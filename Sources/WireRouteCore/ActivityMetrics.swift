// SPDX-License-Identifier: MIT

import Foundation

public struct WireRouteActivityPeerCounters: Equatable, Sendable {
    public let peerIdentifier: String
    public let receivedBytes: UInt64
    public let sentBytes: UInt64
    public let lastHandshake: Date?

    public init(
        peerIdentifier: String,
        receivedBytes: UInt64,
        sentBytes: UInt64,
        lastHandshake: Date?
    ) {
        self.peerIdentifier = peerIdentifier
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
        self.lastHandshake = lastHandshake
    }
}

public struct WireRouteActivityDelta: Equatable, Sendable {
    public let receivedBytes: UInt64
    public let sentBytes: UInt64
    public let receivedBytesPerSecond: Double
    public let sentBytesPerSecond: Double
    public let totalReceivedBytes: UInt64
    public let totalSentBytes: UInt64
    public let lastHandshake: Date?

    public init(
        receivedBytes: UInt64,
        sentBytes: UInt64,
        receivedBytesPerSecond: Double,
        sentBytesPerSecond: Double,
        totalReceivedBytes: UInt64,
        totalSentBytes: UInt64,
        lastHandshake: Date?
    ) {
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
        self.receivedBytesPerSecond = receivedBytesPerSecond
        self.sentBytesPerSecond = sentBytesPerSecond
        self.totalReceivedBytes = totalReceivedBytes
        self.totalSentBytes = totalSentBytes
        self.lastHandshake = lastHandshake
    }
}

public struct WireRouteActivityAccumulator: Sendable {
    private struct PreviousCounters: Sendable {
        let receivedBytes: UInt64
        let sentBytes: UInt64
    }

    private var previousCounters = [String: PreviousCounters]()
    private var previousSampleDate: Date?
    private var totalReceivedBytes: UInt64 = 0
    private var totalSentBytes: UInt64 = 0

    public init() {}

    public mutating func sample(
        peers: [WireRouteActivityPeerCounters],
        at date: Date
    ) -> WireRouteActivityDelta {
        guard !peers.isEmpty else {
            return WireRouteActivityDelta(
                receivedBytes: 0,
                sentBytes: 0,
                receivedBytesPerSecond: 0,
                sentBytesPerSecond: 0,
                totalReceivedBytes: totalReceivedBytes,
                totalSentBytes: totalSentBytes,
                lastHandshake: nil
            )
        }
        var receivedDelta: UInt64 = 0
        var sentDelta: UInt64 = 0
        var nextCounters = [String: PreviousCounters]()

        for peer in peers {
            if let previous = previousCounters[peer.peerIdentifier] {
                receivedDelta = receivedDelta.addingWithoutOverflow(
                    counterDelta(current: peer.receivedBytes, previous: previous.receivedBytes)
                )
                sentDelta = sentDelta.addingWithoutOverflow(
                    counterDelta(current: peer.sentBytes, previous: previous.sentBytes)
                )
            } else {
                // WireGuard counters start at zero with the backend. Counting the first observed
                // value preserves traffic transferred before the first sampling interval fires.
                receivedDelta = receivedDelta.addingWithoutOverflow(peer.receivedBytes)
                sentDelta = sentDelta.addingWithoutOverflow(peer.sentBytes)
            }
            nextCounters[peer.peerIdentifier] = PreviousCounters(
                receivedBytes: peer.receivedBytes,
                sentBytes: peer.sentBytes
            )
        }

        let elapsed = previousSampleDate.map { max(date.timeIntervalSince($0), 0) }
        totalReceivedBytes = totalReceivedBytes.addingWithoutOverflow(receivedDelta)
        totalSentBytes = totalSentBytes.addingWithoutOverflow(sentDelta)
        previousCounters = nextCounters
        previousSampleDate = date

        return WireRouteActivityDelta(
            receivedBytes: receivedDelta,
            sentBytes: sentDelta,
            receivedBytesPerSecond: elapsed.map { $0 > 0 ? Double(receivedDelta) / $0 : 0 } ?? 0,
            sentBytesPerSecond: elapsed.map { $0 > 0 ? Double(sentDelta) / $0 : 0 } ?? 0,
            totalReceivedBytes: totalReceivedBytes,
            totalSentBytes: totalSentBytes,
            lastHandshake: peers.compactMap(\.lastHandshake).max()
        )
    }

    private func counterDelta(current: UInt64, previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : current
    }
}

public enum WireRouteActivityRuntimeParser {
    public static func peerCounters(from runtimeConfiguration: String) -> [WireRouteActivityPeerCounters] {
        var peers = [WireRouteActivityPeerCounters]()
        var peerIdentifier: String?
        var receivedBytes: UInt64 = 0
        var sentBytes: UInt64 = 0
        var handshakeSeconds: TimeInterval = 0
        var handshakeNanoseconds: TimeInterval = 0

        func appendCurrentPeer() {
            guard let peerIdentifier else { return }
            let handshakeInterval = handshakeSeconds + handshakeNanoseconds / 1_000_000_000
            peers.append(
                WireRouteActivityPeerCounters(
                    peerIdentifier: peerIdentifier,
                    receivedBytes: receivedBytes,
                    sentBytes: sentBytes,
                    lastHandshake: handshakeInterval > 0
                        ? Date(timeIntervalSince1970: handshakeInterval)
                        : nil
                )
            )
        }

        for line in runtimeConfiguration.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = String(pair[0])
            let value = String(pair[1])
            switch key {
            case "public_key":
                appendCurrentPeer()
                peerIdentifier = value
                receivedBytes = 0
                sentBytes = 0
                handshakeSeconds = 0
                handshakeNanoseconds = 0
            case "rx_bytes":
                receivedBytes = UInt64(value) ?? 0
            case "tx_bytes":
                sentBytes = UInt64(value) ?? 0
            case "last_handshake_time_sec":
                handshakeSeconds = TimeInterval(value) ?? 0
            case "last_handshake_time_nsec":
                handshakeNanoseconds = TimeInterval(value) ?? 0
            default:
                continue
            }
        }
        appendCurrentPeer()
        return peers
    }
}

public enum WireRouteProfileIdentifier {
    public static func derived(from stableValue: String) -> UUID {
        let bytes = Array(stableValue.utf8)
        var first = fnv1a(bytes, seed: 0xcbf29ce484222325)
        var second = fnv1a(bytes.reversed(), seed: 0x84222325cbf29ce4)
        var uuidBytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: &first) { uuidBytes.replaceSubrange(0 ..< 8, with: $0) }
        withUnsafeBytes(of: &second) { uuidBytes.replaceSubrange(8 ..< 16, with: $0) }
        uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x50
        uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
    }

    private static func fnv1a<S: Sequence>(_ bytes: S, seed: UInt64) -> UInt64 where S.Element == UInt8 {
        bytes.reduce(seed) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x100000001b3
        }
    }
}

private extension UInt64 {
    func addingWithoutOverflow(_ value: UInt64) -> UInt64 {
        let (result, overflow) = addingReportingOverflow(value)
        return overflow ? .max : result
    }
}
