# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import sequtils, tables

import chronos, chronicles

import
  ./messages,
  ./rconn,
  ./utils,
  ../../../peerinfo,
  ../../../switch,
  ../../../multiaddress,
  ../../../multicodec,
  ../../../stream/connection,
  ../../../protocols/protocol,
  ../../../errors,
  ../../../utils/heartbeat,
  ../../../signed_envelope

# TODO:
# * Eventually replace std/times by chronos/timer. Currently chronos/timer
#   doesn't offer the possibility to get a datetime in UNIX UTC
# * Eventually add an access control list in the handleReserve, handleConnect
#   and handleHop
# * Better reservation management ie find a way to re-reserve when the end is nigh

import std/times
export chronicles

const
  RelayMsgSize* = 4096
  DefaultReservationTTL* = initDuration(hours = 1)
  DefaultLimitDuration* = 120
  DefaultLimitData* = 1 shl 17
  DefaultHeartbeatSleepTime* = 1
  MaxCircuit* = 128
  MaxCircuitPerPeer* = 16

logScope:
  topics = "libp2p relay"

type
  RelayV2Error* = object of LPError
  SendStopError = object of RelayV2Error

# Relay Side

type Relay* = ref object of LPProtocol
  switch*: Switch
  peerCount: CountTable[PeerId]

  # number of reservation (relayv2) + number of connection (relayv1)
  maxCircuit*: int

  maxCircuitPerPeer*: int
  msgSize*: int
  # RelayV1
  isCircuitRelayV1*: bool
  streamCount: int
  # RelayV2
  rsvp: Table[PeerId, DateTime]
  reservationLoop: Future[void]
  reservationTTL*: times.Duration
  heartbeatSleepTime*: uint32
  limit*: Limit

# Relay V2

proc createReserveResponse(
    r: Relay, pid: PeerId, expire: DateTime
): Result[HopMessage, CryptoError] =
  let
    expireUnix = expire.toTime.toUnix.uint64
    v = Voucher(
      relayPeerId: r.switch.peerInfo.peerId,
      reservingPeerId: pid,
      expiration: expireUnix,
    )
    sv = ?SignedVoucher.init(r.switch.peerInfo.privateKey, v)
    ma =
      ?MultiAddress.init("/p2p/" & $r.switch.peerInfo.peerId).orErr(
        CryptoError.KeyError
      )
    rsrv = Reservation(
      expire: expireUnix,
      addrs: r.switch.peerInfo.addrs.mapIt(?it.concat(ma).orErr(CryptoError.KeyError)),
      svoucher: Opt.some(?sv.encode),
    )
    msg = HopMessage(
      msgType: HopMessageType.Status,
      reservation: Opt.some(rsrv),
      limit: r.limit,
      status: Opt.some(Ok),
    )
  return ok(msg)

proc isRelayed*(conn: Connection): bool =
  var wrappedConn = conn
  while not isNil(wrappedConn):
    if wrappedConn of RelayConnection:
      return true
    wrappedConn = wrappedConn.getWrapped()
  return false

proc handleReserve(
    r: Relay, conn: Connection
) {.async: (raises: [CancelledError, LPStreamError]).} =
  if conn.isRelayed():
    trace "reservation attempt over relay connection", pid = conn.peerId
    await sendHopStatus(conn, PermissionDenied)
    return

  if r.peerCount[conn.peerId] + r.rsvp.len() >= r.maxCircuit:
    trace "Too many reservations", pid = conn.peerId
    await sendHopStatus(conn, ReservationRefused)
    return
  trace "reserving relay slot for", pid = conn.peerId
  let
    pid = conn.peerId
    expire = now().utc + r.reservationTTL
    msg = r.createReserveResponse(pid, expire).valueOr:
      trace "error signing the voucher", pid
      return

  r.rsvp[pid] = expire
  await conn.writeLp(encode(msg).buffer)

