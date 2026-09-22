// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import NetworkExtension
import XCTest
@testable import WireRouteCore

@MainActor
final class MacOSVPNRegistrationRepairTests: XCTestCase {
    private typealias Repair = MacOSVPNRegistrationRepair
    private let providerID = "test.wireroute.network-extension"
    private let uid: UInt32 = 501

    private func profile(controller: Bool = false) -> NETunnelProviderManager {
        let manager = NETunnelProviderManager()
        manager.localizedDescription = controller ? "Automatic Profiles" : "Fixture"
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerID
        proto.serverAddress = "192.0.2.1:51820"
        proto.passwordReference = controller ? nil : Data("opaque-fixture-reference".utf8)
        proto.providerConfiguration = [
            "UID": uid,
            "WireRouteActivityProfileIdentifier": UUID().uuidString,
            "WireRouteAutomaticProfilesController": controller,
            "WireRouteDNSProtection": ["mode": "encryptedHTTPS", "bootstrapServers": ["192.0.2.2"]],
            "WireRouteRoutingMode": "split",
            "WireRouteSplitAllowedIPs": ["10.0.0.0/8"],
            "futureMetadata": Data([1, 2, 3])
        ]
        proto.disconnectOnSleep = true
        proto.includeAllNetworks = true
        proto.excludeLocalNetworks = true
        proto.enforceRoutes = true
        proto.excludeCellularServices = false
        proto.excludeAPNs = false
        if #available(macOS 14.4, *) { proto.excludeDeviceCommunication = false }
        let proxy = NEProxySettings()
        proxy.exceptionList = ["fixture.invalid"]
        proto.proxySettings = proxy
        manager.protocolConfiguration = proto
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .wiFi
        rule.ssidMatch = ["Test network"]
        manager.onDemandRules = [rule, NEOnDemandRuleDisconnect()]
        manager.isOnDemandEnabled = true
        manager.isEnabled = true
        return manager
    }

    func testOnlyExactPreProviderErrorIsEligible() {
        XCTAssertTrue(Repair.isProviderUnavailable(NSError(domain: NEVPNConnectionErrorDomain, code: 14)))
        XCTAssertFalse(Repair.isProviderUnavailable(NSError(domain: "PacketTunnelProviderError", code: 0)))
        XCTAssertFalse(Repair.isProviderUnavailable(NSError(domain: NSOSStatusErrorDomain, code: 14)))
        XCTAssertFalse(Repair.isProviderUnavailable(NSError(domain: NEVPNConnectionErrorDomain, code: 1)))
    }

    func testVerifiedReplacementKeepsKeysRulesAndPolicies() async throws {
        for controller in [false, true] {
            let original = profile(controller: controller)
            let settings = try Repair.Settings(original)
            let fixture = Fixture(original)
            let replacement = try await Repair.repair(original, providerID: providerID, ownerUID: uid, store: fixture.store)
            XCTAssertTrue(settings.matches(replacement))
            XCTAssertTrue(replacement.isEnabled)
            XCTAssertFalse(Repair.isStaged(replacement))
            XCTAssertEqual(fixture.saved.count, 1)
            XCTAssertFalse(fixture.contains(original))
            XCTAssertEqual(fixture.events, ["load-original", "list", "save-staged", "load-replacement",
                                           "load-original", "remove-original", "save-final", "load-replacement"])
        }
    }

    func testSaveDenialAndReadbackFailureNeverRemoveOriginal() async throws {
        for failEvent in ["save-staged", "load-replacement"] {
            let original = profile()
            let fixture = Fixture(original)
            fixture.fail = { $0 == failEvent }
            await expectFailure { try await Repair.repair(original, providerID: providerID, ownerUID: uid, store: fixture.store) }
            XCTAssertTrue(fixture.contains(original))
            XCTAssertFalse(fixture.events.contains("remove-original"))
        }
    }

    func testMismatchedReadbackNeverRemovesOriginal() async throws {
        let original = profile()
        let fixture = Fixture(original)
        fixture.afterLoad = { manager in
            if manager !== original {
                (manager.protocolConfiguration as? NETunnelProviderProtocol)?.passwordReference = Data([9])
            }
        }
        await expectFailure { try await Repair.repair(original, providerID: providerID, ownerUID: uid, store: fixture.store) }
        XCTAssertTrue(fixture.contains(original))
        XCTAssertFalse(fixture.events.contains("remove-original"))
    }

