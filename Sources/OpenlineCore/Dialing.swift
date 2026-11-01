// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Turns what the user typed into a request URI. The dialled string is never
/// rewritten into E.164, because extensions and feature codes are not numbers.
public enum DialTarget {
    /// Characters that may be pasted around a number but are never dialled.
    private static let visualSeparators = CharacterSet(charactersIn: " \t\n\r-().\u{00A0}/")

    public static func sanitized(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isURI(trimmed) { return trimmed }
        return String(String.UnicodeScalarView(trimmed.unicodeScalars.filter { !visualSeparators.contains($0) }))
    }

    public static func isURI(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return lowered.hasPrefix("sip:") || lowered.hasPrefix("sips:") || value.contains("@")
    }

    public static func isDialable(_ input: String) -> Bool { !sanitized(input).isEmpty }

    /// nil when there is nothing to dial.
    public static func requestURI(for input: String, account: SIPAccount) -> String? {
        let target = sanitized(input)
        if target.isEmpty { return nil }
        let lowered = target.lowercased()
        if lowered.hasPrefix("sip:") || lowered.hasPrefix("sips:") { return target }
        if target.contains("@") { return "sip:\(target)" }
        return "sip:\(escapeUser(target))@\(SIPHost.bracketed(account.effectiveDomain))"
    }

    /// RFC 3261 forbids a bare `#` in the user part; `*` is allowed unreserved.
    static func escapeUser(_ user: String) -> String {
        user.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "#", with: "%23")
    }

    public static let keypadDigits = Set("0123456789*#ABCDabcd")
}

/// A remote party parsed from a From-style value such as
/// `"Alice" <sip:101@pbx.example.com>;tag=abc`.
public struct CallerIdentity: Equatable, Sendable, Codable {
    public let uri: String
    public let displayName: String?
    public let user: String?
    public let host: String?

    public init(uri: String, displayName: String?, user: String?, host: String?) {
        self.uri = uri
        self.displayName = displayName
        self.user = user
        self.host = host
    }

    public init(parsing raw: String) {
        var value = raw.trimmingCharacters(in: .whitespaces)
        var name: String?
        if let open = value.firstIndex(of: "<"), let close = value[open...].firstIndex(of: ">") {
            let prefix = value[..<open].trimmingCharacters(in: .whitespaces)
            let unquoted = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            name = unquoted.isEmpty ? nil : unquoted
            value = String(value[value.index(after: open)..<close])
        } else if let semicolon = value.firstIndex(of: ";") {
            value = String(value[..<semicolon])
        }
        let body = value.replacingOccurrences(of: #"^sips?:"#, with: "", options: [.regularExpression, .caseInsensitive])
        let core = body.components(separatedBy: ";")[0].components(separatedBy: "?")[0]
        if let at = core.lastIndex(of: "@") {
            user = String(core[..<at]).removingPercentEncoding ?? String(core[..<at])
            host = String(core[core.index(after: at)...])
        } else {
            user = nil
            host = core.isEmpty ? nil : core
        }
        uri = value
        displayName = name
    }

    /// What to show when no contact matches.
    public var label: String { displayName ?? user ?? uri }
}

public enum NumberMatcher {
    /// Comparison key only. Never dial this value.
    public static func key(_ value: String) -> String {
        var input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if DialTarget.isURI(input) { input = CallerIdentity(parsing: input).user ?? input }
        let kept = input.lowercased().filter { $0.isLetter || $0.isNumber || "+*#".contains($0) }
        if kept.hasPrefix("00"), kept.count > 6, kept.dropFirst(2).allSatisfy(\.isNumber) {
            return "+" + kept.dropFirst(2)
        }
        return kept
    }

    /// Exact key equality, plus the one safe inexact case: an international
    /// number and the same subscriber written with a single national trunk 0.
    public static func matches(_ a: String, _ b: String) -> Bool {
        let left = key(a)
        let right = key(b)
        if left.isEmpty || right.isEmpty { return false }
        if left == right { return true }
        return isTrunkForm(national: left, international: right) || isTrunkForm(national: right, international: left)
    }

    private static func isTrunkForm(national: String, international: String) -> Bool {
        guard international.hasPrefix("+"), national.hasPrefix("0"), !national.hasPrefix("00") else { return false }
        let subscriber = national.dropFirst()
        guard subscriber.count >= 7, subscriber.allSatisfy(\.isNumber) else { return false }
        let digits = international.dropFirst()
        guard digits.hasSuffix(subscriber) else { return false }
        return (1...3).contains(digits.count - subscriber.count)
    }
}