proc handleConnect(
    r: Relay, connSrc: Connection, msg: HopMessage
) {.async: (raises: [CancelledError, LPStreamError]).} =
  if connSrc.isRelayed():
    trace "connection attempt over relay connection"
    await sendHopStatus(connSrc, PermissionDenied)
    return
  let
    msgPeer = msg.peer.valueOr:
      await sendHopStatus(connSrc, MalformedMessage)
      return
    src = connSrc.peerId
    dst = msgPeer.peerId
  if dst notin r.rsvp:
    trace "refusing connection, no reservation", src, dst
    await sendHopStatus(connSrc, NoReservation)
    return

  r.peerCount.inc(src)
  r.peerCount.inc(dst)
  defer:
    r.peerCount.inc(src, -1)
    r.peerCount.inc(dst, -1)

  if r.peerCount[src] > r.maxCircuitPerPeer or r.peerCount[dst] > r.maxCircuitPerPeer:
    trace "too many connections",
      src = r.peerCount[src], dst = r.peerCount[dst], max = r.maxCircuitPerPeer
    await sendHopStatus(connSrc, ResourceLimitExceeded)
    return

  let connDst =
    try:
      await r.switch.dial(dst, RelayV2StopCodec)
    except CancelledError as exc:
      raise exc
    except DialFailedError as exc:
      trace "error opening relay stream", dst, description = exc.msg
      await sendHopStatus(connSrc, ConnectionFailed)
      return
  defer:
    await connDst.close()

  proc sendStopMsg() {.async: (raises: [SendStopError, CancelledError, LPStreamError]).} =
    let stopMsg = StopMessage(
      msgType: StopMessageType.Connect,
      peer: Opt.some(Peer(peerId: src, addrs: @[])),
      limit: r.limit,
    )
    await connDst.writeLp(encode(stopMsg).buffer)
    let msg = StopMessage.decode(await connDst.readLp(r.msgSize)).valueOr:
      raise newException(SendStopError, "Malformed message")
    if msg.msgType != StopMessageType.Status:
      raise
        newException(SendStopError, "Unexpected stop response, not a status message")
    if msg.status.get(UnexpectedMessage) != Ok:
      raise newException(SendStopError, "Relay stop failure")
    await connSrc.writeLp(
      encode(HopMessage(msgType: HopMessageType.Status, status: Opt.some(Ok))).buffer
    )

  try:
    await sendStopMsg()
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error sending stop message", description = exc.msg
    await sendHopStatus(connSrc, ConnectionFailed)
    return

  trace "relaying connection", src, dst
  let
    rconnSrc = RelayConnection.new(connSrc, r.limit.duration, r.limit.data)
    rconnDst = RelayConnection.new(connDst, r.limit.duration, r.limit.data)
  defer:
    await rconnSrc.close()
    await rconnDst.close()
  await bridge(rconnSrc, rconnDst)

