// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import os.log

extension FileManager {
    static var appGroupId: String? {
        #if os(iOS)
        let appGroupIdInfoDictionaryKey = "com.wireguard.ios.app_group_id"
        #elseif os(macOS)
        let appGroupIdInfoDictionaryKey = "com.wireguard.macos.app_group_id"
        #else
        #error("Unimplemented")
        #endif
        return Bundle.main.object(forInfoDictionaryKey: appGroupIdInfoDictionaryKey) as? String
    }
    private static var sharedFolderURL: URL? {
        guard let appGroupId = FileManager.appGroupId else {
            os_log("Cannot obtain app group ID from bundle", log: OSLog.default, type: .error)
            return nil
        }
        guard let sharedFolderURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            wg_log(.error, message: "Cannot obtain shared folder URL")
            return nil
        }
        return sharedFolderURL
    }

    static var logFileURL: URL? {
        return sharedFolderURL?.appendingPathComponent("tunnel-log.bin")
    }

    static var networkExtensionLastErrorFileURL: URL? {
        return sharedFolderURL?.appendingPathComponent("last-error.txt")
    }

    static var activityDatabaseURL: URL? {
        return activityDatabaseURL(ownerUID: nil)
    }

    static func activityDatabaseURL(ownerUID: uid_t?) -> URL? {
        #if os(macOS)
        let isSystemExtension = Bundle.main.bundleURL.pathExtension == "systemextension"
            || Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "SYSX"
        if isSystemExtension {
            guard let ownerUID else {
                wg_log(.error, staticMessage: "Cannot obtain the owning user for system extension activity storage")
                return nil
            }
            return sharedFolderURL?.appendingPathComponent("activity-\(ownerUID).sqlite3")
        }
        #endif
        return sharedFolderURL?.appendingPathComponent("activity.sqlite3")
    }

    static func automaticProfilesSnapshotURL(ownerUID: uid_t? = nil) -> URL? {
        automaticProfilesURL(fileName: "automatic-profiles.json", ownerUID: ownerUID)
    }

    static func automaticProfilesStateURL(ownerUID: uid_t? = nil) -> URL? {
        automaticProfilesURL(fileName: "automatic-profiles-state.json", ownerUID: ownerUID)
    }

    private static func automaticProfilesURL(fileName: String, ownerUID: uid_t?) -> URL? {
        #if os(macOS)
        let resolvedOwnerUID = ownerUID ?? getuid()
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let pathExtension = URL(fileURLWithPath: fileName).pathExtension
        return sharedFolderURL?.appendingPathComponent(
            "\(stem)-\(resolvedOwnerUID).\(pathExtension)"
        )
        #else
        return sharedFolderURL?.appendingPathComponent(fileName)
        #endif
    }

    static var loginHelperTimestampURL: URL? {
        return sharedFolderURL?.appendingPathComponent("login-helper-timestamp.bin")
    }

    static func deleteFile(at url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            return false
        }
        return true
    }
}
