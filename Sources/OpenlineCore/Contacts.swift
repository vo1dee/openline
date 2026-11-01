// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum NumberLabel: String, Codable, CaseIterable, Sendable {
    case work, mobile, home, other
}

public struct ContactNumber: Identifiable, Equatable, Codable, Sendable, Hashable {
    public var id: UUID
    public var label: NumberLabel
    public var value: String

    public init(id: UUID = UUID(), label: NumberLabel = .work, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public struct Contact: Identifiable, Equatable, Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var company: String?
    public var numbers: [ContactNumber]
    public var internalExtension: String?
    public var sipURI: String?
    public var notes: String?
    public var isFavorite: Bool
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), name: String, company: String? = nil, numbers: [ContactNumber] = [],
                internalExtension: String? = nil, sipURI: String? = nil, notes: String? = nil,
                isFavorite: Bool = false, createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.company = company
        self.numbers = numbers
        self.internalExtension = internalExtension
        self.sipURI = sipURI
        self.notes = notes
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// Every address this contact can be reached at, best dial target first.
    public var dialTargets: [String] {
        numbers.map(\.value) + [internalExtension.nonEmpty, sipURI.nonEmpty].compactMap { $0 }
    }

    public var primaryTarget: String? { internalExtension.nonEmpty ?? numbers.first?.value ?? sipURI.nonEmpty }

    public func matches(search query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty { return true }
        if name.lowercased().contains(needle) || (company?.lowercased().contains(needle) ?? false) { return true }
        let numericNeedle = NumberMatcher.key(needle)
        return dialTargets.contains { target in
            target.lowercased().contains(needle)
                || (!numericNeedle.isEmpty && NumberMatcher.key(target).contains(numericNeedle))
        }
    }
}

public enum ContactMatcher {
    /// The single contact owning this identity. Ambiguous matches return nil:
    /// showing the raw caller is better than naming the wrong person.
    public static func match(_ identity: CallerIdentity, in contacts: [Contact]) -> Contact? {
        let probe = identity.user ?? identity.uri
        let matching = contacts.filter { contact in
            contact.dialTargets.contains { NumberMatcher.matches($0, probe) }
                || (contact.sipURI.nonEmpty.map { sameURI($0, identity) } ?? false)
        }
        return matching.count == 1 ? matching[0] : nil
    }

    private static func sameURI(_ stored: String, _ identity: CallerIdentity) -> Bool {
        let parsed = CallerIdentity(parsing: stored)
        return parsed.user != nil && parsed.user == identity.user && parsed.host?.lowercased() == identity.host?.lowercased()
    }
}

/// CSV interchange. Columns: name, company, work, mobile, home, extension,
/// sip_uri, notes, favorite. Header names are case-insensitive; unknown columns
/// are ignored and only `name` is required.
public enum ContactCSV {
    public struct ImportResult: Equatable, Sendable {
        public var new: [Contact] = []
        public var skippedDuplicates: [String] = []
        public var skippedInvalidRows: [Int] = []
    }

    public static func export(_ contacts: [Contact]) -> String {
        var rows = [["name", "company", "work", "mobile", "home", "extension", "sip_uri", "notes", "favorite"]]
        for contact in contacts {
            func number(_ label: NumberLabel) -> String {
                contact.numbers.filter { $0.label == label }.map(\.value).joined(separator: "; ")
            }
            rows.append([contact.name, contact.company ?? "", number(.work), number(.mobile), number(.home),
                         contact.internalExtension ?? "", contact.sipURI ?? "", contact.notes ?? "",
                         contact.isFavorite ? "true" : "false"])
        }
        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// Never touches existing contacts: rows sharing a name and a dial target
    /// with an existing or earlier row are skipped and reported.
    public static func importContacts(_ text: String, existing: [Contact], now: Date = Date()) -> ImportResult {
        var result = ImportResult()
        let rows = parse(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else { return result }
        func field(_ row: [String], _ name: String) -> String? {
            guard let index = header.firstIndex(of: name), index < row.count else { return nil }
            return Optional(row[index]).nonEmpty
        }
        var known = existing
        for (index, row) in rows.dropFirst().enumerated() {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            guard let name = field(row, "name") else {
                result.skippedInvalidRows.append(index + 2)
                continue
            }
            var numbers: [ContactNumber] = []
            for (column, label) in [("work", NumberLabel.work), ("mobile", .mobile), ("home", .home)] {
                for value in (field(row, column) ?? "").split(separator: ";") {
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { numbers.append(ContactNumber(label: label, value: trimmed)) }
                }
            }
            let favorite = ["true", "yes", "1"].contains(field(row, "favorite")?.lowercased() ?? "")
            let contact = Contact(name: name, company: field(row, "company"), numbers: numbers,
                                  internalExtension: field(row, "extension"), sipURI: field(row, "sip_uri"),
                                  notes: field(row, "notes"), isFavorite: favorite, createdAt: now, modifiedAt: now)
            if known.contains(where: { isDuplicate($0, contact) }) {
                result.skippedDuplicates.append(name)
            } else {
                result.new.append(contact)
                known.append(contact)
            }
        }
        return result
    }

    static func isDuplicate(_ a: Contact, _ b: Contact) -> Bool {
        guard a.name.caseInsensitiveCompare(b.name) == .orderedSame else { return false }
        if a.dialTargets.isEmpty && b.dialTargets.isEmpty { return true }
        return a.dialTargets.contains { left in b.dialTargets.contains { NumberMatcher.matches(left, $0) } }
    }

    private static func escape(_ value: String) -> String {
        // A leading formula character would execute when opened in a spreadsheet.
        var safe = value
        if let first = safe.first, "=-@".contains(first), !safe.dropFirst().isEmpty, safe.dropFirst().first?.isNumber == false {
            safe = "'" + safe
        }
        if safe.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) {
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return safe
    }

    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = Array(text.unicodeScalars.filter { $0 != "\u{FEFF}" }).makeIterator()
        var pending = iterator.next()
        func flushField() {
            row.append(field)
            field = ""
        }
        while let scalar = pending {
            pending = iterator.next()
            if inQuotes {
                if scalar == "\"" {
                    if pending == "\"" {
                        field.unicodeScalars.append("\"")
                        pending = iterator.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"": inQuotes = true
            case ",": flushField()
            case "\r":
                if pending == "\n" { continue }
                flushField()
                rows.append(row)
                row = []
            case "\n":
                flushField()
                rows.append(row)
                row = []
            default: field.unicodeScalars.append(scalar)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            flushField()
            rows.append(row)
        }
        return rows
    }
}
