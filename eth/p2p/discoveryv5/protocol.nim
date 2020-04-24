# nim-eth - Node Discovery Protocol v5
# Copyright (c) 2020 Status Research & Development GmbH
# Licensed under either of
#   * Apache License, version 2.0, (LICENSE-APACHEv2)
#   * MIT license (LICENSE-MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Node Discovery Protocol v5
##
## Node discovery protocol implementation as per specification:
## https://github.com/ethereum/devp2p/blob/master/discv5/discv5.md
##
## This node discovery protocol implementation uses the same underlying
## implementation of routing table as is also used for the discovery v4
## implementation, which is the same or similar as the one described in the
## original Kademlia paper:
## https://pdos.csail.mit.edu/~petar/papers/maymounkov-kademlia-lncs.pdf
##
## This might not be the most optimal implementation for the node discovery
## protocol v5. Why?
##
## The Kademlia paper describes an implementation that starts off from one
## k-bucket, and keeps splitting the bucket as more nodes are discovered and
## added. The bucket splits only on the part of the binary tree where our own
## node its id belongs too (same prefix). Resulting eventually in a k-bucket per
## logarithmic distance (log base2 distance). Well, not really, as nodes with
## ids in the closer distance ranges will never be found. And because of this an
## optimisation is done where buckets will also split sometimes even if the
## nodes own id does not have the same prefix (this is to avoid creating highly
## unbalanced branches which would require longer lookups).
##
## Now, some implementations take a more simplified approach. They just create
## directly a bucket for each possible logarithmic distance (e.g. here 1->256).
## Some implementations also don't create buckets with logarithmic distance
## lower than a certain value (e.g. only 1/15th of the highest buckets),
## because the closer to the node (the lower the distance), the less chance
## there is to still find nodes.
##
## The discovery protocol v4 its `FindNode` call will request the k closest
## nodes. As does original Kademlia. This effectively puts the work at the node
## that gets the request. This node will have to check its buckets and gather
## the closest. Some implementations go over all the nodes in all the buckets
## for this (e.g. go-ethereum discovery v4). However, in our bucket splitting
## approach, this search is improved.
##
## In the discovery protocol v5 the `FindNode` call is changed and now the
## logarithmic distance is passed as parameter instead of the NodeId. And only
## nodes that match that logarithmic distance are allowed to be returned.
## This change was made to not put the trust at the requested node for selecting
## the closest nodes. To counter a possible (mistaken) difference in
## implementation, but more importantly for security reasons. See also:
## https://github.com/ethereum/devp2p/blob/master/discv5/discv5-rationale.md#115-guard-against-kademlia-implementation-flaws
##
## The result is that in an implementation which just stores buckets per
## logarithmic distance, it simply needs to return the right bucket. In our
## split-bucket implementation, this cannot be done as such and thus the closest
## neighbours search is still done. And to do this, a reverse calculation of an
## id at given logarithmic distance is needed (which is why there is the
## `idAtDistance` proc). Next, nodes with invalid distances need to be filtered
## out to be compliant to the specification. This can most likely get further
## optimised, but it sounds likely better to switch away from the split-bucket
## approach. I believe that the main benefit it has is improved lookups
## (due to no unbalanced branches), and it looks like this will be negated by
## limiting the returned nodes to only the ones of the requested logarithmic
## distance for the `FindNode` call.

## This `FindNode` change in discovery v5 will also have an effect on the
## efficiency of the network. Work will be moved from the receiver of
## `FindNodes` to the requester. But this also means more network traffic,
## as less nodes will potentially be passed around per `FindNode` call, and thus
## more requests will be needed for a lookup (adding bandwidth and latency).
## This might be a concern for mobile devices.

import
  std/[tables, sets, options, math, random],
  json_serialization/std/net,
  stew/[byteutils, endians2], chronicles, chronos, stint,
  eth/[rlp, keys], ../enode, types, encoding, node, routing_table, enr

import nimcrypto except toHex

export options

logScope:
  topics = "discv5"

const
  alpha = 3 ## Kademlia concurrency factor
  lookupRequestLimit = 3
  findNodeResultLimit = 15 # applies in FINDNODE handler
  maxNodesPerPacket = 3
  lookupInterval = 60.seconds ## Interval of launching a random lookup to
  ## populate the routing table. go-ethereum seems to do 3 runs every 30
  ## minutes. Trinity starts one every minute.
  handshakeTimeout* = 2.seconds ## timeout for the reply on the
  ## whoareyou message
  responseTimeout* = 2.seconds ## timeout for the response of a request-response
  ## call
  magicSize = 32 ## size of the magic which is the start of the whoareyou
  ## message