proc handleHopStreamV2*(
    r: Relay, conn: Connection
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let msg = HopMessage.decode(await conn.readLp(r.msgSize)).valueOr:
    await sendHopStatus(conn, MalformedMessage)
    return
  trace "relayv2 handle stream", hopMsg = msg
  case msg.msgType
  of HopMessageType.Reserve:
    await r.handleReserve(conn)
  of HopMessageType.Connect:
    await r.handleConnect(conn, msg)
  else:
    trace "Unexpected relayv2 handshake", msgType = msg.msgType
    await sendHopStatus(conn, MalformedMessage)

# Relay V1

proc handleHop*(
    r: Relay, connSrc: Connection, msg: RelayMessage
) {.async: (raises: [CancelledError]).} =
  r.streamCount.inc()
  defer:
    r.streamCount.dec()
  if r.streamCount + r.rsvp.len() >= r.maxCircuit:
    trace "refusing connection; too many active circuit",
      streamCount = r.streamCount, rsvp = r.rsvp.len()
    await sendStatus(connSrc, StatusV1.HopCantSpeakRelay)
    return

  var src, dst: RelayPeer
  proc checkMsg(): Result[RelayMessage, StatusV1] =
    src = msg.srcPeer.valueOr:
      return err(StatusV1.HopSrcMultiaddrInvalid)
    if src.peerId != connSrc.peerId:
      return err(StatusV1.HopSrcMultiaddrInvalid)
    dst = msg.dstPeer.valueOr:
      return err(StatusV1.HopDstMultiaddrInvalid)
    if dst.peerId == r.switch.peerInfo.peerId:
      return err(StatusV1.HopCantRelayToSelf)
    if not r.switch.isConnected(dst.peerId):
      trace "relay not connected to dst", dst
      return err(StatusV1.HopNoConnToDst)
    ok(msg)

  let check = checkMsg()
  if check.isErr:
    await sendStatus(connSrc, check.error())
    return

  if r.peerCount[src.peerId] >= r.maxCircuitPerPeer or
      r.peerCount[dst.peerId] >= r.maxCircuitPerPeer:
    trace "refusing connection; too many connection from src or to dst", src, dst
    await sendStatus(connSrc, StatusV1.HopCantSpeakRelay)
    return
  r.peerCount.inc(src.peerId)
  r.peerCount.inc(dst.peerId)
  defer:
    r.peerCount.inc(src.peerId, -1)
    r.peerCount.inc(dst.peerId, -1)

  let connDst =
    try:
      await r.switch.dial(dst.peerId, RelayV1Codec)
    except CancelledError as exc:
      raise exc
    except DialFailedError as exc:
      trace "error opening relay stream", dst, description = exc.msg
      await sendStatus(connSrc, StatusV1.HopCantDialDst)
      return
  defer:
    await connDst.close()

  let msgToSend = RelayMessage(
    msgType: Opt.some(RelayType.Stop), srcPeer: Opt.some(src), dstPeer: Opt.some(dst)
  )

  let msgRcvFromDstOpt =
    try:
      await connDst.writeLp(encode(msgToSend).buffer)
      RelayMessage.decode(await connDst.readLp(r.msgSize))
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "error writing stop handshake or reading stop response",
        description = exc.msg
      await sendStatus(connSrc, StatusV1.HopCantOpenDstStream)
      return

  let msgRcvFromDst = msgRcvFromDstOpt.valueOr:
    trace "error reading stop response", response = msgRcvFromDstOpt
    await sendStatus(connSrc, StatusV1.HopCantOpenDstStream)
    return

  if msgRcvFromDst.msgType.get(RelayType.Stop) != RelayType.Status or
      msgRcvFromDst.status.get(StatusV1.StopRelayRefused) != StatusV1.Success:
    trace "unexcepted relay stop response", msgRcvFromDst
    await sendStatus(connSrc, StatusV1.HopCantOpenDstStream)
    return

  await sendStatus(connSrc, StatusV1.Success)
  trace "relaying connection", src, dst
  await bridge(connSrc, connDst)

proc handleStreamV1(
    r: Relay, conn: Connection
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let msg = RelayMessage.decode(await conn.readLp(r.msgSize)).valueOr:
    await sendStatus(conn, StatusV1.MalformedMessage)
    return
  trace "relay handle stream", msg

  let typ = msg.msgType.valueOr:
    trace "Message type not set"
    await sendStatus(conn, StatusV1.MalformedMessage)
    return
  case typ
  of RelayType.Hop:
    await r.handleHop(conn, msg)
  of RelayType.Stop:
    await sendStatus(conn, StatusV1.StopRelayRefused)
  of RelayType.CanHop:
    await sendStatus(conn, StatusV1.Success)
  else:
    trace "Unexpected relay handshake", msgType = msg.msgType
    await sendStatus(conn, StatusV1.MalformedMessage)

proc setup*(r: Relay, switch: Switch) =
  r.switch = switch
  r.switch.addPeerEventHandler(
    proc(peerId: PeerId, event: PeerEvent) {.async: (raises: [CancelledError]).} =
      r.rsvp.del(peerId),
    Left,
  )

proc new*(
    T: typedesc[Relay],
    reservationTTL: times.Duration = DefaultReservationTTL,
    limitDuration: uint32 = DefaultLimitDuration,
    limitData: uint64 = DefaultLimitData,
    heartbeatSleepTime: uint32 = DefaultHeartbeatSleepTime,
    maxCircuit: int = MaxCircuit,
    maxCircuitPerPeer: int = MaxCircuitPerPeer,
    msgSize: int = RelayMsgSize,
    circuitRelayV1: bool = false,
): T =
  let r = T(
    reservationTTL: reservationTTL,
    limit: Limit(duration: limitDuration, data: limitData),
    heartbeatSleepTime: heartbeatSleepTime,
    maxCircuit: maxCircuit,
    maxCircuitPerPeer: maxCircuitPerPeer,
    msgSize: msgSize,
    isCircuitRelayV1: circuitRelayV1,
  )

  proc handleStream(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      case proto
      of RelayV2HopCodec:
        await r.handleHopStreamV2(conn)
      of RelayV1Codec:
        await r.handleStreamV1(conn)
    except CancelledError as exc:
      trace "cancelled relayv2 handler"
      raise exc
    except CatchableError as exc:
      debug "exception in relayv2 handler", description = exc.msg, conn
    finally:
      trace "exiting relayv2 handler", conn
      await conn.close()

  r.codecs =
    if r.isCircuitRelayV1:
      @[RelayV1Codec]
    else:
      @[RelayV2HopCodec, RelayV1Codec]
  r.handler = handleStream
  r

proc deletesReservation(r: Relay) {.async: (raises: [CancelledError]).} =
  heartbeat "Reservation timeout", r.heartbeatSleepTime.seconds():
    try:
      let n = now().utc
      for k in toSeq(r.rsvp.keys):
        if n > r.rsvp[k]:
          r.rsvp.del(k)
    except KeyError:
      raiseAssert "checked with in"

method start*(r: Relay): Future[void] {.async: (raises: [CancelledError], raw: true).} =
  let fut = newFuture[void]()
  fut.complete()
  if not r.reservationLoop.isNil:
    warn "Starting relay twice"
    return fut
  r.reservationLoop = r.deletesReservation()
  r.started = true
  fut

method stop*(r: Relay): Future[void] {.async: (raises: [], raw: true).} =
  let fut = newFuture[void]()
  fut.complete()
  if r.reservationLoop.isNil:
    warn "Stopping relay without starting it"
    return fut
  r.started = false
  r.reservationLoop.cancelSoon()
  r.reservationLoop = nil
  fut