    func testChangedSettingsAndConnectionDuringRepairAreProtected() async throws {
        for becomeActive in [false, true] {
            let original = profile()
            let fixture = Fixture(original)
            fixture.afterLoad = { manager in
                if manager === original && fixture.events.filter({ $0 == "load-original" }).count == 2 {
                    if becomeActive { fixture.active.insert(ObjectIdentifier(original)) }
                    else { manager.localizedDescription = "User edited this" }
                }
            }
            await expectFailure { try await Repair.repair(original, providerID: providerID, ownerUID: uid, store: fixture.store) }
            XCTAssertTrue(fixture.contains(original))
            XCTAssertFalse(fixture.events.contains("remove-original"))
        }
    }

    func testActiveOrForeignRegistrationIsNeverSaved() async throws {
        for mode in 0..<3 {
            let original = profile()
            let fixture = Fixture(original)
            if mode == 0 { fixture.active.insert(ObjectIdentifier(original)) }
            await expectFailure {
                try await Repair.repair(original, providerID: mode == 1 ? "different.app" : providerID,
                                        ownerUID: mode == 2 ? 502 : uid, store: fixture.store)
            }
            XCTAssertFalse(fixture.events.contains(where: { $0.hasPrefix("save") || $0.hasPrefix("remove") }))
        }
    }

    func testRemovalDenialRollsBackStagedRegistrationOnly() async throws {
        let original = profile()
        let fixture = Fixture(original)
        fixture.fail = { $0 == "remove-original" }
        await expectFailure { try await Repair.repair(original, providerID: providerID, ownerUID: uid, store: fixture.store) }
        XCTAssertTrue(fixture.contains(original))
        XCTAssertEqual(fixture.saved.count, 1)
        XCTAssertTrue(fixture.events.contains("remove-replacement"))
    }

    func testFailedRollbackIsHiddenAndExplicitRetryReusesStaging() async throws {
        let original = profile()
        let fixture = Fixture(original)
        fixture.fail = { $0.hasPrefix("remove") }
        await expectFailure { try await Repair.repair(original, providerID: providerID, ownerUID: uid, store: fixture.store) }
        XCTAssertEqual(fixture.saved.count, 2)
        let reopened = fixture.reopen()
        XCTAssertEqual(Repair.visibleManagers(reopened).count, 1)
        let pending = Repair.pendingReplacements(for: original, in: reopened)
        XCTAssertEqual(pending.count, 1)
        XCTAssertFalse(pending[0].isEnabled)
        fixture.fail = { _ in false }
        let result = try await Repair.repair(original, providerID: providerID, ownerUID: uid, store: fixture.store)
        XCTAssertEqual(fixture.saved.count, 1)
        XCTAssertTrue(result === pending[0])
    }

    func testFinalSaveFailureKeepsVerifiedReplacementAndCanResume() async throws {
        let original = profile()
        let fixture = Fixture(original)
        fixture.fail = { $0 == "save-final" }
        await expectFailure { try await Repair.repair(original, providerID: providerID, ownerUID: uid, store: fixture.store) }
        XCTAssertFalse(fixture.contains(original))
        let reopened = Repair.visibleManagers(fixture.reopen())
        XCTAssertEqual(reopened.count, 1)
        XCTAssertTrue(Repair.isStaged(reopened[0]))
        XCTAssertFalse(reopened[0].isEnabled)
        XCTAssertTrue(reopened[0].isOnDemandEnabled)
        fixture.fail = { _ in false }
        let removedBefore = fixture.events.filter { $0.hasPrefix("remove") }.count
        let result = try await Repair.repair(reopened[0], providerID: providerID, ownerUID: uid, store: fixture.store)
        XCTAssertTrue(result.isEnabled)
        XCTAssertEqual(fixture.events.filter { $0.hasPrefix("remove") }.count, removedBefore)
    }

    func testUncertainRemovalNeverDeletesSurvivingReplacement() async throws {
        let original = profile()
        let fixture = Fixture(original)
        fixture.removeThenFail = true
        await expectFailure { try await Repair.repair(original, providerID: providerID, ownerUID: uid, store: fixture.store) }
        XCTAssertFalse(fixture.contains(original))
        XCTAssertEqual(fixture.saved.count, 1)
        XCTAssertFalse(fixture.events.contains("remove-replacement"))
    }

