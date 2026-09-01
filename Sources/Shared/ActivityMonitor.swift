// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import os.log

enum WireRouteActivityRetention: Int, CaseIterable, Sendable {
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30

    static let defaultValue: Self = .sevenDays

    var interval: TimeInterval {
        TimeInterval(rawValue) * 24 * 60 * 60
    }
}

enum WireRouteActivityPreference {
    private static let retentionKey = "WireRoute.Activity.RetentionDays"

    static func loadRetention() -> WireRouteActivityRetention {
        let defaults = sharedDefaults
        guard defaults.object(forKey: retentionKey) != nil,
              let retention = WireRouteActivityRetention(rawValue: defaults.integer(forKey: retentionKey)) else {
            return .defaultValue
        }
        return retention
    }

    static func saveRetention(_ retention: WireRouteActivityRetention) {
        sharedDefaults.set(retention.rawValue, forKey: retentionKey)
        NotificationCenter.default.post(name: .wireRouteActivityRetentionDidChange, object: retention)
    }

    private static var sharedDefaults: UserDefaults {
        guard let appGroupID = FileManager.appGroupId,
              let defaults = UserDefaults(suiteName: appGroupID) else {
            return .standard
        }
        return defaults
    }
}

extension Notification.Name {
    static let wireRouteActivityRetentionDidChange = Notification.Name(
        "WireRouteActivityRetentionDidChange"
    )
}

struct WireRouteActivityPoint: Equatable, Sendable {
    let date: Date
    let receivedBytesPerSecond: Double
    let sentBytesPerSecond: Double
    let totalReceivedBytes: UInt64
    let totalSentBytes: UInt64
    let lastHandshake: Date?
}

struct WireRouteActivitySession: Equatable, Sendable {
    let id: Int64
    let profileIdentifier: UUID
    let profileName: String
    let startedAt: Date
    let endedAt: Date?
    let lastSampleAt: Date
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let lastHandshake: Date?
}

enum WireRouteActivityStoreError: Error, LocalizedError {
    case openFailed(String)
    case statementFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "WireRoute could not open activity history: \(message)"
        case .statementFailed(let message):
            return "WireRoute could not update activity history: \(message)"
        }
    }
}

final class WireRouteActivityStore: @unchecked Sendable {
    private let lock = NSLock()
    private var database: OpaquePointer?