type
  Protocol* = ref object
    transp: DatagramTransport
    localNode*: Node
    privateKey: PrivateKey
    whoareyouMagic: array[magicSize, byte]
    idHash: array[32, byte]
    pendingRequests: Table[AuthTag, PendingRequest]
    db: Database
    routingTable: RoutingTable
    codec*: Codec
    awaitedPackets: Table[(NodeId, RequestId), Future[Option[Packet]]]
    lookupLoop: Future[void]
    revalidateLoop: Future[void]
    bootstrapRecords*: seq[Record]

  PendingRequest = object
    node: Node
    packet: seq[byte]

  RandomSourceDepleted* = object of CatchableError

proc addNode*(d: Protocol, node: Node) =
  discard d.routingTable.addNode(node)

template addNode*(d: Protocol, enode: ENode) =
  addNode d, newNode(enode)

template addNode*(d: Protocol, r: Record) =
  addNode d, newNode(r)

proc addNode*(d: Protocol, enr: EnrUri) =
  var r: Record
  let res = r.fromUri(enr)
  doAssert(res)
  d.addNode newNode(r)

proc getNode*(d: Protocol, id: NodeId): Option[Node] =
  d.routingTable.getNode(id)

proc randomNodes*(d: Protocol, count: int): seq[Node] =
  d.routingTable.randomNodes(count)

proc neighbours*(d: Protocol, id: NodeId, k: int = BUCKET_SIZE): seq[Node] =
  d.routingTable.neighbours(id, k)

proc nodesDiscovered*(d: Protocol): int {.inline.} = d.routingTable.len

func privKey*(d: Protocol): lent PrivateKey =
  d.privateKey

proc send(d: Protocol, a: Address, data: seq[byte]) =
  # debug "Sending bytes", amount = data.len, to = a
  let ta = initTAddress(a.ip, a.udpPort)
  let f = d.transp.sendTo(ta, data)
  f.callback = proc(data: pointer) {.gcsafe.} =
    if f.failed:
      debug "Discovery send failed", msg = f.readError.msg

proc send(d: Protocol, n: Node, data: seq[byte]) =
  d.send(n.node.address, data)

proc `xor`[N: static[int], T](a, b: array[N, T]): array[N, T] =
  for i in 0 .. a.high:
    result[i] = a[i] xor b[i]

proc whoareyouMagic(toNode: NodeId): array[magicSize, byte] =
  const prefix = "WHOAREYOU"
  var data: array[prefix.len + sizeof(toNode), byte]
  data[0 .. sizeof(toNode) - 1] = toNode.toByteArrayBE()
  for i, c in prefix: data[sizeof(toNode) + i] = byte(c)
  sha256.digest(data).data

proc isWhoAreYou(d: Protocol, msg: openArray[byte]): bool =
  if msg.len > d.whoareyouMagic.len:
    result = d.whoareyouMagic == msg.toOpenArray(0, magicSize - 1)

proc decodeWhoAreYou(d: Protocol, msg: openArray[byte]): Whoareyou =
  result = Whoareyou()
  result[] = rlp.decode(msg.toOpenArray(magicSize, msg.high), WhoareyouObj)

proc sendWhoareyou(d: Protocol, address: Address, toNode: NodeId, authTag: AuthTag) =
  trace "sending who are you", to = $toNode, toAddress = $address
  let challenge = Whoareyou(authTag: authTag, recordSeq: 0)

  if randomBytes(challenge.idNonce) != challenge.idNonce.len:
    raise newException(RandomSourceDepleted, "Could not randomize bytes")
  # If there is already a handshake going on for this nodeid then we drop this
  # new one. Handshake will get cleaned up after `handshakeTimeout`.
  # If instead overwriting the handshake would be allowed, the handshake timeout
  # will need to be canceled each time.
  # TODO: could also clean up handshakes in a seperate call, e.g. triggered in
  # a loop.
  # Use toNode + address to make it more difficult for an attacker to occupy
  # the handshake of another node.

  let key = HandShakeKey(nodeId: toNode, address: $address)
  if not d.codec.handshakes.hasKeyOrPut(key, challenge):
    sleepAsync(handshakeTimeout).addCallback() do(data: pointer):
      # TODO: should we still provide cancellation in case handshake completes
      # correctly?
      d.codec.handshakes.del(key)

    var data = @(whoareyouMagic(toNode))
    data.add(rlp.encode(challenge[]))
    d.send(address, data)