    func testVisibilityDoesNotHideUnrelatedProfilesOrUsers() throws {
        let original = profile()
        let staged = NETunnelProviderManager()
        try Repair.Settings(original).apply(to: staged, staged: true)
        let other = profile()
        XCTAssertEqual(Repair.visibleManagers([original, staged, other]).count, 2)
        (staged.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["UID"] = 502
        XCTAssertEqual(Repair.visibleManagers([original, staged, other]).count, 3)
    }

    func testAmbiguousOriginalsAreNotGuessedAt() async throws {
        let original = profile()
        let fixture = Fixture(original)
        let duplicate = NETunnelProviderManager()
        try Repair.Settings(original).apply(to: duplicate, staged: false)
        duplicate.localizedDescription = "Another copy"
        fixture.saved[ObjectIdentifier(duplicate)] = Fixture.Record(duplicate)
        await expectFailure { try await Repair.repair(original, providerID: providerID, ownerUID: uid, store: fixture.store) }
        XCTAssertEqual(fixture.saved.count, 2)
        XCTAssertFalse(fixture.events.contains(where: { $0.hasPrefix("save") || $0.hasPrefix("remove") }))
    }

    func testFailedEnumerationDoesNotWriteAnything() async throws {
        let original = profile()
        let fixture = Fixture(original)
        fixture.fail = { $0 == "list" }
        await expectFailure { try await Repair.repair(original, providerID: providerID, ownerUID: uid, store: fixture.store) }
        XCTAssertEqual(fixture.events, ["load-original", "list"])
        XCTAssertTrue(fixture.contains(original))
    }

    func testFinalReadbackFailureRetainsSavedReplacement() async throws {
        let original = profile()
        let fixture = Fixture(original)
        fixture.fail = { $0 == "load-replacement" && fixture.events.contains("save-final") }
        await expectFailure { try await Repair.repair(original, providerID: providerID, ownerUID: uid, store: fixture.store) }
        XCTAssertEqual(fixture.saved.count, 1)
        XCTAssertFalse(fixture.contains(original))
        let reopened = fixture.reopen()
        XCTAssertTrue(reopened[0].isEnabled)
        XCTAssertFalse(Repair.isStaged(reopened[0]))
        XCTAssertFalse(fixture.events.contains("remove-replacement"))
    }

    private func expectFailure(_ action: () async throws -> NETunnelProviderManager) async {
        do { _ = try await action(); XCTFail("Expected repair to stop") }
        catch { /* Failure must leave safe persisted state, asserted by each caller. */ }
    }

    /// In-memory preference store: never calls any system save/load/remove API.
    @MainActor private final class Fixture {
        struct Record {
            let manager: NETunnelProviderManager
            let proto: NEVPNProtocol?
            let name: String?
            let enabled: Bool
            let onDemand: Bool
            let rules: [NEOnDemandRule]?

            init(_ manager: NETunnelProviderManager) {
                self.manager = manager
                proto = manager.protocolConfiguration?.copy() as? NEVPNProtocol
                name = manager.localizedDescription
                enabled = manager.isEnabled
                onDemand = manager.isOnDemandEnabled
                rules = manager.onDemandRules
            }

            func restore() {
                manager.protocolConfiguration = proto?.copy() as? NEVPNProtocol
                manager.localizedDescription = name
                manager.isEnabled = enabled
                manager.isOnDemandEnabled = onDemand
                manager.onDemandRules = rules
            }
        }
        let original: NETunnelProviderManager
        var saved: [ObjectIdentifier: Record] = [:]
        var active: Set<ObjectIdentifier> = []
        var events = [String]()
        var fail: (String) -> Bool = { _ in false }
        var afterLoad: (NETunnelProviderManager) -> Void = { _ in }
        var removeThenFail = false

        init(_ original: NETunnelProviderManager) {
            self.original = original
            saved[ObjectIdentifier(original)] = Record(original)
        }
        func contains(_ manager: NETunnelProviderManager) -> Bool { saved[ObjectIdentifier(manager)] != nil }
        func event(_ name: String) throws {
            events.append(name)
            if fail(name) { throw NSError(domain: "fixture.denied", code: 1) }
        }
        func reopen() -> [NETunnelProviderManager] {
            saved.values.map { $0.restore(); return $0.manager }
        }
        var store: Repair.Store {
            Repair.Store(
                loadAll: { try self.event("list"); return self.reopen() },
                load: { manager in
                    try self.event(manager === self.original ? "load-original" : "load-replacement")
                    guard let record = self.saved[ObjectIdentifier(manager)] else { throw Repair.Failure.unavailable }
                    record.restore()
                    self.afterLoad(manager)
                },
                save: { manager in
                    try self.event(Repair.isStaged(manager) ? "save-staged" : "save-final")
                    self.saved[ObjectIdentifier(manager)] = Record(manager)
                },
                remove: { manager in
                    try self.event(manager === self.original ? "remove-original" : "remove-replacement")
                    self.saved.removeValue(forKey: ObjectIdentifier(manager))
                    if manager === self.original && self.removeThenFail { throw Repair.Failure.incomplete }
                },
                isInactive: { !self.active.contains(ObjectIdentifier($0)) }
            )
        }
    }
}
#endif
