// SPDX-License-Identifier: MIT

import XCTest
@testable import WireRouteCore

final class AutomaticProfilePolicyTests: XCTestCase {
    private let home = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let mobile = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let office = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    func testTrustedWiFiTakesPriorityOverAssignmentAndFallback() {
        let policy = AutomaticProfilePolicy(
            isEnabled: true,
            defaultProfileID: home,
            otherWiFiTarget: .profile(mobile),
            trustedWiFiNames: ["Trusted"],
            wiFiAssignments: [AutomaticWiFiAssignment(ssid: "Trusted", target: .profile(office))]
        )

        XCTAssertEqual(
            policy.decide(transport: .wiFi, wiFiName: "Trusted", availableProfileIDs: [home, mobile, office]),
            .disconnect
        )
    }

    func testSpecificWiFiAssignmentTakesPriorityOverOtherWiFi() {
        let policy = AutomaticProfilePolicy(
            isEnabled: true,
            defaultProfileID: home,
            otherWiFiTarget: .profile(mobile),
            wiFiAssignments: [AutomaticWiFiAssignment(ssid: "Office", target: .profile(office))]
        )

        XCTAssertEqual(
            policy.decide(transport: .wiFi, wiFiName: "Office", availableProfileIDs: [home, mobile, office]),
            .connect(office)
        )
        XCTAssertEqual(
            policy.decide(transport: .wiFi, wiFiName: "Cafe", availableProfileIDs: [home, mobile, office]),
            .connect(mobile)
        )
    }

    func testUseDefaultResolvesToDefaultProfileOrVPNOff() {
        let enabled = AutomaticProfilePolicy(isEnabled: true, defaultProfileID: home)
        let off = AutomaticProfilePolicy(isEnabled: true, defaultProfileID: nil)

        XCTAssertEqual(
            enabled.decide(transport: .cellular, wiFiName: nil, availableProfileIDs: [home]),
            .connect(home)
        )
        XCTAssertEqual(
            off.decide(transport: .ethernet, wiFiName: nil, availableProfileIDs: [home]),
            .disconnect
        )
    }

    func testMissingProfileHoldsInsteadOfDisconnectingCurrentTunnel() {
        let policy = AutomaticProfilePolicy(
            isEnabled: true,
            defaultProfileID: home,
            cellularTarget: .profile(mobile)
        )

        XCTAssertEqual(
            policy.decide(transport: .cellular, wiFiName: nil, availableProfileIDs: [home]),
            .hold(.profileUnavailable(mobile))
        )
    }

    func testWiFiNameIsRequiredOnlyWhenRulesUseIt() {
        let basic = AutomaticProfilePolicy(isEnabled: true, defaultProfileID: home)
        let named = AutomaticProfilePolicy(
            isEnabled: true,
            defaultProfileID: home,
            trustedWiFiNames: ["Home"]
        )

        XCTAssertEqual(
            basic.decide(transport: .wiFi, wiFiName: nil, availableProfileIDs: [home]),
            .connect(home)
        )
        XCTAssertEqual(
            named.decide(transport: .wiFi, wiFiName: nil, availableProfileIDs: [home]),
            .hold(.wiFiNameUnavailable)
        )
    }

    func testValidationNormalizesNamesAndRejectsDuplicatesAcrossRuleTypes() throws {
        let normalized = try AutomaticProfilePolicy(
            trustedWiFiNames: ["  Home  "],
            wiFiAssignments: [AutomaticWiFiAssignment(ssid: "Office\n", target: .profile(office))]
        ).validated()

        XCTAssertEqual(normalized.trustedWiFiNames, ["Home"])
        XCTAssertEqual(normalized.wiFiAssignments.map(\.ssid), ["Office"])

        XCTAssertThrowsError(
            try AutomaticProfilePolicy(
                trustedWiFiNames: ["Home"],
                wiFiAssignments: [AutomaticWiFiAssignment(ssid: " Home ", target: .profile(office))]
            ).validated()
        ) { error in
            XCTAssertEqual(error as? AutomaticProfilePolicyError, .duplicateWiFiName("Home"))
        }
    }

    func testPolicyRoundTripsWithoutProfileNames() throws {
        let policy = AutomaticProfilePolicy(
            isEnabled: true,
            defaultProfileID: home,
            otherWiFiTarget: .profile(mobile),
            cellularTarget: .vpnOff,
            ethernetTarget: .useDefault,
            trustedWiFiNames: ["Home"],
            wiFiAssignments: [AutomaticWiFiAssignment(ssid: "Office", target: .profile(office))]
        )

        let data = try JSONEncoder().encode(policy)
        XCTAssertEqual(try JSONDecoder().decode(AutomaticProfilePolicy.self, from: data), policy)
    }

    func testReplacingProfileIdentifierUpdatesEveryReference() {
        let replacement = UUID()
        let policy = AutomaticProfilePolicy(
            isEnabled: true,
            defaultProfileID: home,
            otherWiFiTarget: .profile(home),
            cellularTarget: .profile(home),
            ethernetTarget: .profile(home),
            wiFiAssignments: [AutomaticWiFiAssignment(ssid: "Office", target: .profile(home))]
        ).replacingProfileID(home, with: replacement)

        XCTAssertEqual(policy.defaultProfileID, replacement)
        XCTAssertEqual(policy.otherWiFiTarget, .profile(replacement))
        XCTAssertEqual(policy.cellularTarget, .profile(replacement))
        XCTAssertEqual(policy.ethernetTarget, .profile(replacement))
        XCTAssertEqual(policy.wiFiAssignments.first?.target, .profile(replacement))
    }
}
