// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct AudioDevice: Identifiable, Equatable, Sendable, Hashable {
    public var id: String { name }
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int

    public init(name: String, inputChannels: Int, outputChannels: Int) {
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
    }
}

public enum AppearancePreference: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

public enum Ringtone: String, Codable, CaseIterable, Sendable {
    case classic, chime, pulse
}

public struct ApplicationSettings: Codable, Equatable, Sendable {
    public var inputDevice: String?
    public var outputDevice: String?
    public var ringtone: Ringtone = .classic
    public var ringtoneVolume: Double = 0.8
    public var doNotDisturb = false
    public var showIncomingWindow = true
    public var launchAtLogin = false
    public var showMenuBarIcon = true
    public var appearance: AppearancePreference = .system
    public var codecOrder: [String] = ApplicationSettings.defaultCodecs
    public var diagnosticLogging = false
    public var hasCompletedOnboarding = false

    public init() {}

    /// G.711 first for interoperability, then wideband where the far end offers it.
    public static let defaultCodecs = ["PCMU/8000/1", "PCMA/8000/1", "G722/16000/1", "opus/48000/2"]

    public init(from decoder: any Decoder) throws {
        // Missing keys fall back to defaults so added settings never lose stored ones.
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputDevice = try c.decodeIfPresent(String.self, forKey: .inputDevice)
        outputDevice = try c.decodeIfPresent(String.self, forKey: .outputDevice)
        ringtone = try c.decodeIfPresent(Ringtone.self, forKey: .ringtone) ?? ringtone
        ringtoneVolume = try c.decodeIfPresent(Double.self, forKey: .ringtoneVolume) ?? ringtoneVolume
        doNotDisturb = try c.decodeIfPresent(Bool.self, forKey: .doNotDisturb) ?? doNotDisturb
        showIncomingWindow = try c.decodeIfPresent(Bool.self, forKey: .showIncomingWindow) ?? showIncomingWindow
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? showMenuBarIcon
        appearance = try c.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? appearance
        codecOrder = try c.decodeIfPresent([String].self, forKey: .codecOrder) ?? codecOrder
        diagnosticLogging = try c.decodeIfPresent(Bool.self, forKey: .diagnosticLogging) ?? diagnosticLogging
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? hasCompletedOnboarding
    }
}

/// Immutable, engine-independent events. Delivered in order.
public enum SIPEvent: Equatable, Sendable {
    case registrationStarted(account: UUID, renewing: Bool)
    case registrationChanged(account: UUID, code: Int, reason: String, expiration: Int, network: NetworkFailureKind)
    case incomingCall(handle: String, account: UUID, remoteURI: String, sipCallID: String?)
    case callPhase(handle: String, phase: SIPCallPhase, code: Int, reason: String, sipCallID: String?)
    case callMedia(handle: String, phase: SIPMediaPhase)
    case reinviteFailed(handle: String, code: Int, reason: String)
    case transferStatus(handle: String, code: Int, reason: String, final: Bool)
    case dtmfReceived(handle: String, digit: String)
    case audioDevicesChanged
}

public enum SIPCallPhase: Equatable, Sendable {
    case null, calling, incoming, early, connecting, confirmed, disconnected
}

public enum SIPMediaPhase: Equatable, Sendable {
    case none, active, localHold, remoteHold, error
}

public struct SIPAccountCredentials: Sendable {
    public let password: String
    public let turnPassword: String?

    public init(password: String, turnPassword: String? = nil) {
        self.password = password
        self.turnPassword = turnPassword
    }
}

/// The SIP engine as the application sees it. Every method resolves only after
/// the engine has acted; progress and results arrive through `events`.
public protocol SIPService: Sendable {
    var events: AsyncStream<SIPEvent> { get }

    func start() async throws
    func shutdown() async

    func addAccount(_ account: SIPAccount, credentials: SIPAccountCredentials, register: Bool) async throws
    func removeAccount(_ id: UUID) async throws
    func setRegistered(_ registered: Bool, account: UUID) async throws

    func makeCall(uri: String, account: UUID) async throws -> String
    func sendRinging(handle: String) async throws
    func answer(handle: String) async throws
    func hangup(handle: String, statusCode: Int) async throws
    func setHold(_ hold: Bool, handle: String) async throws
    func setMuted(_ muted: Bool, handle: String) async throws
    func sendDTMF(_ digits: String, mode: DTMFMode, handle: String) async throws
    func transfer(handle: String, to uri: String) async throws
    func mediaInfo(handle: String) async -> NegotiatedMedia?

    func audioDevices() async -> [AudioDevice]
    func selectAudioDevices(input: String?, output: String?) async throws
    func audioHardwareChanged()

    func setCodecOrder(_ codecs: [String]) async throws
    func availableCodecs() async -> [String]
    func setSTUNServers(_ servers: [String])
    func handleNetworkChange()
}

public protocol CredentialStore: Sendable {
    func password(for reference: String) throws -> String?
    func setPassword(_ password: String, for reference: String) throws
    func deletePassword(for reference: String) throws
}

/// Bounded exponential backoff with jitter, so many clients recovering from one
/// outage do not reach the server in lockstep.
public struct ReconnectPolicy: Equatable, Sendable {
    public var base: TimeInterval
    public var maximum: TimeInterval
    public var jitter: Double

    public init(base: TimeInterval = 5, maximum: TimeInterval = 300, jitter: Double = 0.2) {
        self.base = base
        self.maximum = maximum
        self.jitter = jitter
    }

    /// `attempt` starts at 1. `random` is in 0...1.
    public func delay(attempt: Int, random: Double) -> TimeInterval {
        let exponent = min(max(attempt, 1) - 1, 16)
        let raw = min(maximum, base * pow(2, Double(exponent)))
        return min(maximum, raw * (1 - jitter + 2 * jitter * random))
    }
}

/// Removes secrets from anything that leaves the app as diagnostics.
public enum DiagnosticsSanitizer {
    private static let headerPatterns = [
        #"(?im)^(\s*(?:proxy-)?authorization\s*:).*$"#,
        #"(?im)^(\s*(?:proxy-|www-)authenticate\s*:).*$"#,
        #"(?im)^(\s*authentication-info\s*:).*$"#,
    ]
    private static let parameterPattern = #"(?i)\b(password|passwd|secret|response|nonce|cnonce)(\s*[=:]\s*)("[^"]*"|[^\s,;]+)"#

    public static func sanitize(_ text: String) -> String {
        var output = text
        for pattern in headerPatterns {
            output = output.replacingOccurrences(of: pattern, with: "$1 <redacted>", options: .regularExpression)
        }
        return output.replacingOccurrences(of: parameterPattern, with: "$1$2<redacted>", options: .regularExpression)
    }
}
