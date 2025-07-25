# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[tables, sequtils, sets, algorithm, deques]
import chronos, chronicles, metrics
import "."/[types, scoring]
import ".."/[pubsubpeer, peertable, mcache, floodsub, pubsub]
import "../rpc"/[messages]
import
  "../../.."/[
    peerid,
    multiaddress,
    utility,
    switch,
    routing_record,
    signed_envelope,
    utils/heartbeat,
  ]
when defined(libp2p_gossipsub_1_4):
  import ./preamblestore
  import ../bandwidth

logScope:
  topics = "libp2p gossipsub"

declareGauge(libp2p_gossipsub_cache_window_size, "the number of messages in the cache")
declareGauge(
  libp2p_gossipsub_peers_per_topic_mesh,
  "gossipsub peers per topic in mesh",
  labels = ["topic"],
)
declareGauge(
  libp2p_gossipsub_peers_per_topic_fanout,
  "gossipsub peers per topic in fanout",
  labels = ["topic"],
)
declareGauge(
  libp2p_gossipsub_peers_per_topic_gossipsub,
  "gossipsub peers per topic in gossipsub",
  labels = ["topic"],
)
declareGauge(libp2p_gossipsub_under_dout_topics, "number of topics below dout")
declareGauge(libp2p_gossipsub_no_peers_topics, "number of topics in mesh with no peers")
declareGauge(
  libp2p_gossipsub_low_peers_topics,
  "number of topics in mesh with at least one but below dlow peers",
)
declareGauge(
  libp2p_gossipsub_healthy_peers_topics,
  "number of topics in mesh with at least dlow peers (but below dhigh)",
)
declareCounter(
  libp2p_gossipsub_above_dhigh_condition,
  "number of above dhigh pruning branches ran",
  labels = ["topic"],
)
declareGauge(libp2p_gossipsub_received_iwants, "received iwants", labels = ["kind"])
declareCounter(
  libp2p_gossipsub_preamble_saved_iwants,
  "number of iwant requests avoided by preamble",
  labels = ["topic"],
)

const MaxHeIsReceiving = 50

proc grafted*(g: GossipSub, p: PubSubPeer, topic: string) =
  g.withPeerStats(p.peerId) do(stats: var PeerStats):
    var info = stats.topicInfos.getOrDefault(topic)
    info.graftTime = Moment.now()
    info.meshTime = 0.seconds
    info.inMesh = true
    info.meshMessageDeliveriesActive = false

    stats.topicInfos[topic] = info

    trace "grafted", peer = p, topic

proc pruned*(
    g: GossipSub,
    p: PubSubPeer,
    topic: string,
    setBackoff: bool = true,
    backoff = none(Duration),
) =
  if setBackoff:
    let
      backoffDuration = backoff.get(g.parameters.pruneBackoff)
      backoffMoment = Moment.fromNow(backoffDuration)

    g.backingOff.mgetOrPut(topic, initTable[PeerId, Moment]())[p.peerId] = backoffMoment

  g.peerStats.withValue(p.peerId, stats):
    stats.topicInfos.withValue(topic, info):
      g.topicParams.withValue(topic, topicParams):
        # penalize a peer that delivered no message
        let threshold = topicParams[].meshMessageDeliveriesThreshold
        if info[].inMesh and info[].meshMessageDeliveriesActive and
            info[].meshMessageDeliveries < threshold:
          let deficit = threshold - info.meshMessageDeliveries
          info[].meshFailurePenalty += deficit * deficit

      info.inMesh = false

      trace "pruned", peer = p, topic

proc handleBackingOff*(t: var BackoffTable, topic: string) =
  let now = Moment.now()
  var expired = toSeq(t.getOrDefault(topic).pairs())
  expired.keepIf do(pair: tuple[peer: PeerId, expire: Moment]) -> bool:
    now >= pair.expire
  for (peer, _) in expired:
    t.withValue(topic, v):
      v[].del(peer)

proc peerExchangeList*(g: GossipSub, topic: string): seq[PeerInfoMsg] =
  if not g.parameters.enablePX:
    return @[]
  var peers = g.gossipsub.getOrDefault(topic, initHashSet[PubSubPeer]()).toSeq()
  peers.keepIf do(x: PubSubPeer) -> bool:
    x.score >= 0.0
  # by spec, larger then Dhi, but let's put some hard caps
  peers.setLen(min(peers.len, g.parameters.dHigh * 2))
  let sprBook = g.switch.peerStore[SPRBook]
  peers.map do(x: PubSubPeer) -> PeerInfoMsg:
    PeerInfoMsg(
      peerId: x.peerId,
      signedPeerRecord:
        if x.peerId in sprBook:
          sprBook[x.peerId].encode().get(default(seq[byte]))
        else:
          default(seq[byte]),
    )