proc sendNodes(d: Protocol, toId: NodeId, toAddr: Address, reqId: RequestId,
    nodes: openarray[Node]) =
  proc sendNodes(d: Protocol, toId: NodeId, toAddr: Address,
      packet: NodesPacket, reqId: RequestId) {.nimcall.} =
    let (data, _) = d.codec.encodeEncrypted(toId, toAddr,
      encodePacket(packet, reqId), challenge = nil).tryGet()
    d.send(toAddr, data)

  var packet: NodesPacket
  packet.total = ceil(nodes.len / maxNodesPerPacket).uint32

  for i in 0 ..< nodes.len:
    packet.enrs.add(nodes[i].record)
    if packet.enrs.len == 3:
      d.sendNodes(toId, toAddr, packet, reqId)
      packet.enrs.setLen(0)

  if packet.enrs.len != 0:
    d.sendNodes(toId, toAddr, packet, reqId)

proc handlePing(d: Protocol, fromId: NodeId, fromAddr: Address,
    ping: PingPacket, reqId: RequestId) =
  let a = fromAddr
  var pong: PongPacket
  pong.enrSeq = ping.enrSeq
  pong.ip = case a.ip.family
    of IpAddressFamily.IPv4: @(a.ip.address_v4)
    of IpAddressFamily.IPv6: @(a.ip.address_v6)
  pong.port = a.udpPort.uint16

  let (data, _) = d.codec.encodeEncrypted(fromId, fromAddr,
    encodePacket(pong, reqId), challenge = nil).tryGet()
  d.send(fromAddr, data)

proc handleFindNode(d: Protocol, fromId: NodeId, fromAddr: Address,
    fn: FindNodePacket, reqId: RequestId) =
  if fn.distance == 0:
    d.sendNodes(fromId, fromAddr, reqId, [d.localNode])
  else:
    let distance = min(fn.distance, 256)
    d.sendNodes(fromId, fromAddr, reqId,
      d.routingTable.neighboursAtDistance(distance))

proc receive*(d: Protocol, a: Address, msg: openArray[byte]) {.gcsafe,
  raises: [
    Defect,
    # TODO This is now coming from Chronos's callSoon
    Exception,
    # TODO All of these should probably be handled here
    RlpError,
    IOError,
    TransportAddressError,
  ].} =
  if msg.len < tagSize: # or magicSize, can be either
    return # Invalid msg

  # debug "Packet received: ", length = msg.len

  if d.isWhoAreYou(msg):
    trace "Received whoareyou", localNode = $d.localNode, address = a
    let whoareyou = d.decodeWhoAreYou(msg)
    var pr: PendingRequest
    if d.pendingRequests.take(whoareyou.authTag, pr):
      let toNode = pr.node
      whoareyou.pubKey = toNode.node.pubkey # TODO: Yeah, rather ugly this.
      try:
        let (data, _) = d.codec.encodeEncrypted(toNode.id, toNode.address,
          pr.packet, challenge = whoareyou).tryGet()
        d.send(toNode, data)
      except RandomSourceDepleted:
        debug "Failed to respond to a who-you-are msg " &
              "due to randomness source depletion."

  else:
    var tag: array[tagSize, byte]
    tag[0 .. ^1] = msg.toOpenArray(0, tagSize - 1)
    let senderData = tag xor d.idHash
    let sender = readUintBE[256](senderData)

    var authTag: AuthTag
    var node: Node
    var packet: Packet
    let decoded = d.codec.decodeEncrypted(sender, a, msg, authTag, node, packet)
    if decoded.isOk:
      if not node.isNil:
        # Not filling table with nodes without correct IP in the ENR
        if a.ip == node.address.ip:
          debug "Adding new node to routing table", node = $node,
            localNode = $d.localNode
          discard d.routingTable.addNode(node)

      case packet.kind
      of ping:
        d.handlePing(sender, a, packet.ping, packet.reqId)
      of findNode:
        d.handleFindNode(sender, a, packet.findNode, packet.reqId)
      else:
        var waiter: Future[Option[Packet]]
        if d.awaitedPackets.take((sender, packet.reqId), waiter):
          waiter.complete(packet.some)
        else:
          debug "TODO: handle packet: ", packet = packet.kind, origin = a
    elif decoded.error == DecodeError.DecryptError:
      debug "Could not decrypt packet, respond with whoareyou",
        localNode = $d.localNode, address = a
      # only sendingWhoareyou in case it is a decryption failure
      d.sendWhoareyou(a, sender, authTag)
    elif decoded.error == DecodeError.UnsupportedPacketType:
      # Still adding the node in case failure is because of unsupported packet.
      if not node.isNil:
        if a.ip == node.address.ip:
          debug "Adding new node to routing table", node = $node,
            localNode = $d.localNode
          discard d.routingTable.addNode(node)
    # elif decoded.error == DecodeError.PacketError:
      # Not adding this node as from our perspective it is sending rubbish.

