# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import sequtils, strutils

import chronos, chronicles

import
  ./client,
  ./rconn,
  ./utils,
  ../../../switch,
  ../../../stream/connection,
  ../../../transports/transport

logScope:
  topics = "libp2p relay relay-transport"

type RelayTransport* = ref object of Transport
  client*: RelayClient
  queue: AsyncQueue[Connection]
  selfRunning: bool

method start*(
    self: RelayTransport, ma: seq[MultiAddress]
) {.async: (raises: [LPError, transport.TransportError, CancelledError]).} =
  if self.selfRunning:
    trace "Relay transport already running"
    return

  self.client.onNewConnection = proc(
      conn: Connection, duration: uint32 = 0, data: uint64 = 0
  ) {.async: (raises: [CancelledError]).} =
    await self.queue.addLast(RelayConnection.new(conn, duration, data))
    await conn.join()
  self.selfRunning = true
  await procCall Transport(self).start(ma)
  trace "Starting Relay transport"

method stop*(self: RelayTransport) {.async: (raises: []).} =
  self.running = false
  self.selfRunning = false
  self.client.onNewConnection = nil
  while not self.queue.empty():
    try:
      await self.queue.popFirstNoWait().close()
    except AsyncQueueEmptyError:
      continue # checked with self.queue.empty()

method accept*(
    self: RelayTransport
): Future[Connection] {.async: (raises: [transport.TransportError, CancelledError]).} =
  result = await self.queue.popFirst()

proc dial*(
    self: RelayTransport, ma: MultiAddress
): Future[Connection] {.async: (raises: [RelayDialError, CancelledError]).} =
  var
    relayAddrs: MultiAddress
    relayPeerId: PeerId
    dstPeerId: PeerId

  try:
    let sma = toSeq(ma.items())
    relayAddrs = sma[0 .. sma.len - 4].mapIt(it.tryGet()).foldl(a & b)
    if not relayPeerId.init(($(sma[^3].tryGet())).split('/')[2]):
      raise newException(RelayDialError, "Relay doesn't exist")
    if not dstPeerId.init(($(sma[^1].tryGet())).split('/')[2]):
      raise newException(RelayDialError, "Destination doesn't exist")
  except RelayDialError as e:
    raise newException(RelayDialError, "dial address not valid: " & e.msg, e)
  except CatchableError:
    raise newException(RelayDialError, "dial address not valid")

  trace "Dial", relayPeerId, dstPeerId

  var rc: RelayConnection
  try:
    let conn = await self.client.switch.dial(
      relayPeerId, @[relayAddrs], @[RelayV2HopCodec, RelayV1Codec]
    )
    conn.dir = Direction.Out

    case conn.protocol
    of RelayV1Codec:
      return await self.client.dialPeerV1(conn, dstPeerId, @[])
    of RelayV2HopCodec:
      rc = RelayConnection.new(conn, 0, 0)
      return await self.client.dialPeerV2(rc, dstPeerId, @[])
  except CancelledError as e:
    safeClose(rc)
    raise e
  except DialFailedError as e:
    safeClose(rc)
    raise newException(RelayDialError, "dial relay peer failed: " & e.msg, e)
  except RelayV1DialError as e:
    safeClose(rc)
    raise newException(RelayV1DialError, "dial relay v1 failed: " & e.msg, e)
  except RelayV2DialError as e:
    safeClose(rc)
    raise newException(RelayV2DialError, "dial relay v2 failed: " & e.msg, e)

method dial*(
    self: RelayTransport,
    hostname: string,
    ma: MultiAddress,
    peerId: Opt[PeerId] = Opt.none(PeerId),
): Future[Connection] {.async: (raises: [transport.TransportError, CancelledError]).} =
  peerId.withValue(pid):
    try:
      let address = MultiAddress.init($ma & "/p2p/" & $pid).tryGet()
      result = await self.dial(address)
    except CancelledError as e:
      raise e
    except CatchableError as e:
      raise
        newException(transport.TransportDialError, "Caught error in dial: " & e.msg, e)

method handles*(self: RelayTransport, ma: MultiAddress): bool {.gcsafe.} =
  try:
    if ma.protocols.isOk():
      let sma = toSeq(ma.items())
      result = sma.len >= 2 and CircuitRelay.match(sma[^1].tryGet())
  except CatchableError as exc:
    result = false
  trace "Handles return", ma, result

proc new*(T: typedesc[RelayTransport], cl: RelayClient, upgrader: Upgrade): T =
  result = T(client: cl, upgrader: upgrader)
  result.running = true
  result.queue = newAsyncQueue[Connection](0)
