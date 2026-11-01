// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum SIPTransport: String, Codable, CaseIterable, Sendable {
    case udp, tcp, tls
}

public enum SRTPMode: String, Codable, CaseIterable, Sendable {
    case disabled, optional, mandatory
}

public enum DTMFMode: String, Codable, CaseIterable, Sendable {
    case rfc4733, sipInfo
}

/// A SIP account. Holds no secrets: `credentialReference` names a Keychain item.
///
/// The server hostname, address-of-record domain, registrar, authentication
/// username and outbound proxy are independent, so each is stored on its own.
public struct SIPAccount: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var server: String
    public var username: String
    public var authUsername: String?
    public var domain: String?
    public var registrar: String?
    public var port: Int?
    public var transport: SIPTransport
    public var outboundProxy: String?
    public var realm: String?
    public var registrationInterval: Int
    public var stunServer: String?
    public var iceEnabled: Bool
    public var turnServer: String?
    public var turnUsername: String?
    public var rewriteContact: Bool
    public var rewriteSDP: Bool
    public var srtp: SRTPMode
    public var dtmf: DTMFMode
    public var preferIPv6: Bool
    public var isEnabled: Bool
    public var isDefault: Bool
    public var credentialReference: String

    public init(
        id: UUID = UUID(),
        label: String = "",
        server: String = "",
        username: String = "",
        authUsername: String? = nil,
        domain: String? = nil,
        registrar: String? = nil,
        port: Int? = nil,
        transport: SIPTransport = .udp,
        outboundProxy: String? = nil,
        realm: String? = nil,
        registrationInterval: Int = 300,
        stunServer: String? = nil,
        iceEnabled: Bool = false,
        turnServer: String? = nil,
        turnUsername: String? = nil,
        rewriteContact: Bool = true,
        rewriteSDP: Bool = false,
        srtp: SRTPMode = .disabled,
        dtmf: DTMFMode = .rfc4733,
        preferIPv6: Bool = false,
        isEnabled: Bool = true,
        isDefault: Bool = false,
        credentialReference: String? = nil
    ) {
        self.id = id
        self.label = label
        self.server = server
        self.username = username
        self.authUsername = authUsername
        self.domain = domain
        self.registrar = registrar
        self.port = port
        self.transport = transport
        self.outboundProxy = outboundProxy
        self.realm = realm
        self.registrationInterval = registrationInterval
        self.stunServer = stunServer
        self.iceEnabled = iceEnabled
        self.turnServer = turnServer
        self.turnUsername = turnUsername
        self.rewriteContact = rewriteContact
        self.rewriteSDP = rewriteSDP
        self.srtp = srtp
        self.dtmf = dtmf
        self.preferIPv6 = preferIPv6
        self.isEnabled = isEnabled
        self.isDefault = isDefault
        self.credentialReference = credentialReference ?? "sip-account-\(id.uuidString)"
    }

    public var displayName: String { label.isEmpty ? username + "@" + effectiveDomain : label }
    public var effectiveDomain: String { domain.nonEmpty ?? server }
    public var effectiveRegistrar: String { registrar.nonEmpty ?? server }
    public var effectiveAuthUsername: String { authUsername.nonEmpty ?? username }

    /// Secure media over cleartext signalling still works, but warns in the UI.
    public var addressOfRecord: String { "sip:\(username)@\(SIPHost.bracketed(effectiveDomain))" }

    public var registrarURI: String {
        "sip:" + hostPort(effectiveRegistrar) + transportParameter
    }

    /// Route for requests. The request URI keeps the SIP domain, so a registrar
    /// reachable under another name, port or transport still receives the call.
    public var routeURI: String? {
        if let proxy = outboundProxy.nonEmpty {
            let uri = proxy.lowercased().hasPrefix("sip:") || proxy.lowercased().hasPrefix("sips:") ? proxy : "sip:\(proxy)"
            var route = uri
            if !route.contains(";lr") { route += ";lr" }
            if !route.contains("transport=") { route += transportParameter }
            return route
        }
        let needsRoute = effectiveRegistrar.lowercased() != effectiveDomain.lowercased()
            || port != nil || transport != .udp
        return needsRoute ? "sip:" + hostPort(effectiveRegistrar) + ";lr" + transportParameter : nil
    }

    private var transportParameter: String {
        transport == .udp ? "" : ";transport=\(transport.rawValue)"
    }

    private func hostPort(_ host: String) -> String {
        let bracketed = SIPHost.bracketed(host)
        return port.map { "\(bracketed):\($0)" } ?? bracketed
    }
}

public enum SIPHost {
    public static func bracketed(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") && host.filter({ $0 == ":" }).count > 1 ? "[\(host)]" : host
    }
}

