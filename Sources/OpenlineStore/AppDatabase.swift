// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import OpenlineCore

/// Local persistence. Stores no secrets: account rows carry only a Keychain
/// reference, enforced by `SIPAccount` having no password property.
public final class AppDatabase: Sendable {
    private let writer: any DatabaseWriter

    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        writer = try DatabasePool(path: path, configuration: config)
        try Self.migrator.migrate(writer)
    }

    /// In-memory database for tests and previews.
    public init() throws {
        writer = try DatabaseQueue()
        try Self.migrator.migrate(writer)
    }

    public static func defaultURL() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appending(path: "Openline", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "openline.sqlite")
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "account") { t in
                t.primaryKey("id", .text)
                t.column("position", .integer).notNull()
                t.column("config", .blob).notNull()
            }
            try db.create(table: "contact") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("company", .text)
                t.column("internalExtension", .text)
                t.column("sipURI", .text)
                t.column("notes", .text)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
            }
            try db.create(table: "contactNumber") { t in
                t.primaryKey("id", .text)
                t.belongsTo("contact", onDelete: .cascade).notNull()
                t.column("position", .integer).notNull()
                t.column("label", .text).notNull()
                t.column("value", .text).notNull()
            }
            // accountId and contactId are deliberately not foreign keys: history
            // outlives both.
            try db.create(table: "callHistory") { t in
                t.primaryKey("id", .text)
                t.column("dialTarget", .text).notNull()
                t.column("displayIdentity", .text).notNull()
                t.column("accountId", .text).notNull()
                t.column("direction", .text).notNull()
                t.column("outcome", .text).notNull()
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("answeredAt", .datetime)
                t.column("endedAt", .datetime).notNull()
                t.column("contactId", .text)
                t.column("sipStatus", .integer)
                t.column("failureDetail", .text)
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .blob).notNull()
            }
        }
        return migrator
    }

    // MARK: Accounts

    public func accounts() throws -> [SIPAccount] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT config FROM account ORDER BY position").map { row in
                try JSONDecoder().decode(SIPAccount.self, from: row["config"] as Data)
            }
        }
    }

    public func save(_ account: SIPAccount) throws {
        let data = try JSONEncoder().encode(account)
        try writer.write { db in
            let position = try Int.fetchOne(db, sql: "SELECT position FROM account WHERE id = ?", arguments: [account.id.uuidString])
                ?? (Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM account") ?? 0)
            try db.execute(sql: "INSERT OR REPLACE INTO account (id, position, config) VALUES (?, ?, ?)",
                           arguments: [account.id.uuidString, position, data])
        }
    }

    public func deleteAccount(_ id: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: Contacts

    public func contacts() throws -> [Contact] {
        try writer.read { db in
            var numbers: [String: [ContactNumber]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM contactNumber ORDER BY position") {
                guard let id = UUID(uuidString: row["id"]), let label = NumberLabel(rawValue: row["label"]) else { continue }
                numbers[row["contactId"], default: []].append(ContactNumber(id: id, label: label, value: row["value"]))
            }
            return try Row.fetchAll(db, sql: "SELECT * FROM contact ORDER BY name COLLATE NOCASE").compactMap { row in
                let key: String = row["id"]
                guard let id = UUID(uuidString: key) else { return nil }
                return Contact(id: id, name: row["name"], company: row["company"], numbers: numbers[key] ?? [],
                               internalExtension: row["internalExtension"], sipURI: row["sipURI"], notes: row["notes"],
                               isFavorite: row["isFavorite"], createdAt: row["createdAt"], modifiedAt: row["modifiedAt"])
            }
        }
    }

    public func save(_ contact: Contact) throws {
        try save(contacts: [contact])
    }

    public func save(contacts: [Contact]) throws {
        try writer.write { db in
            for contact in contacts {
                try db.execute(sql: """
                    INSERT INTO contact (id, name, company, internalExtension, sipURI, notes, isFavorite, createdAt, modifiedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name, company = excluded.company,
                      internalExtension = excluded.internalExtension, sipURI = excluded.sipURI, notes = excluded.notes,
                      isFavorite = excluded.isFavorite, modifiedAt = excluded.modifiedAt
                    """, arguments: [contact.id.uuidString, contact.name, contact.company, contact.internalExtension,
                                     contact.sipURI, contact.notes, contact.isFavorite, contact.createdAt, contact.modifiedAt])
                try db.execute(sql: "DELETE FROM contactNumber WHERE contactId = ?", arguments: [contact.id.uuidString])
                for (position, number) in contact.numbers.enumerated() {
                    try db.execute(sql: "INSERT INTO contactNumber (id, contactId, position, label, value) VALUES (?, ?, ?, ?, ?)",
                                   arguments: [number.id.uuidString, contact.id.uuidString, position, number.label.rawValue, number.value])
                }
            }
        }
    }

    public func deleteContact(_ id: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM contact WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: Call history

    /// Idempotent: a repeated callback for the same call rewrites one row.
    public func record(_ entry: CallHistoryEntry) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO callHistory
                (id, dialTarget, displayIdentity, accountId, direction, outcome, startedAt, answeredAt, endedAt, contactId, sipStatus, failureDetail)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [entry.id.uuidString, entry.dialTarget, entry.displayIdentity, entry.accountID.uuidString,
                                 entry.direction.rawValue, entry.outcome.rawValue, entry.startedAt, entry.answeredAt,
                                 entry.endedAt, entry.contactID?.uuidString, entry.sipStatus, entry.failureDetail])
        }
    }

    public func history(limit: Int = 2000) throws -> [CallHistoryEntry] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM callHistory ORDER BY startedAt DESC LIMIT ?", arguments: [limit]).compactMap { row in
                guard let id = UUID(uuidString: row["id"]), let account = UUID(uuidString: row["accountId"]),
                      let direction = CallDirection(rawValue: row["direction"]),
                      let outcome = CallOutcome(rawValue: row["outcome"]) else { return nil }
                return CallHistoryEntry(id: id, dialTarget: row["dialTarget"], displayIdentity: row["displayIdentity"],
                                        accountID: account, direction: direction, outcome: outcome,
                                        startedAt: row["startedAt"], answeredAt: row["answeredAt"], endedAt: row["endedAt"],
                                        contactID: (row["contactId"] as String?).flatMap(UUID.init(uuidString:)),
                                        sipStatus: row["sipStatus"], failureDetail: row["failureDetail"])
            }
        }
    }

    public func deleteHistory(_ id: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM callHistory WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func clearHistory() throws {
        try writer.write { db in try db.execute(sql: "DELETE FROM callHistory") }
    }

    // MARK: Settings

    public func settings() throws -> ApplicationSettings {
        try writer.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM setting WHERE key = 'application'") else {
                return ApplicationSettings()
            }
            return try JSONDecoder().decode(ApplicationSettings.self, from: data)
        }
    }

    public func save(_ settings: ApplicationSettings) throws {
        let data = try JSONEncoder().encode(settings)
        try writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO setting (key, value) VALUES ('application', ?)", arguments: [data])
        }
    }
}