proc processClient(transp: DatagramTransport,
                   raddr: TransportAddress): Future[void] {.async, gcsafe.} =
  var proto = getUserData[Protocol](transp)
  try:
    # TODO: Maybe here better to use `peekMessage()` to avoid allocation,
    # but `Bytes` object is just a simple seq[byte], and `ByteRange` object
    # do not support custom length.
    var buf = transp.getMessage()
    let a = Address(ip: raddr.address, udpPort: raddr.port, tcpPort: raddr.port)
    proto.receive(a, buf)
  except RlpError as e:
    debug "Receive failed", exception = e.name, msg = e.msg
  # TODO: what else can be raised? Figure this out and be more restrictive?
  except CatchableError as e:
    debug "Receive failed", exception = e.name, msg = e.msg,
      stacktrace = e.getStackTrace()

proc validIp(sender, address: IpAddress): bool =
  let
    s = initTAddress(sender, Port(0))
    a = initTAddress(address, Port(0))
  if a.isAnyLocal():
    return false
  if a.isMulticast():
    return false
  if a.isLoopback() and not s.isLoopback():
    return false
  if a.isSiteLocal() and not s.isSiteLocal():
    return false
  # TODO: Also check for special reserved ip addresses:
  # https://www.iana.org/assignments/iana-ipv4-special-registry/iana-ipv4-special-registry.xhtml
  # https://www.iana.org/assignments/iana-ipv6-special-registry/iana-ipv6-special-registry.xhtml
  return true

# TODO: This could be improved to do the clean-up immediatily in case a non
# whoareyou response does arrive, but we would need to store the AuthTag
# somewhere
proc registerRequest(d: Protocol, n: Node, packet: seq[byte], nonce: AuthTag) =
  let request = PendingRequest(node: n, packet: packet)
  if not d.pendingRequests.hasKeyOrPut(nonce, request):
    sleepAsync(responseTimeout).addCallback() do(data: pointer):
      d.pendingRequests.del(nonce)

proc waitPacket(d: Protocol, fromNode: Node, reqId: RequestId): Future[Option[Packet]] =
  result = newFuture[Option[Packet]]("waitPacket")
  let res = result
  let key = (fromNode.id, reqId)
  sleepAsync(responseTimeout).addCallback() do(data: pointer):
    d.awaitedPackets.del(key)
    if not res.finished:
      res.complete(none(Packet))
  d.awaitedPackets[key] = result

proc addNodesFromENRs(result: var seq[Node], enrs: openarray[Record]) =
  for r in enrs: result.add(newNode(r))

proc waitNodes(d: Protocol, fromNode: Node, reqId: RequestId): Future[seq[Node]] {.async.} =
  var op = await d.waitPacket(fromNode, reqId)
  if op.isSome and op.get.kind == nodes:
    result.addNodesFromENRs(op.get.nodes.enrs)
    let total = op.get.nodes.total
    for i in 1 ..< total:
      op = await d.waitPacket(fromNode, reqId)
      if op.isSome and op.get.kind == nodes:
        result.addNodesFromENRs(op.get.nodes.enrs)
      else:
        break

proc sendPing(d: Protocol, toNode: Node): RequestId =
  let
    reqId = newRequestId().tryGet()
    ping = PingPacket(enrSeq: d.localNode.record.seqNum)
    packet = encodePacket(ping, reqId)
    (data, nonce) = d.codec.encodeEncrypted(toNode.id, toNode.address, packet,
      challenge = nil).tryGet()
  d.registerRequest(toNode, packet, nonce)
  d.send(toNode, data)
  return reqId