    init(databaseURL: URL? = FileManager.activityDatabaseURL) throws {
        guard let databaseURL else {
            throw WireRouteActivityStoreError.openFailed("The shared app container is unavailable.")
        }
        var openedDatabase: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &openedDatabase, flags, nil) == SQLITE_OK,
              let openedDatabase else {
            let message = openedDatabase.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) }
                ?? "Unknown SQLite error"
            sqlite3_close(openedDatabase)
            throw WireRouteActivityStoreError.openFailed(message)
        }
        database = openedDatabase
        sqlite3_busy_timeout(openedDatabase, 1_500)
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try execute("PRAGMA foreign_keys=ON")
            try createSchema()
        } catch {
            sqlite3_close(openedDatabase)
            database = nil
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func beginSession(
        profileIdentifier: UUID,
        profileName: String,
        at date: Date
    ) throws -> Int64 {
        try lock.withLock {
            guard let database else { throw WireRouteActivityStoreError.openFailed("Database is closed.") }
            let closeStale = try prepareLocked("""
                UPDATE activity_sessions
                SET ended_at = last_sample_at
                WHERE ended_at IS NULL AND (profile_id = ? OR last_sample_at < ?)
                """)
            defer { sqlite3_finalize(closeStale) }
            bind(profileIdentifier.uuidString, to: closeStale, at: 1)
            sqlite3_bind_double(closeStale, 2, date.addingTimeInterval(-60).timeIntervalSince1970)
            try stepDone(closeStale, database: database)
            let sql = """
                INSERT INTO activity_sessions (
                    profile_id, profile_name, started_at, last_sample_at,
                    received_bytes, sent_bytes
                ) VALUES (?, ?, ?, ?, 0, 0)
                """
            let statement = try prepareLocked(sql)
            defer { sqlite3_finalize(statement) }
            bind(profileIdentifier.uuidString, to: statement, at: 1)
            bind(profileName, to: statement, at: 2)
            sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
            sqlite3_bind_double(statement, 4, date.timeIntervalSince1970)
            try stepDone(statement, database: database)
            return sqlite3_last_insert_rowid(database)
        }
    }

    func append(
        _ delta: WireRouteActivityDelta,
        sessionID: Int64,
        profileIdentifier: UUID,
        at date: Date
    ) throws {
        try lock.withLock {
            guard let database else { throw WireRouteActivityStoreError.openFailed("Database is closed.") }
            try executeLocked("BEGIN IMMEDIATE TRANSACTION")
            do {
                let insert = try prepareLocked("""
                    INSERT INTO activity_samples (
                        session_id, profile_id, recorded_at,
                        received_delta, sent_delta,
                        received_rate, sent_rate,
                        total_received, total_sent, last_handshake
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """)
                defer { sqlite3_finalize(insert) }
                sqlite3_bind_int64(insert, 1, sessionID)
                bind(profileIdentifier.uuidString, to: insert, at: 2)
                sqlite3_bind_double(insert, 3, date.timeIntervalSince1970)
                sqlite3_bind_int64(insert, 4, sqliteInteger(delta.receivedBytes))
                sqlite3_bind_int64(insert, 5, sqliteInteger(delta.sentBytes))
                sqlite3_bind_double(insert, 6, delta.receivedBytesPerSecond)
                sqlite3_bind_double(insert, 7, delta.sentBytesPerSecond)
                sqlite3_bind_int64(insert, 8, sqliteInteger(delta.totalReceivedBytes))
                sqlite3_bind_int64(insert, 9, sqliteInteger(delta.totalSentBytes))
                bind(delta.lastHandshake?.timeIntervalSince1970, to: insert, at: 10)
                try stepDone(insert, database: database)

                let update = try prepareLocked("""
                    UPDATE activity_sessions
                    SET last_sample_at = ?, received_bytes = ?, sent_bytes = ?, last_handshake = ?
                    WHERE id = ?
                    """)
                defer { sqlite3_finalize(update) }
                sqlite3_bind_double(update, 1, date.timeIntervalSince1970)
                sqlite3_bind_int64(update, 2, sqliteInteger(delta.totalReceivedBytes))
                sqlite3_bind_int64(update, 3, sqliteInteger(delta.totalSentBytes))
                bind(delta.lastHandshake?.timeIntervalSince1970, to: update, at: 4)
                sqlite3_bind_int64(update, 5, sessionID)
                try stepDone(update, database: database)
                try executeLocked("COMMIT")
            } catch {
                try? executeLocked("ROLLBACK")
                throw error
            }
        }
    }

    func endSession(_ sessionID: Int64, at date: Date) throws {
        try lock.withLock {
            guard let database else { throw WireRouteActivityStoreError.openFailed("Database is closed.") }
            let statement = try prepareLocked("""
                UPDATE activity_sessions
                SET ended_at = ?, last_sample_at = MAX(last_sample_at, ?)
                WHERE id = ?
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
            sqlite3_bind_int64(statement, 3, sessionID)
            try stepDone(statement, database: database)
        }
    }

    func points(
        profileIdentifier: UUID,
        since date: Date,
        limit: Int = 360
    ) throws -> [WireRouteActivityPoint] {
        try lock.withLock {
            let statement = try prepareLocked("""
                SELECT recorded_at, received_rate, sent_rate,
                       total_received, total_sent, last_handshake
                FROM activity_samples
                WHERE profile_id = ? AND recorded_at >= ?
                ORDER BY recorded_at DESC
                LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            bind(profileIdentifier.uuidString, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
            sqlite3_bind_int(statement, 3, Int32(clamping: limit))
            var points = [WireRouteActivityPoint]()
            while sqlite3_step(statement) == SQLITE_ROW {
                points.append(
                    WireRouteActivityPoint(
                        date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                        receivedBytesPerSecond: sqlite3_column_double(statement, 1),
                        sentBytesPerSecond: sqlite3_column_double(statement, 2),
                        totalReceivedBytes: unsignedInteger(sqlite3_column_int64(statement, 3)),
                        totalSentBytes: unsignedInteger(sqlite3_column_int64(statement, 4)),
                        lastHandshake: optionalDate(statement, column: 5)
                    )
                )
            }
            return points.reversed()
        }
    }

    func sessions(profileIdentifier: UUID, limit: Int = 24) throws -> [WireRouteActivitySession] {
        try lock.withLock {
            let statement = try prepareLocked("""
                SELECT id, profile_name, started_at, ended_at, last_sample_at,
                       received_bytes, sent_bytes, last_handshake
                FROM activity_sessions
                WHERE profile_id = ?
                ORDER BY started_at DESC
                LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            bind(profileIdentifier.uuidString, to: statement, at: 1)
            sqlite3_bind_int(statement, 2, Int32(clamping: limit))
            var sessions = [WireRouteActivitySession]()
            while sqlite3_step(statement) == SQLITE_ROW {
                sessions.append(
                    WireRouteActivitySession(
                        id: sqlite3_column_int64(statement, 0),
                        profileIdentifier: profileIdentifier,
                        profileName: text(statement, column: 1) ?? "WireRoute",
                        startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                        endedAt: optionalDate(statement, column: 3),
                        lastSampleAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                        receivedBytes: unsignedInteger(sqlite3_column_int64(statement, 5)),
                        sentBytes: unsignedInteger(sqlite3_column_int64(statement, 6)),
                        lastHandshake: optionalDate(statement, column: 7)
                    )
                )
            }
            return sessions
        }
    }

    func clearCompletedHistory(profileIdentifier: UUID) throws {
        try lock.withLock {
            guard let database else { throw WireRouteActivityStoreError.openFailed("Database is closed.") }
            let statement = try prepareLocked("""
                DELETE FROM activity_sessions
                WHERE profile_id = ? AND ended_at IS NOT NULL
                """)
            defer { sqlite3_finalize(statement) }
            bind(profileIdentifier.uuidString, to: statement, at: 1)
            try stepDone(statement, database: database)
        }
    }

    func clearAllHistory(profileIdentifier: UUID) throws {
        try lock.withLock {
            guard let database else { throw WireRouteActivityStoreError.openFailed("Database is closed.") }
            let statement = try prepareLocked("DELETE FROM activity_sessions WHERE profile_id = ?")
            defer { sqlite3_finalize(statement) }
            bind(profileIdentifier.uuidString, to: statement, at: 1)
            try stepDone(statement, database: database)
        }
    }

    func purge(before date: Date) throws {
        try lock.withLock {
            guard let database else { throw WireRouteActivityStoreError.openFailed("Database is closed.") }
            let statement = try prepareLocked("""
                DELETE FROM activity_sessions
                WHERE ended_at IS NOT NULL AND ended_at < ?
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            try stepDone(statement, database: database)
        }
    }

    private func createSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS activity_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                profile_id TEXT NOT NULL,
                profile_name TEXT NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL,
                last_sample_at REAL NOT NULL,
                received_bytes INTEGER NOT NULL DEFAULT 0,
                sent_bytes INTEGER NOT NULL DEFAULT 0,
                last_handshake REAL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS activity_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id INTEGER NOT NULL REFERENCES activity_sessions(id) ON DELETE CASCADE,
                profile_id TEXT NOT NULL,
                recorded_at REAL NOT NULL,
                received_delta INTEGER NOT NULL,
                sent_delta INTEGER NOT NULL,
                received_rate REAL NOT NULL,
                sent_rate REAL NOT NULL,
                total_received INTEGER NOT NULL,
                total_sent INTEGER NOT NULL,
                last_handshake REAL
            )
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS activity_samples_profile_date
            ON activity_samples(profile_id, recorded_at)
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS activity_sessions_profile_date
            ON activity_sessions(profile_id, started_at)
            """)
    }

    private func execute(_ sql: String) throws {
        try lock.withLock {
            try executeLocked(sql)
        }
    }

    private func executeLocked(_ sql: String) throws {
        guard let database else { throw WireRouteActivityStoreError.openFailed("Database is closed.") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw WireRouteActivityStoreError.statementFailed(message)
        }
    }

    private func prepareLocked(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw WireRouteActivityStoreError.openFailed("Database is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw WireRouteActivityStoreError.statementFailed(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer, database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw WireRouteActivityStoreError.statementFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(
            statement,
            index,
            value,
            -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )
    }

    private func bind(_ value: TimeInterval?, to statement: OpaquePointer, at index: Int32) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private func optionalDate(_ statement: OpaquePointer, column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private func sqliteInteger(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }

    private func unsignedInteger(_ value: Int64) -> UInt64 {
        value > 0 ? UInt64(value) : 0
    }
}

final class WireRouteActivityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let store: WireRouteActivityStore
    private let profileIdentifier: UUID
    private var sessionID: Int64?
    private var accumulator = WireRouteActivityAccumulator()
    private var lastPurgeDate: Date?

    init(store: WireRouteActivityStore, profileIdentifier: UUID) {
        self.store = store
        self.profileIdentifier = profileIdentifier
    }

    func start(profileName: String, at date: Date = Date()) throws {
        try lock.withLock {
            guard sessionID == nil else { return }
            sessionID = try store.beginSession(
                profileIdentifier: profileIdentifier,
                profileName: profileName,
                at: date
            )
            accumulator = WireRouteActivityAccumulator()
            try purgeIfNeeded(at: date)
        }
    }

    func record(runtimeConfiguration: String, at date: Date = Date()) throws {
        try lock.withLock {
            guard let sessionID else { return }
            let peers = WireRouteActivityRuntimeParser.peerCounters(from: runtimeConfiguration)
            let delta = accumulator.sample(peers: peers, at: date)
            try store.append(
                delta,
                sessionID: sessionID,
                profileIdentifier: profileIdentifier,
                at: date
            )
            try purgeIfNeeded(at: date)
        }
    }

    func stop(at date: Date = Date()) throws {
        try lock.withLock {
            guard let sessionID else { return }
            try store.endSession(sessionID, at: date)
            self.sessionID = nil
        }
    }

    private func purgeIfNeeded(at date: Date) throws {
        guard lastPurgeDate.map({ date.timeIntervalSince($0) >= 60 * 60 }) ?? true else { return }
        let retention = WireRouteActivityPreference.loadRetention()
        try store.purge(before: date.addingTimeInterval(-retention.interval))
        lastPurgeDate = date
    }
}
