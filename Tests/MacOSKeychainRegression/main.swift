// SPDX-License-Identifier: MIT
// Compiled with the production Keychain.swift, not a duplicate implementation.
import Foundation
import Security
import os.log

// The test executable has no app-group logger. Do not touch the installed app's log.
func wg_log(_ type: OSLogType, message: String) {}
func wg_log(_ type: OSLogType, staticMessage: StaticString) {}

let base = "test.wireroute.keychain"
let services = Keychain.ownedServices(baseIdentifier: base)
precondition(services == [base, base + ".credential-recovery", base + ".profile-recovery"])

var passed = 0
@MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    passed += 1
    print("PASS: \(message)")
}

// Model each service independently: a profile recovery ref is not a tunnel ref.
for (index, service) in services.enumerated() {
    for modern in [false, true] {
        let reference = Data("fixture-\(index)-\(modern)".utf8)
        let storage = Keychain.referenceStorage(called: reference, services: services) { requestedService, requestedModern in
            requestedService == service && requestedModern == modern ? [reference] : []
        }
        check(storage == (modern ? .dataProtection : .login), "Classify \(service) in \(modern ? "data protection" : "login") storage")
    }
}

var visited = [String]()
let unknownReference = Data("unknown-system-keychain-reference".utf8)
let unknownStorage = Keychain.referenceStorage(called: unknownReference, services: services) { service, modern in
    visited.append(service)
    return []
}
check(unknownStorage == .unavailable, "Unknown/System reference stays unavailable to local lookup")
check(Set(visited) == Set(services) && visited.count == 6, "Classification enumerates only owned services in the two user stores")

let query = Keychain.referenceQuery(called: unknownReference)
check(query[kSecClass] as? String == kSecClassGenericPassword as String, "Persistent-reference query explicitly identifies generic passwords")
check(query[kSecValuePersistentRef] as? Data == unknownReference, "Persistent reference is preserved byte-for-byte")
check(query.count == 2 && query[kSecReturnData] == nil, "Verification query does not request secret data or broaden its match")

// A caller adds operation-specific flags to a fresh dictionary. Reads must not
// leak kSecReturnData or kSecMatchLimitAll into a later delete/verify operation.
var read = query
read[kSecReturnData] = true
check(Keychain.referenceQuery(called: unknownReference)[kSecReturnData] == nil, "Read flags never leak into delete/verify queries")

print("\(passed) Keychain regression checks passed. No installed profiles or Keychain items were read or changed.")