proc ping*(d: Protocol, toNode: Node): Future[Option[PongPacket]] {.async.} =
  let reqId = d.sendPing(toNode)
  let resp = await d.waitPacket(toNode, reqId)

  if resp.isSome() and resp.get().kind == pong:
    return some(resp.get().pong)

proc sendFindNode(d: Protocol, toNode: Node, distance: uint32): RequestId =
  let reqId = newRequestId().tryGet()
  let packet = encodePacket(FindNodePacket(distance: distance), reqId)
  let (data, nonce) = d.codec.encodeEncrypted(toNode.id, toNode.address, packet,
    challenge = nil).tryGet()
  d.registerRequest(toNode, packet, nonce)

  d.send(toNode, data)
  return reqId

proc findNode*(d: Protocol, toNode: Node, distance: uint32): Future[seq[Node]] {.async.} =
  let reqId = sendFindNode(d, toNode, distance)
  let nodes = await d.waitNodes(toNode, reqId)

  for n in nodes:
    if validIp(toNode.address.ip, n.address.ip):
      result.add(n)

proc lookupDistances(target, dest: NodeId): seq[uint32] =
  let td = logDist(target, dest)
  result.add(td)
  var i = 1'u32
  while result.len < lookupRequestLimit:
    if td + i < 256:
      result.add(td + i)
    if td - i > 0'u32:
      result.add(td - i)
    inc i

proc lookupWorker(d: Protocol, destNode: Node, target: NodeId): Future[seq[Node]] {.async.} =
  let dists = lookupDistances(target, destNode.id)
  var i = 0
  while i < lookupRequestLimit and result.len < findNodeResultLimit:
    # TODO: Handle failures
    let r = await d.findNode(destNode, dists[i])
    # TODO: I guess it makes sense to limit here also to `findNodeResultLimit`?
    result.add(r)
    inc i

  for n in result:
    discard d.routingTable.addNode(n)

proc lookup*(d: Protocol, target: NodeId): Future[seq[Node]] {.async.} =
  ## Perform a lookup for the given target, return the closest n nodes to the
  ## target. Maximum value for n is `BUCKET_SIZE`.
  # TODO: Sort the returned nodes on distance
  result = d.routingTable.neighbours(target, BUCKET_SIZE)
  var asked = initHashSet[NodeId]()
  asked.incl(d.localNode.id)
  var seen = asked
  for node in result:
    seen.incl(node.id)

  var pendingQueries = newSeqOfCap[Future[seq[Node]]](alpha)

  while true:
    var i = 0
    while i < result.len and pendingQueries.len < alpha:
      let n = result[i]
      if not asked.containsOrIncl(n.id):
        pendingQueries.add(d.lookupWorker(n, target))
      inc i

    trace "discv5 pending queries", total = pendingQueries.len

    if pendingQueries.len == 0:
      break

    let idx = await oneIndex(pendingQueries)
    trace "Got discv5 lookup response", idx

    let nodes = pendingQueries[idx].read
    pendingQueries.del(idx)
    for n in nodes:
      if not seen.containsOrIncl(n.id):
        if result.len < BUCKET_SIZE:
          result.add(n)

proc lookupRandom*(d: Protocol): Future[seq[Node]]
    {.raises:[RandomSourceDepleted, Defect, Exception].} =
  var id: NodeId
  if randomBytes(addr id, sizeof(id)) != sizeof(id):
    raise newException(RandomSourceDepleted, "Could not randomize bytes")
  d.lookup(id)

proc resolve*(d: Protocol, id: NodeId): Future[Option[Node]] {.async.} =
  ## Resolve a `Node` based on provided `NodeId`.
  ##
  ## This will first look in the own DHT. If the node is known, it will try to
  ## contact if for newer information. If node is not known or it does not
  ## reply, a lookup is done to see if it can find a (newer) record of the node
  ## on the network.

  let node = d.getNode(id)
  if node.isSome():
    let request = await d.findNode(node.get(), 0)

    if request.len > 0:
      return some(request[0])

  let discovered = await d.lookup(id)
  for n in discovered:
    if n.id == id:
      # TODO: Not getting any new seqNum here as in a lookup nodes in table with
      # new seqNum don't get replaced.
      if node.isSome() and node.get().record.seqNum >= n.record.seqNum:
        return node
      else:
        return some(n)