public extension Optional<String> {
    /// The trimmed value, or nil when empty.
    var nonEmpty: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

public enum RegistrationFailure: Equatable, Sendable {
    case incorrectCredentials
    case credentialUnavailable
    case forbidden
    case notFound
    case timedOut
    case serverUnreachable
    case dnsFailure
    case tlsCertificate
    case server(code: Int, reason: String)

    /// Bad credentials stay bad until the user changes them, and retrying only
    /// risks a lockout on the server.
    public var isRetryable: Bool {
        switch self {
        case .incorrectCredentials, .credentialUnavailable, .forbidden, .notFound, .tlsCertificate: false
        case .timedOut, .serverUnreachable, .dnsFailure, .server: true
        }
    }

    public static func classify(code: Int, reason: String, network: NetworkFailureKind) -> RegistrationFailure {
        switch network {
        case .tls: return .tlsCertificate
        case .dns: return .dnsFailure
        case .network, .none: break
        }
        switch code {
        case 401, 407: return .incorrectCredentials
        case 403: return .forbidden
        case 404: return .notFound
        case 408: return .timedOut
        case 0, 502, 503, 504: return .serverUnreachable
        default: return .server(code: code, reason: reason)
        }
    }
}

public enum NetworkFailureKind: Sendable {
    case none, dns, tls, network
}

public enum AccountRegistrationState: Equatable, Sendable {
    case disabled
    case offline
    case registering
    case reconnecting(attempt: Int)
    case registered(expiresIn: Int)
    case failed(RegistrationFailure)

    public var isRegistered: Bool {
        if case .registered = self { return true }
        return false
    }
}

public enum AccountSelection {
    /// The explicit choice when it can place calls, otherwise the default
    /// account, otherwise the only other registered candidate.
    public static func outgoing(from accounts: [SIPAccount], explicit: UUID?) -> SIPAccount? {
        let enabled = accounts.filter(\.isEnabled)
        if let explicit, let account = enabled.first(where: { $0.id == explicit }) { return account }
        return enabled.first(where: \.isDefault) ?? enabled.first
    }
}

public struct ValidationIssue: Equatable, Sendable, Hashable {
    public enum Field: Sendable, Hashable {
        case server, username, password, domain, registrar, port, outboundProxy, registrationInterval, stunServer
    }

    public enum Problem: Sendable, Hashable {
        case required, invalidHost, invalidPort, invalidUsername, intervalOutOfRange
    }

    public let field: Field
    public let problem: Problem

    public init(field: Field, problem: Problem) {
        self.field = field
        self.problem = problem
    }
}

public enum AccountValidator {
    public static func validate(_ account: SIPAccount, password: String?) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if account.server.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(field: .server, problem: .required))
        } else if !isHost(account.server) {
            issues.append(.init(field: .server, problem: .invalidHost))
        }
        if account.username.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(field: .username, problem: .required))
        } else if account.username.contains(where: { $0.isWhitespace || "<>\"@:".contains($0) }) {
            issues.append(.init(field: .username, problem: .invalidUsername))
        }
        if let password, password.isEmpty {
            issues.append(.init(field: .password, problem: .required))
        }
        for (value, field) in [(account.domain, ValidationIssue.Field.domain), (account.registrar, .registrar)] {
            if let host = value.nonEmpty, !isHost(host) {
                issues.append(.init(field: field, problem: .invalidHost))
            }
        }
        if let port = account.port, !(1...65535).contains(port) {
            issues.append(.init(field: .port, problem: .invalidPort))
        }
        if let proxy = account.outboundProxy.nonEmpty {
            let stripped = proxy.replacingOccurrences(of: #"^sips?:"#, with: "", options: .regularExpression)
                .components(separatedBy: ";")[0]
            if !isHostPort(stripped) { issues.append(.init(field: .outboundProxy, problem: .invalidHost)) }
        }
        if !(60...86400).contains(account.registrationInterval) {
            issues.append(.init(field: .registrationInterval, problem: .intervalOutOfRange))
        }
        if let stun = account.stunServer.nonEmpty, !isHostPort(stun) {
            issues.append(.init(field: .stunServer, problem: .invalidHost))
        }
        return issues
    }

    static func isHost(_ value: String) -> Bool {
        let host = value.trimmingCharacters(in: .whitespaces)
        if host.isEmpty || host.contains(where: \.isWhitespace) { return false }
        if host.filter({ $0 == ":" }).count > 1 { return host.allSatisfy { $0.isHexDigit || ":.[]".contains($0) } }
        return host.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || "-._".contains($0) }
            && !host.hasPrefix("-") && !host.hasPrefix(".")
    }

    static func isHostPort(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard let port = Int(parts[1]), (1...65535).contains(port) else { return false }
            return isHost(String(parts[0]))
        }
        return isHost(value)
    }
}
