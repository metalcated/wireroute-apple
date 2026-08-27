// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import os.log

private final class GlobalLoggerStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var logger: Logger?

    var current: Logger? {
        lock.lock()
        defer { lock.unlock() }
        return logger
    }

    func installIfAbsent(_ candidate: Logger) -> Logger {
        lock.lock()
        defer { lock.unlock() }
        if let logger {
            return logger
        }
        logger = candidate
        return candidate
    }
}

public final class Logger: @unchecked Sendable {
    enum LoggerError: Error {
        case openFailure
    }

    private static let globalStorage = GlobalLoggerStorage()

    static var global: Logger? {
        globalStorage.current
    }

    let log: OpaquePointer
    let tag: String

    init(tagged tag: String, withFilePath filePath: String) throws {
        guard let log = open_log(filePath) else { throw LoggerError.openFailure }
        self.log = log
        self.tag = tag
    }

    deinit {
        close_log(self.log)
    }

    func log(message: String) {
        write_msg_to_log(log, tag, message.trimmingCharacters(in: .newlines))
    }

    func writeLog(to targetFile: String) -> Bool {
        return write_log_to_file(targetFile, self.log) == 0
    }

    static func configureGlobal(tagged tag: String, withFilePath filePath: String?) {
        if global != nil {
            return
        }
        guard let filePath = filePath else {
            os_log("Unable to determine log destination path. Log will not be saved to file.", log: OSLog.default, type: .error)
            return
        }
        guard let logger = try? Logger(tagged: tag, withFilePath: filePath) else {
            os_log("Unable to open log file for writing. Log will not be saved to file.", log: OSLog.default, type: .error)
            return
        }
        let globalLogger = globalStorage.installIfAbsent(logger)
        var appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown version"
        if let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            appVersion += " (\(appBuild))"
        }

        globalLogger.log(message: "App version: \(appVersion)")
    }
}

func wg_log(_ type: OSLogType, staticMessage msg: StaticString) {
    os_log(msg, log: OSLog.default, type: type)
    Logger.global?.log(message: "\(msg)")
}

func wg_log(_ type: OSLogType, message msg: String) {
    os_log("%{public}s", log: OSLog.default, type: type, msg)
    Logger.global?.log(message: msg)
}