proc revalidateNode*(d: Protocol, n: Node)
    {.async, raises:[Defect, Exception].} = # TODO: Exception
  trace "Ping to revalidate node", node = $n
  let pong = await d.ping(n)

  if pong.isSome():
    if pong.get().enrSeq > n.record.seqNum:
      # TODO: Request new ENR
      discard

    d.routingTable.setJustSeen(n)
    trace "Revalidated node", node = $n
  else:
    # For now we never remove bootstrap nodes. It might make sense to actually
    # do so and to retry them only in case we drop to a really low amount of
    # peers in the DHT
    if n.record notin d.bootstrapRecords:
      trace "Revalidation of node failed, removing node", record = n.record
      d.routingTable.removeNode(n)
      # Remove shared secrets when removing the node from routing table.
      # This might be to direct, so we could keep these longer. But better
      # would be to simply not remove the nodes immediatly but only after x
      # amount of failures.
      discard d.codec.db.deleteKeys(n.id, n.address)
    else:
      debug "Revalidation of bootstrap node failed", enr = toURI(n.record)

proc revalidateLoop(d: Protocol) {.async.} =
  try:
    # TODO: We need to handle actual errors still, which might just allow to
    # continue the loop. However, currently `revalidateNode` raises a general
    # `Exception` making this rather hard.
    while true:
      await sleepAsync(rand(10 * 1000).milliseconds)
      let n = d.routingTable.nodeToRevalidate()
      if not n.isNil:
        # TODO: Should we do these in parallel and/or async to be certain of how
        # often nodes are revalidated?
        await d.revalidateNode(n)
  except CancelledError:
    trace "revalidateLoop canceled"

proc lookupLoop(d: Protocol) {.async.} =
  ## TODO: Same story as for `revalidateLoop`
  try:
    while true:
      # lookup self (neighbour nodes)
      var nodes = await d.lookup(d.localNode.id)
      trace "Discovered nodes in self lookup", nodes = $nodes

      nodes = await d.lookupRandom()
      trace "Discovered nodes in random lookup", nodes = $nodes
      await sleepAsync(lookupInterval)
  except CancelledError:
    trace "lookupLoop canceled"

proc newProtocol*(privKey: PrivateKey, db: Database,
                  externalIp: Option[IpAddress], tcpPort, udpPort: Port,
                  localEnrFields: openarray[FieldPair] = [],
                  bootstrapRecords: openarray[Record] = []): Protocol =
  let
    a = Address(ip: externalIp.get(IPv4_any()),
                tcpPort: tcpPort, udpPort: udpPort)
    enode = ENode(pubkey: privKey.toPublicKey().tryGet(), address: a)
    enrRec = enr.Record.init(1, privKey, externalIp, tcpPort, udpPort, localEnrFields)
    node = newNode(enode, enrRec)

  result = Protocol(
    privateKey: privKey,
    db: db,
    localNode: node,
    whoareyouMagic: whoareyouMagic(node.id),
    idHash: sha256.digest(node.id.toByteArrayBE).data,
    codec: Codec(localNode: node, privKey: privKey, db: db),
    bootstrapRecords: @bootstrapRecords)

  result.routingTable.init(node)

proc open*(d: Protocol) =
  info "Starting discovery node", node = $d.localNode,
    uri = toURI(d.localNode.record)
  # TODO allow binding to specific IP / IPv6 / etc
  let ta = initTAddress(IPv4_any(), d.localNode.node.address.udpPort)
  d.transp = newDatagramTransport(processClient, udata = d, local = ta)

  for record in d.bootstrapRecords:
    debug "Adding bootstrap node", uri = toURI(record)
    d.addNode(record)

proc start*(d: Protocol) =
  # Might want to move these to a separate proc if this turns out to be needed.
  d.lookupLoop = lookupLoop(d)
  d.revalidateLoop = revalidateLoop(d)

proc close*(d: Protocol) =
  doAssert(not d.transp.closed)

  debug "Closing discovery node", node = $d.localNode
  if not d.revalidateLoop.isNil:
    d.revalidateLoop.cancel()
  if not d.lookupLoop.isNil:
    d.lookupLoop.cancel()
  # TODO: unsure if close can't create issues in the not awaited cancellations
  # above
  d.transp.close()

proc closeWait*(d: Protocol) {.async.} =
  doAssert(not d.transp.closed)

  debug "Closing discovery node", node = $d.localNode
  if not d.revalidateLoop.isNil:
    await d.revalidateLoop.cancelAndWait()
  if not d.lookupLoop.isNil:
    await d.lookupLoop.cancelAndWait()

  await d.transp.closeWait()
