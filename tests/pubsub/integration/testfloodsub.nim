# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import sequtils, tables, sets
import chronos, stew/byteutils
import
  ../utils,
  ../../../libp2p/[
    switch,
    stream/connection,
    crypto/crypto,
    protocols/pubsub/pubsub,
    protocols/pubsub/floodsub,
    protocols/pubsub/rpc/messages,
    protocols/pubsub/peertable,
    protocols/pubsub/pubsubpeer,
  ]
import ../../../libp2p/protocols/pubsub/errors as pubsub_errors

import ../../helpers

proc waitSub(sender, receiver: auto, key: string) {.async.} =
  # turn things deterministic
  # this is for testing purposes only
  var ceil = 15
  let fsub = cast[FloodSub](sender)
  while not fsub.floodsub.hasKey(key) or
      not fsub.floodsub.hasPeerId(key, receiver.peerInfo.peerId):
    await sleepAsync(100.millis)
    dec ceil
    doAssert(ceil > 0, "waitSub timeout!")

suite "FloodSub Integration":
  teardown:
    checkTrackers()

  asyncTest "FloodSub basic publish/subscribe A -> B":
    var completionFut = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"
      completionFut.complete(true)

    let nodes = generateNodes(2)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe("foobar", handler)
    await waitSub(nodes[0], nodes[1], "foobar")

    check (await nodes[0].publish("foobar", "Hello!".toBytes())) > 0
    check (await completionFut.wait(5.seconds)) == true

    when defined(libp2p_agents_metrics):
      let
        agentA = nodes[0].peers[nodes[1].switch.peerInfo.peerId].shortAgent
        agentB = nodes[1].peers[nodes[0].switch.peerInfo.peerId].shortAgent
      check:
        agentA == "nim-libp2p"
        agentB == "nim-libp2p"

  asyncTest "FloodSub basic publish/subscribe B -> A":
    var completionFut = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"
      completionFut.complete(true)

    let nodes = generateNodes(2)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[0].subscribe("foobar", handler)
    await waitSub(nodes[1], nodes[0], "foobar")

    check (await nodes[1].publish("foobar", "Hello!".toBytes())) > 0
    check (await completionFut.wait(5.seconds)) == true

  asyncTest "FloodSub validation should succeed":
    var handlerFut = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"
      handlerFut.complete(true)

    let nodes = generateNodes(2)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe("foobar", handler)
    await waitSub(nodes[0], nodes[1], "foobar")

    var validatorFut = newFuture[bool]()
    proc validator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      check topic == "foobar"
      validatorFut.complete(true)
      result = ValidationResult.Accept

    nodes[1].addValidator("foobar", validator)

    check (await nodes[0].publish("foobar", "Hello!".toBytes())) > 0
    check (await handlerFut) == true

  asyncTest "FloodSub validation should fail":
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check false # if we get here, it should fail

    let nodes = generateNodes(2)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe("foobar", handler)
    await waitSub(nodes[0], nodes[1], "foobar")

    var validatorFut = newFuture[bool]()
    proc validator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      validatorFut.complete(true)
      result = ValidationResult.Reject

    nodes[1].addValidator("foobar", validator)

    discard await nodes[0].publish("foobar", "Hello!".toBytes())

  asyncTest "FloodSub validation one fails and one succeeds":
    var handlerFut = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foo"
      handlerFut.complete(true)

    let nodes = generateNodes(2)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe("foo", handler)
    await waitSub(nodes[0], nodes[1], "foo")
    nodes[1].subscribe("bar", handler)
    await waitSub(nodes[0], nodes[1], "bar")

    proc validator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      if topic == "foo":
        result = ValidationResult.Accept
      else:
        result = ValidationResult.Reject

    nodes[1].addValidator("foo", "bar", validator)

    check (await nodes[0].publish("foo", "Hello!".toBytes())) > 0
    check (await nodes[0].publish("bar", "Hello!".toBytes())) > 0

  asyncTest "FloodSub multiple peers, no self trigger":
    var runs = 10

    var futs = newSeq[(Future[void], TopicHandler, ref int)](runs)
    for i in 0 ..< runs:
      closureScope:
        var
          fut = newFuture[void]()
          counter = new int
        futs[i] = (
          fut,
          (
            proc(topic: string, data: seq[byte]) {.async.} =
              check topic == "foobar"
              inc counter[]
              if counter[] == runs - 1:
                fut.complete()
          ),
          counter,
        )

    let nodes = generateNodes(runs, triggerSelf = false)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    for i in 0 ..< runs:
      nodes[i].subscribe("foobar", futs[i][1])

    var subs: seq[Future[void]]
    for i in 0 ..< runs:
      for y in 0 ..< runs:
        if y != i:
          subs &= waitSub(nodes[i], nodes[y], "foobar")
    await allFuturesThrowing(subs)

    var pubs: seq[Future[int]]
    for i in 0 ..< runs:
      pubs &= nodes[i].publish("foobar", ("Hello!" & $i).toBytes())
    await allFuturesThrowing(pubs)

    await allFuturesThrowing(futs.mapIt(it[0]))

  asyncTest "FloodSub multiple peers, with self trigger":
    var runs = 10

    var futs = newSeq[(Future[void], TopicHandler, ref int)](runs)
    for i in 0 ..< runs:
      closureScope:
        var
          fut = newFuture[void]()
          counter = new int
        futs[i] = (
          fut,
          (
            proc(topic: string, data: seq[byte]) {.async.} =
              check topic == "foobar"
              inc counter[]
              if counter[] == runs - 1:
                fut.complete()
          ),
          counter,
        )

    let nodes = generateNodes(runs, triggerSelf = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    for i in 0 ..< runs:
      nodes[i].subscribe("foobar", futs[i][1])

    var subs: seq[Future[void]]
    for i in 0 ..< runs:
      for y in 0 ..< runs:
        if y != i:
          subs &= waitSub(nodes[i], nodes[y], "foobar")
    await allFuturesThrowing(subs)

    var pubs: seq[Future[int]]
    for i in 0 ..< runs:
      pubs &= nodes[i].publish("foobar", ("Hello!" & $i).toBytes())
    await allFuturesThrowing(pubs)

    # wait the test task
    await allFuturesThrowing(futs.mapIt(it[0]))

    # test calling unsubscribeAll for coverage
    for node in nodes:
      node.unsubscribeAll("foobar")
      check:
        # we keep the peers in table
        FloodSub(node).floodsub["foobar"].len == 9
        # remove the topic tho
        node.topics.len == 0

  asyncTest "FloodSub message size validation":
    var messageReceived = 0
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check data.len < 50
      inc(messageReceived)

    let
      bigNode = generateNodes(1)
      smallNode = generateNodes(1, maxMessageSize = 200)

    startNodesAndDeferStop(bigNode & smallNode)
    await connectNodesStar(bigNode & smallNode)

    bigNode[0].subscribe("foo", handler)
    smallNode[0].subscribe("foo", handler)
    await waitSub(bigNode[0], smallNode[0], "foo")

    let
      bigMessage = newSeq[byte](1000)
      smallMessage1 = @[1.byte]
      smallMessage2 = @[3.byte]

    # Need two different messages, otherwise they are the same when anonymized
    check (await smallNode[0].publish("foo", smallMessage1)) > 0
    check (await bigNode[0].publish("foo", smallMessage2)) > 0

    checkUntilTimeout:
      messageReceived == 2

    check (await smallNode[0].publish("foo", bigMessage)) > 0
    check (await bigNode[0].publish("foo", bigMessage)) > 0

  asyncTest "FloodSub message size validation 2":
    var messageReceived = 0
    proc handler(topic: string, data: seq[byte]) {.async.} =
      inc(messageReceived)

    let
      bigNode1 = generateNodes(1, maxMessageSize = 20000000)
      bigNode2 = generateNodes(1, maxMessageSize = 20000000)

    startNodesAndDeferStop(bigNode1 & bigNode2)
    await connectNodesStar(bigNode1 & bigNode2)

    bigNode2[0].subscribe("foo", handler)
    await waitSub(bigNode1[0], bigNode2[0], "foo")

    let bigMessage = newSeq[byte](19000000)

    check (await bigNode1[0].publish("foo", bigMessage)) > 0

    checkUntilTimeoutCustom(10.seconds, 100.milliseconds):
      messageReceived == 1