proc handleGraft*(
    g: GossipSub, peer: PubSubPeer, grafts: seq[ControlGraft]
): seq[ControlPrune] =
  var prunes: seq[ControlPrune]
  for graft in grafts:
    let topic = graft.topicID
    trace "peer grafted topicID", peer, topic

    # It is an error to GRAFT on a direct peer
    if peer.peerId in g.parameters.directPeers:
      # receiving a graft from a direct peer should yield a more prominent warning (protocol violation)
      # we are trusting direct peer not to abuse this
      warn "a direct peer attempted to graft us, peering agreements should be reciprocal",
        peer, topic
      # and such an attempt should be logged and rejected with a PRUNE
      prunes.add(
        ControlPrune(
          topicID: topic,
          peers: @[],
            # omitting heavy computation here as the remote did something illegal
          backoff: g.parameters.pruneBackoff.seconds.uint64,
        )
      )

      let backoff = Moment.fromNow(g.parameters.pruneBackoff)

      g.backingOff.mgetOrPut(topic, initTable[PeerId, Moment]())[peer.peerId] = backoff

      peer.behaviourPenalty += 0.1

      continue

    if g.mesh.hasPeer(topic, peer):
      trace "peer already in mesh", peer, topic
      continue

    # Check backingOff
    # Ignore BackoffSlackTime here, since this only for outbound activity
    # and subtract a second time to avoid race conditions
    # (peers may wait to graft us as the exact instant they're allowed to)
    if g.backingOff.getOrDefault(topic).getOrDefault(peer.peerId) -
        (BackoffSlackTime * 2).seconds > Moment.now():
      debug "a backingOff peer attempted to graft us", peer, topic
      # and such an attempt should be logged and rejected with a PRUNE
      prunes.add(
        ControlPrune(
          topicID: topic,
          peers: @[],
            # omitting heavy computation here as the remote did something illegal
          backoff: g.parameters.pruneBackoff.seconds.uint64,
        )
      )

      let backoff = Moment.fromNow(g.parameters.pruneBackoff)

      g.backingOff.mgetOrPut(topic, initTable[PeerId, Moment]())[peer.peerId] = backoff

      peer.behaviourPenalty += 0.1

      continue

    # not in the spec exactly, but let's avoid way too low score peers
    # other clients do it too also was an audit recommendation
    if peer.score < g.parameters.publishThreshold:
      continue

    # If they send us a graft before they send us a subscribe, what should
    # we do? For now, we add them to mesh but don't add them to gossipsub.
    if topic in g.topics:
      if g.mesh.peers(topic) < g.parameters.dHigh or
          (peer.outbound and g.mesh.outboundPeers(topic) < g.parameters.dOut):
        # In the spec, there's no mention of DHi here, but implicitly, a
        # peer will be removed from the mesh on next rebalance, so we don't want
        # this peer to push someone else out
        if g.mesh.addPeer(topic, peer):
          g.grafted(peer, topic)
          g.fanout.removePeer(topic, peer)
        else:
          trace "peer already in mesh", peer, topic
      else:
        trace "pruning grafting peer, mesh full",
          peer, topic, score = peer.score, mesh = g.mesh.peers(topic)
        prunes.add(
          ControlPrune(
            topicID: topic,
            peers: g.peerExchangeList(topic),
            backoff: g.parameters.pruneBackoff.seconds.uint64,
          )
        )

        let backoff = Moment.fromNow(g.parameters.pruneBackoff)

        g.backingOff.mgetOrPut(topic, initTable[PeerId, Moment]())[peer.peerId] =
          backoff
    else:
      trace "peer grafting topic we're not interested in", peer, topic
      # gossip 1.1, we do not send a control message prune anymore

  return prunes

proc getPeers(
    prune: ControlPrune, peer: PubSubPeer
): seq[(PeerId, Option[PeerRecord])] =
  var routingRecords: seq[(PeerId, Option[PeerRecord])]
  for record in prune.peers:
    var peerRecord = none(PeerRecord)
    if record.signedPeerRecord.len > 0:
      SignedPeerRecord.decode(record.signedPeerRecord).toOpt().withValue(spr):
        if record.peerId != spr.data.peerId:
          trace "peer sent envelope with wrong public key", peer
        else:
          peerRecord = some(spr.data)
      else:
        trace "peer sent invalid SPR", peer

    routingRecords.add((record.peerId, peerRecord))

  routingRecords

