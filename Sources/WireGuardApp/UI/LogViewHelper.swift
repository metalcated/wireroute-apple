// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

public final class LogViewHelper: @unchecked Sendable {
    private let log: OpaquePointer
    private let readerQueue = DispatchQueue(label: "com.gnet.wireroute.log-reader", qos: .userInitiated)
    private var cursor: UInt32 = UINT32_MAX
    private static let formatOptions: ISO8601DateFormatter.Options = [
        .withYear, .withMonth, .withDay, .withTime,
        .withDashSeparatorInDate, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime,
        .withFractionalSeconds
    ]

    struct LogEntry: Sendable {
        let timestamp: String
        let message: String

        func text() -> String {
            return timestamp + " " + message
        }
    }

    private final class LogEntries: @unchecked Sendable {
        var entries: [LogEntry] = []
    }

    init?(logFilePath: String?) {
        guard let logFilePath = logFilePath else { return nil }
        guard let log = open_log(logFilePath) else { return nil }
        self.log = log
    }

    deinit {
        close_log(self.log)
    }

    func fetchLogEntriesSinceLastFetch(
        completion: @escaping @MainActor @Sendable ([LogViewHelper.LogEntry]) -> Void
    ) {
        readerQueue.async { [weak self] in
            guard let self = self else { return }
            let logEntries = LogEntries()
            let context = Unmanaged.passUnretained(logEntries).toOpaque()
            self.cursor = view_lines_from_cursor(self.log, self.cursor, context) { cStr, timestamp, ctx in
                let message = cStr != nil ? String(cString: cStr!) : ""
                let date = Date(timeIntervalSince1970: Double(timestamp) / 1000000000)
                let dateString = ISO8601DateFormatter.string(from: date, timeZone: TimeZone.current, formatOptions: LogViewHelper.formatOptions)
                if let ctx {
                    let entries = Unmanaged<LogEntries>.fromOpaque(ctx).takeUnretainedValue()
                    entries.entries.append(LogEntry(timestamp: dateString, message: message))
                }
            }
            let fetchedEntries = logEntries.entries
            DispatchQueue.main.async {
                completion(fetchedEntries)
            }
        }
    }
}
