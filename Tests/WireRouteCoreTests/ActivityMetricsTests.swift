// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import WireRouteCore

final class ActivityMetricsTests: XCTestCase {
    func testParsesPeerCountersFromRuntimeConfiguration() {
        let runtimeConfiguration = """
        private_key=hidden
        listen_port=51820
        public_key=peer-one
        rx_bytes=1200
        tx_bytes=3400
        last_handshake_time_sec=1700000000
        last_handshake_time_nsec=500000000
        public_key=peer-two
        rx_bytes=50
        tx_bytes=75
        last_handshake_time_sec=0
        last_handshake_time_nsec=0
        errno=0
        """

        let peers = WireRouteActivityRuntimeParser.peerCounters(from: runtimeConfiguration)

        XCTAssertEqual(peers.count, 2)
        XCTAssertEqual(peers[0].peerIdentifier, "peer-one")
        XCTAssertEqual(peers[0].receivedBytes, 1200)
        XCTAssertEqual(peers[0].sentBytes, 3400)
        XCTAssertEqual(peers[0].lastHandshake, Date(timeIntervalSince1970: 1_700_000_000.5))
        XCTAssertEqual(peers[1].peerIdentifier, "peer-two")
        XCTAssertNil(peers[1].lastHandshake)
    }

    func testAggregatesPeersAndCalculatesRates() {
        var accumulator = WireRouteActivityAccumulator()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let first = accumulator.sample(
            peers: [
                peer("one", received: 100, sent: 200),
                peer("two", received: 50, sent: 25)
            ],
            at: start
        )
        XCTAssertEqual(first.receivedBytes, 150)
        XCTAssertEqual(first.sentBytes, 225)
        XCTAssertEqual(first.totalReceivedBytes, 150)
        XCTAssertEqual(first.totalSentBytes, 225)

        let second = accumulator.sample(
            peers: [
                peer("one", received: 300, sent: 300),
                peer("two", received: 150, sent: 125)
            ],
            at: start.addingTimeInterval(5)
        )
        XCTAssertEqual(second.receivedBytes, 300)
        XCTAssertEqual(second.sentBytes, 200)
        XCTAssertEqual(second.receivedBytesPerSecond, 60)
        XCTAssertEqual(second.sentBytesPerSecond, 40)
        XCTAssertEqual(second.totalReceivedBytes, 450)
        XCTAssertEqual(second.totalSentBytes, 425)
    }

    func testHandlesCounterResetAndPeerReplacement() {
        var accumulator = WireRouteActivityAccumulator()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = accumulator.sample(
            peers: [peer("one", received: 1000, sent: 2000)],
            at: start
        )

        let reset = accumulator.sample(
            peers: [peer("one", received: 25, sent: 50)],
            at: start.addingTimeInterval(5)
        )
        XCTAssertEqual(reset.receivedBytes, 25)
        XCTAssertEqual(reset.sentBytes, 50)

        let replacement = accumulator.sample(
            peers: [peer("two", received: 10, sent: 20)],
            at: start.addingTimeInterval(10)
        )
        XCTAssertEqual(replacement.receivedBytes, 10)
        XCTAssertEqual(replacement.sentBytes, 20)
    }

    func testEmptySampleDoesNotResetPeerBaselines() {
        var accumulator = WireRouteActivityAccumulator()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = accumulator.sample(
            peers: [peer("one", received: 100, sent: 200)],
            at: start
        )
        let empty = accumulator.sample(peers: [], at: start.addingTimeInterval(5))
        XCTAssertEqual(empty.receivedBytes, 0)
        XCTAssertEqual(empty.totalReceivedBytes, 100)

        let resumed = accumulator.sample(
            peers: [peer("one", received: 150, sent: 275)],
            at: start.addingTimeInterval(10)
        )
        XCTAssertEqual(resumed.receivedBytes, 50)
        XCTAssertEqual(resumed.sentBytes, 75)
    }

    func testDerivedProfileIdentifierIsStableAndDistinct() {
        let first = WireRouteProfileIdentifier.derived(from: "profile-public-key")
        XCTAssertEqual(first, WireRouteProfileIdentifier.derived(from: "profile-public-key"))
        XCTAssertNotEqual(first, WireRouteProfileIdentifier.derived(from: "different-public-key"))
    }

    private func peer(
        _ identifier: String,
        received: UInt64,
        sent: UInt64
    ) -> WireRouteActivityPeerCounters {
        WireRouteActivityPeerCounters(
            peerIdentifier: identifier,
            receivedBytes: received,
            sentBytes: sent,
            lastHandshake: nil
        )
    }
}