proc handlePrune*(g: GossipSub, peer: PubSubPeer, prunes: seq[ControlPrune]) =
  for prune in prunes:
    let topic = prune.topicID

    trace "peer pruned topicID", peer, topic

    # add peer backoff
    if prune.backoff > 0:
      let
        # avoid overflows and clamp to reasonable value
        backoffSeconds =
          clamp(prune.backoff + BackoffSlackTime, 0'u64, 1.days.seconds.uint64)
        backoff = Moment.fromNow(backoffSeconds.int64.seconds)
        current = g.backingOff.getOrDefault(topic).getOrDefault(peer.peerId)
      if backoff > current:
        g.backingOff.mgetOrPut(topic, initTable[PeerId, Moment]())[peer.peerId] =
          backoff

    trace "pruning rpc received peer", peer, score = peer.score
    g.pruned(peer, topic, setBackoff = false)
    g.mesh.removePeer(topic, peer)

    if peer.score > g.parameters.gossipThreshold and prune.peers.len > 0 and
        g.routingRecordsHandler.len > 0:
      let routingRecords = prune.getPeers(peer)

      for handler in g.routingRecordsHandler:
        handler(peer.peerId, topic, routingRecords)

when defined(libp2p_gossipsub_1_4):
  proc addPossiblePeerToQuery(g: GossipSub, peer: PubSubPeer, messageId: MessageId) =
    g.ongoingReceives.addPossiblePeerToQuery(messageId, peer)
    g.ongoingIWantReceives.addPossiblePeerToQuery(messageId, peer)

proc handleIHave*(
    g: GossipSub, peer: PubSubPeer, ihaves: seq[ControlIHave]
): ControlIWant =
  var res: ControlIWant
  if peer.score < g.parameters.gossipThreshold:
    trace "ihave: ignoring low score peer", peer, score = peer.score
  elif peer.iHaveBudget <= 0:
    trace "ihave: ignoring out of budget peer", peer, score = peer.score
  else:
    for ihave in ihaves:
      trace "peer sent ihave", peer, topicID = ihave.topicID, msgs = ihave.messageIDs
      if ihave.topicID in g.topics:
        for msgId in ihave.messageIDs:
          if not g.hasSeen(g.salt(msgId)):
            if peer.iHaveBudget <= 0:
              break
            elif msgId notin res.messageIDs:
              when defined(libp2p_gossipsub_1_4):
                if g.ongoingReceives.hasKey(msgId) or
                    g.ongoingIWantReceives.hasKey(msgId):
                  g.addPossiblePeerToQuery(peer, msgId)
                  libp2p_gossipsub_preamble_saved_iwants.inc(
                    labelValues = [ihave.topicID]
                  )
                  continue
              res.messageIDs.add(msgId)
              dec peer.iHaveBudget
              trace "requested message via ihave", messageID = msgId
    # shuffling res.messageIDs before sending it out to increase the likelihood
    # of getting an answer if the peer truncates the list due to internal size restrictions.
    g.rng.shuffle(res.messageIDs)
    return res

proc handleIDontWant*(g: GossipSub, peer: PubSubPeer, iDontWants: seq[ControlIWant]) =
  for dontWant in iDontWants:
    for messageId in dontWant.messageIDs:
      if peer.iDontWants[0].len >= IDontWantMaxCount:
        break
      peer.iDontWants[0].incl(g.salt(messageId))
      when defined(libp2p_gossipsub_1_4):
        peer.heIsReceivings.del(messageId)
        g.addPossiblePeerToQuery(peer, messageId)

proc handleIWant*(
    g: GossipSub, peer: PubSubPeer, iwants: seq[ControlIWant]
): tuple[messages: seq[Message], ids: seq[MessageId]] =
  var response: tuple[messages: seq[Message], ids: seq[MessageId]]
  var invalidRequests = 0
  if peer.score < g.parameters.gossipThreshold:
    trace "iwant: ignoring low score peer", peer, score = peer.score
  else:
    for iwant in iwants:
      for mid in iwant.messageIDs:
        trace "peer sent iwant", peer, messageID = mid
        # canAskIWant will only return true once for a specific message
        if not peer.canAskIWant(mid):
          libp2p_gossipsub_received_iwants.inc(1, labelValues = ["notsent"])

          invalidRequests.inc()
          if invalidRequests > 20:
            libp2p_gossipsub_received_iwants.inc(1, labelValues = ["skipped"])
            return response
          continue
        let msg = g.mcache.get(mid).valueOr:
          libp2p_gossipsub_received_iwants.inc(1, labelValues = ["unknown"])
          continue
        libp2p_gossipsub_received_iwants.inc(1, labelValues = ["correct"])
        response.messages.add(msg)
        response.ids.add(mid)
  return response

when defined(libp2p_gossipsub_1_4):
  proc medianDownloadRate*(p: var HashSet[PubSubPeer]): float =
    if p.len == 0:
      return 0

    let vals = p.toSeq().mapIt(it.bandwidthTracking.download.value()).sorted()
    echo vals
    let mid = vals.len div 2
    if vals.len mod 2 == 0:
      (vals[mid - 1] + vals[mid]) / 2
    else:
      vals[mid]

  proc handlePreamble*(
      g: GossipSub, peer: PubSubPeer, preambles: seq[ControlPreamble]
  ) =
    let starts = Moment.now()

    for preamble in preambles:
      dec peer.preambleBudget
      if peer.preambleBudget <= 0:
        return
      if g.hasSeen(g.salt(preamble.messageID)):
        continue
      elif peer.heIsSendings.hasKey(preamble.messageID):
        continue
      elif g.ongoingReceives.hasKey(preamble.messageID):
        #TODO: add to conflicts_watch if length is different
        continue
      else:
        peer.heIsSendings[preamble.messageID] = starts
        var toSendPeers = HashSet[PubSubPeer]()
        g.mesh.withValue(preamble.topicID, peers):
          toSendPeers.incl(peers[])
        toSendPeers.incl(g.subscribedDirectPeers.getOrDefault(preamble.topicID))
        var peers = toSendPeers.filterIt(it.codec == GossipSubCodec_14)
        let bytesPerSecond = peer.bandwidthTracking.download.value()
        let transmissionTimeMs =
          calculateReceiveTimeMs(preamble.messageLength.int64, bytesPerSecond.int64)
        let expires = starts + transmissionTimeMs.milliseconds

        #We send imreceiving only if received from mesh members
        if peer notin peers:
          if not g.ongoingIWantReceives.hasKey(preamble.messageID):
            g.ongoingIWantReceives[preamble.messageID] =
              PreambleInfo.init(preamble, peer, starts, expires)

          trace "preamble: ignoring out of mesh peer", peer
          continue

        g.ongoingReceives[preamble.messageID] =
          PreambleInfo.init(preamble, peer, starts, expires)

        #Send imreceiving only if received from faster mesh members
        if bytesPerSecond >= toSendPeers.medianDownloadRate():
          g.broadcast(
            peers,
            RPCMsg(
              control: some(
                ControlMessage(
                  imreceiving:
                    @[
                      ControlIMReceiving(
                        messageID: preamble.messageID,
                        messageLength: preamble.messageLength,
                      )
                    ]
                )
              )
            ),
            isHighPriority = true,
          )

  proc handleIMReceiving*(
      g: GossipSub, peer: PubSubPeer, imreceivings: seq[ControlIMReceiving]
  ) =
    for imreceiving in imreceivings:
      if peer.heIsReceivings.len > MaxHeIsReceiving:
        break
      #Ignore if message length is different
      g.ongoingReceives.withValue(imreceiving.messageID, pInfo):
        if pInfo.messageLength != imreceiving.messageLength:
          continue
      peer.heIsReceivings[imreceiving.messageID] = imreceiving.messageLength
      #No need to check mcache. In that case, we might have already transmitted/transmitting

proc commitMetrics(metrics: var MeshMetrics) =
  libp2p_gossipsub_low_peers_topics.set(metrics.lowPeersTopics)
  libp2p_gossipsub_no_peers_topics.set(metrics.noPeersTopics)
  libp2p_gossipsub_under_dout_topics.set(metrics.underDoutTopics)
  libp2p_gossipsub_healthy_peers_topics.set(metrics.healthyPeersTopics)
  libp2p_gossipsub_peers_per_topic_gossipsub.set(
    metrics.otherPeersPerTopicGossipsub, labelValues = ["other"]
  )
  libp2p_gossipsub_peers_per_topic_fanout.set(
    metrics.otherPeersPerTopicFanout, labelValues = ["other"]
  )
  libp2p_gossipsub_peers_per_topic_mesh.set(
    metrics.otherPeersPerTopicMesh, labelValues = ["other"]
  )

proc rebalanceMesh*(g: GossipSub, topic: string, metrics: ptr MeshMetrics = nil) =
  logScope:
    topic
    mesh = g.mesh.peers(topic)
    gossipsub = g.gossipsub.peers(topic)

  trace "rebalancing mesh"

  # create a mesh topic that we're subscribing to

  var
    prunes, grafts: seq[PubSubPeer]
    npeers = g.mesh.peers(topic)
    nOutPeers = g.mesh.outboundPeers(topic)
    defaultMesh: HashSet[PubSubPeer]
    backingOff = g.backingOff.getOrDefault(topic)

  if npeers < g.parameters.dLow:
    trace "replenishing mesh", peers = npeers
    # replenish the mesh if we're below Dlo

    var
      candidates: seq[PubSubPeer]
      currentMesh = addr defaultMesh
    g.mesh.withValue(topic, v):
      currentMesh = v
    g.gossipsub.withValue(topic, peerList):
      for it in peerList[]:
        if it.connected and
            # avoid negative score peers
            it.score >= 0.0 and it notin currentMesh[] and
            # don't pick direct peers
            it.peerId notin g.parameters.directPeers and
            # and avoid peers we are backing off
            it.peerId notin backingOff:
          candidates.add(it)

    # shuffle anyway, score might be not used
    g.rng.shuffle(candidates)

    # sort peers by score, high score first since we graft
    candidates.sort(byScore, SortOrder.Descending)

    # Graft peers so we reach a count of D
    candidates.setLen(min(candidates.len, g.parameters.d - npeers))

    trace "grafting", grafting = candidates.len

    if candidates.len > 0:
      for peer in candidates:
        if g.mesh.addPeer(topic, peer):
          g.grafted(peer, topic)
          g.fanout.removePeer(topic, peer)
          grafts &= peer
  elif nOutPeers < g.parameters.dOut:
    trace "replenishing mesh outbound quota", peers = g.mesh.peers(topic)

    var
      candidates: seq[PubSubPeer]
      currentMesh = addr defaultMesh
    g.mesh.withValue(topic, v):
      currentMesh = v
    g.gossipsub.withValue(topic, peerList):
      for it in peerList[]:
        if it.connected and
        # get only outbound ones
        it.outbound and it notin currentMesh[] and
            # avoid negative score peers
            it.score >= 0.0 and
            # don't pick direct peers
            it.peerId notin g.parameters.directPeers and
            # and avoid peers we are backing off
            it.peerId notin backingOff:
          candidates.add(it)

    # shuffle anyway, score might be not used
    g.rng.shuffle(candidates)

    # sort peers by score, high score first, we are grafting
    candidates.sort(byScore, SortOrder.Descending)

    # Graft outgoing peers so we reach a count of dOut
    candidates.setLen(min(candidates.len, g.parameters.dOut - nOutPeers))

    trace "grafting outbound peers", topic, peers = candidates.len

    for peer in candidates:
      if g.mesh.addPeer(topic, peer):
        g.grafted(peer, topic)
        g.fanout.removePeer(topic, peer)
        grafts &= peer

  # get again npeers after possible grafts
  npeers = g.mesh.peers(topic)
  if npeers > g.parameters.dHigh:
    if not isNil(metrics):
      if g.knownTopics.contains(topic):
        libp2p_gossipsub_above_dhigh_condition.inc(labelValues = [topic])
      else:
        libp2p_gossipsub_above_dhigh_condition.inc(labelValues = ["other"])

    # prune peers if we've gone over Dhi
    prunes = toSeq(
      try:
        g.mesh[topic]
      except KeyError as e:
        raiseAssert "have peers: " & e.msg
    )
    # avoid pruning peers we are currently grafting in this heartbeat
    prunes.keepIf do(x: PubSubPeer) -> bool:
      x notin grafts

    # shuffle anyway, score might be not used
    g.rng.shuffle(prunes)

    # sort peers by score (inverted), pruning, so low score peers are on top
    prunes.sort(byScore, SortOrder.Ascending)

    # keep high score peers
    if prunes.len > g.parameters.dScore:
      prunes.setLen(prunes.len - g.parameters.dScore)

      # collect inbound/outbound info
      var outbound: seq[PubSubPeer]
      var inbound: seq[PubSubPeer]
      for peer in prunes:
        if peer.outbound:
          outbound &= peer
        else:
          inbound &= peer

      let
        meshOutbound = prunes.countIt(it.outbound)
        maxOutboundPrunes = meshOutbound - g.parameters.dOut

      # ensure that there are at least D_out peers first and rebalance to g.d after that
      outbound.setLen(min(outbound.len, max(0, maxOutboundPrunes)))

      # concat remaining outbound peers
      prunes = inbound & outbound

      let pruneLen = prunes.len - g.parameters.d
      if pruneLen > 0:
        # Ok we got some peers to prune,
        # for this heartbeat let's prune those
        g.rng.shuffle(prunes)
        prunes.setLen(pruneLen)

      trace "pruning", prunes = prunes.len
      for peer in prunes:
        trace "pruning peer on rebalance", peer, score = peer.score
        g.pruned(peer, topic)
        g.mesh.removePeer(topic, peer)

      backingOff = g.backingOff.getOrDefault(topic)

  # opportunistic grafting, by spec mesh should not be empty...
  if g.mesh.peers(topic) > 1:
    var peers = toSeq(
      try:
        g.mesh[topic]
      except KeyError as e:
        raiseAssert "have peers: " & e.msg
    )
    # grafting so high score has priority
    peers.sort(byScore, SortOrder.Descending)
    let medianIdx = peers.len div 2
    let median = peers[medianIdx]
    if median.score < g.parameters.opportunisticGraftThreshold:
      trace "median score below opportunistic threshold", score = median.score

      var
        avail: seq[PubSubPeer]
        currentMesh = addr defaultMesh
      g.mesh.withValue(topic, v):
        currentMesh = v
      g.gossipsub.withValue(topic, peerList):
        for it in peerList[]:
          if it.score >= median.score and # avoid negative score peers
          it notin currentMesh[] and
              # don't pick direct peers
              it.peerId notin g.parameters.directPeers and
              # and avoid peers we are backing off
              it.peerId notin backingOff:
            avail.add(it)

            # by spec, grab only up to MaxOpportunisticGraftPeers
            if avail.len >= MaxOpportunisticGraftPeers:
              break

      for peer in avail:
        if g.mesh.addPeer(topic, peer):
          g.grafted(peer, topic)
          grafts &= peer
          trace "opportunistic grafting", peer

  if not isNil(metrics):
    npeers = g.mesh.peers(topic)
    if npeers == 0:
      inc metrics[].noPeersTopics
    elif npeers < g.parameters.dLow:
      inc metrics[].lowPeersTopics
    else:
      inc metrics[].healthyPeersTopics

    var meshPeers = toSeq(g.mesh.getOrDefault(topic, initHashSet[PubSubPeer]()))
    meshPeers.keepIf do(x: PubSubPeer) -> bool:
      x.outbound
    if meshPeers.len < g.parameters.dOut:
      inc metrics[].underDoutTopics

    if g.knownTopics.contains(topic):
      libp2p_gossipsub_peers_per_topic_gossipsub.set(
        g.gossipsub.peers(topic).int64, labelValues = [topic]
      )

      libp2p_gossipsub_peers_per_topic_fanout.set(
        g.fanout.peers(topic).int64, labelValues = [topic]
      )

      libp2p_gossipsub_peers_per_topic_mesh.set(
        g.mesh.peers(topic).int64, labelValues = [topic]
      )
    else:
      metrics[].otherPeersPerTopicGossipsub += g.gossipsub.peers(topic).int64
      metrics[].otherPeersPerTopicFanout += g.fanout.peers(topic).int64
      metrics[].otherPeersPerTopicMesh += g.mesh.peers(topic).int64

  trace "mesh balanced"

  # Send changes to peers after table updates to avoid stale state
  if grafts.len > 0:
    let graft =
      RPCMsg(control: some(ControlMessage(graft: @[ControlGraft(topicID: topic)])))
    g.broadcast(grafts, graft, isHighPriority = true)
  if prunes.len > 0:
    let prune = RPCMsg(
      control: some(
        ControlMessage(
          prune:
            @[
              ControlPrune(
                topicID: topic,
                peers: g.peerExchangeList(topic),
                backoff: g.parameters.pruneBackoff.seconds.uint64,
              )
            ]
        )
      )
    )
    g.broadcast(prunes, prune, isHighPriority = true)

proc dropFanoutPeers*(g: GossipSub) =
  # drop peers that we haven't published to in
  # GossipSubFanoutTTL seconds
  let now = Moment.now()
  var drops: seq[string]
  for topic, val in g.lastFanoutPubSub:
    if now > val:
      g.fanout.del(topic)
      drops.add topic
      trace "dropping fanout topic", topic
  for topic in drops:
    g.lastFanoutPubSub.del topic

proc replenishFanout*(g: GossipSub, topic: string) =
  ## get fanout peers for a topic
  logScope:
    topic
  trace "about to replenish fanout"

  if g.fanout.peers(topic) < g.parameters.dLow:
    let currentMesh = g.mesh.getOrDefault(topic)
    trace "replenishing fanout", peers = g.fanout.peers(topic)
    for peer in g.gossipsub.getOrDefault(topic):
      if peer in currentMesh:
        continue
      if g.fanout.addPeer(topic, peer):
        if g.fanout.peers(topic) == g.parameters.d:
          break

  trace "fanout replenished with peers", peers = g.fanout.peers(topic)

proc getGossipPeers*(g: GossipSub): Table[PubSubPeer, ControlMessage] =
  ## gossip iHave messages to peers
  ##

  var cacheWindowSize = 0
  var control: Table[PubSubPeer, ControlMessage]

  let topics = toHashSet(toSeq(g.mesh.keys)) + toHashSet(toSeq(g.fanout.keys))
  trace "getting gossip peers (iHave)", ntopics = topics.len
  for topic in topics:
    if topic notin g.gossipsub:
      trace "topic not in gossip array, skipping", topic = topic
      continue

    let mids = g.mcache.window(topic)
    if not (mids.len > 0):
      trace "no messages to emit"
      continue

    var midsSeq = toSeq(mids)

    cacheWindowSize += midsSeq.len

    trace "got messages to emit", size = midsSeq.len

    # not in spec
    # similar to rust: https://github.com/sigp/rust-libp2p/blob/f53d02bc873fef2bf52cd31e3d5ce366a41d8a8c/protocols/gossipsub/src/behaviour.rs#L2101
    # and go https://github.com/libp2p/go-libp2p-pubsub/blob/08c17398fb11b2ab06ca141dddc8ec97272eb772/gossipsub.go#L582
    if midsSeq.len > IHaveMaxLength:
      g.rng.shuffle(midsSeq)
      midsSeq.setLen(IHaveMaxLength)

    let
      ihave = ControlIHave(topicID: topic, messageIDs: midsSeq)
      mesh = g.mesh.getOrDefault(topic)
      fanout = g.fanout.getOrDefault(topic)
      gossipPeers = mesh + fanout
    var allPeers = toSeq(g.gossipsub.getOrDefault(topic))

    allPeers.keepIf do(x: PubSubPeer) -> bool:
      x.peerId notin g.parameters.directPeers and x notin gossipPeers and
        x.score >= g.parameters.gossipThreshold

    # https://github.com/libp2p/specs/blob/98c5aa9421703fc31b0833ad8860a55db15be063/pubsub/gossipsub/gossipsub-v1.1.md#adaptive-gossip-dissemination
    let
      factor = (g.parameters.gossipFactor.float * allPeers.len.float).int
      target = max(g.parameters.dLazy, factor)

    if target < allPeers.len:
      g.rng.shuffle(allPeers)
      allPeers.setLen(target)

    for peer in allPeers:
      control.mgetOrPut(peer, ControlMessage()).ihave.add(ihave)
      for msgId in ihave.messageIDs:
        peer.sentIHaves[0].incl(msgId)

  libp2p_gossipsub_cache_window_size.set(cacheWindowSize.int64)

  return control

proc onHeartbeat(g: GossipSub) =
  # reset IWANT budget
  # reset IHAVE cap
  block:
    for peer in g.peers.values:
      peer.sentIHaves.addFirst(default(HashSet[MessageId]))
      if peer.sentIHaves.len > g.parameters.historyLength:
        discard peer.sentIHaves.popLast()
      peer.iDontWants.addFirst(default(HashSet[SaltedId]))
      if peer.iDontWants.len > g.parameters.historyLength:
        discard peer.iDontWants.popLast()
      peer.iHaveBudget = IHavePeerBudget
      peer.pingBudget = PingsPeerBudget

      when defined(libp2p_gossipsub_1_4):
        peer.preambleBudget = PreamblePeerBudget

  var meshMetrics = MeshMetrics()

  for t in toSeq(g.topics.keys):
    # remove expired backoffs
    block:
      handleBackingOff(g.backingOff, t)

    # prune every negative score peer
    # do this before relance
    # in order to avoid grafted -> pruned in the same cycle
    let meshPeers = g.mesh.getOrDefault(t)
    var prunes: seq[PubSubPeer]
    for peer in meshPeers:
      if peer.score < 0.0:
        trace "pruning negative score peer", peer, score = peer.score
        g.pruned(peer, t)
        g.mesh.removePeer(t, peer)
        prunes &= peer
    if prunes.len > 0:
      let prune = RPCMsg(
        control: some(
          ControlMessage(
            prune:
              @[
                ControlPrune(
                  topicID: t,
                  peers: g.peerExchangeList(t),
                  backoff: g.parameters.pruneBackoff.seconds.uint64,
                )
              ]
          )
        )
      )
      g.broadcast(prunes, prune, isHighPriority = true)

    # pass by ptr in order to both signal we want to update metrics
    # and as well update the struct for each topic during this iteration
    g.rebalanceMesh(t, addr meshMetrics)

  commitMetrics(meshMetrics)

  g.dropFanoutPeers()

  # replenish known topics to the fanout
  for t in toSeq(g.fanout.keys):
    g.replenishFanout(t)

  let peers = g.getGossipPeers()
  for peer, control in peers:
    # only ihave from here
    for ihave in control.ihave:
      if g.knownTopics.contains(ihave.topicID):
        libp2p_pubsub_broadcast_ihave.inc(labelValues = [ihave.topicID])
      else:
        libp2p_pubsub_broadcast_ihave.inc(labelValues = ["generic"])
    g.send(peer, RPCMsg(control: some(control)), isHighPriority = true)

  g.mcache.shift() # shift the cache

proc heartbeat*(g: GossipSub) {.async: (raises: [CancelledError]).} =
  heartbeat "GossipSub", g.parameters.heartbeatInterval:
    trace "running heartbeat", instance = cast[int](g)
    g.onHeartbeat()

    for trigger in g.heartbeatEvents:
      trace "firing heartbeat event", instance = cast[int](g)
      trigger.fire()

when defined(libp2p_gossipsub_1_4):
  proc preambleExpirationHeartbeat*(
      g: GossipSub
  ) {.async: (raises: [CancelledError]).} =
    heartbeat "GossipSub: Preamble Expiration", 200.milliseconds:
      trace "running preamble expiration heartbeat", instance = cast[int](g)

      while true:
        var expiredOngoingReceive = g.ongoingReceives.popExpired(Moment.now()).valueOr:
          break

        if not expiredOngoingReceive.sender.isNil:
          let sender = expiredOngoingReceive.sender
          if g.peers.hasKey(sender.peerId):
            sender.behaviourPenalty += 0.1

        if PullOperation:
          var possiblePeers = expiredOngoingReceive.possiblePeersToQuery()
          g.rng.shuffle(possiblePeers)

          var peer: PubSubPeer = nil
          for peerId in possiblePeers:
            try:
              if g.peers.hasKey(peerId) and g.peers[peerId].codec == GossipSubCodec_14:
                peer = g.peers[peerId]
                break
            except KeyError:
              assert false, "checked with hasKey"

          if peer.isNil:
            trace "no peer available to send IWANT for an expiredOngoingReceive",
              messageID = expiredOngoingReceive.messageId
            continue

          let starts = Moment.now()

          g.broadcast(
            @[peer],
            RPCMsg(
              control: some(
                ControlMessage(
                  iwant: @[ControlIWant(messageIDs: @[expiredOngoingReceive.messageId])]
                )
              )
            ),
            isHighPriority = true,
          )

          let bytesPerSecond = peer.bandwidthTracking.download.value()
          let transmissionTimeMs = calculateReceiveTimeMs(
            expiredOngoingReceive.messageLength.int64, bytesPerSecond.int64
          )
          let expires = starts + transmissionTimeMs.milliseconds

          # Setting new data before reinserting the preamble
          expiredOngoingReceive.startsAt = starts
          expiredOngoingReceive.expiresAt = expires
          expiredOngoingReceive.sender = peer
          g.ongoingIWantReceives[expiredOngoingReceive.messageId] =
            expiredOngoingReceive

      while true:
        let expiredOngoingIWantReceived = g.ongoingIWantReceives.popExpired(
          Moment.now()
        ).valueOr:
          break
        # TODO: use expiredOngoingIWantReceived
        # TODO: what should we do here?
