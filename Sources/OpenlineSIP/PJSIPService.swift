// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import OpenlineBridge
import OpenlineCore

/// `SIPService` backed by PJSIP. Thread ownership lives in `OLEngine`; this type
/// only converts between Swift values and the Objective-C facade.
public final class PJSIPService: SIPService, @unchecked Sendable {
    public struct TestAudio: Sendable {
        public let sourceWAV: String
        public let recordWAV: String
        public let skipTLSVerification: Bool

        public init(sourceWAV: String, recordWAV: String, skipTLSVerification: Bool = false) {
            self.sourceWAV = sourceWAV
            self.recordWAV = recordWAV
            self.skipTLSVerification = skipTLSVerification
        }
    }

    public let events: AsyncStream<SIPEvent>
    private let continuation: AsyncStream<SIPEvent>.Continuation
    private let engine: OLEngine
    private let userAgent: String
    private let testAudio: TestAudio?

    /// `testAudio` replaces sound hardware for the integration harness.
    public init(userAgent: String, logLevel: Int = 0, log: (@Sendable (String) -> Void)? = nil, testAudio: TestAudio? = nil) {
        let (stream, continuation) = AsyncStream.makeStream(of: SIPEvent.self)
        events = stream
        self.continuation = continuation
        self.userAgent = userAgent
        self.testAudio = testAudio
        engine = OLEngine { event in
            if let converted = SIPEvent(event) { continuation.yield(converted) }
        }
        if let log { engine.setLogHandler({ log($0) }, level: logLevel) }
    }

    public func start() async throws {
        let config = OLEngineConfig()
        config.userAgent = userAgent
        if let testAudio {
            config.nullAudio = true
            config.sourceWAV = testAudio.sourceWAV
            config.recordWAV = testAudio.recordWAV
            config.skipTLSVerificationForTesting = testAudio.skipTLSVerification
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            engine.start(config) { done.resume(error: $0) }
        }
    }

    public func shutdown() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            engine.shutdown { done.resume() }
        }
    }

    public func addAccount(_ account: SIPAccount, credentials: SIPAccountCredentials, register: Bool) async throws {
        let spec = OLAccountSpec()
        spec.accountID = account.id.uuidString
        spec.idURI = account.addressOfRecord
        spec.registrarURI = account.registrarURI
        spec.proxyURI = account.routeURI
        spec.authUsername = account.effectiveAuthUsername
        spec.password = credentials.password
        spec.realm = account.realm.nonEmpty ?? "*"
        spec.transport = switch account.transport {
        case .udp: .UDP
        case .tcp: .TCP
        case .tls: .TLS
        }
        spec.registrationInterval = account.registrationInterval
        spec.useSTUN = account.stunServer.nonEmpty != nil
        spec.iceEnabled = account.iceEnabled
        spec.turnServer = account.turnServer.nonEmpty
        spec.turnUsername = account.turnUsername
        spec.turnPassword = credentials.turnPassword
        spec.rewriteContact = account.rewriteContact
        spec.rewriteSDP = account.rewriteSDP
        spec.srtp = switch account.srtp {
        case .disabled: .disabled
        case .optional: .optional
        case .mandatory: .mandatory
        }
        spec.dtmfMethod = account.dtmf == .sipInfo ? .sipInfo : .RFC4733
        spec.preferIPv6 = account.preferIPv6
        try await complete { self.engine.addAccount(spec, registerNow: register, completion: $0) }
    }

    public func removeAccount(_ id: UUID) async throws {
        try await complete { self.engine.removeAccount(id.uuidString, completion: $0) }
    }

    public func setRegistered(_ registered: Bool, account: UUID) async throws {
        try await complete { self.engine.setRegistered(registered, account: account.uuidString, completion: $0) }
    }

    public func makeCall(uri: String, account: UUID) async throws -> String {
        try await withCheckedThrowingContinuation { done in
            engine.makeCall(to: uri, account: account.uuidString) { handle, error in
                if let handle {
                    done.resume(returning: handle)
                } else {
                    done.resume(throwing: error ?? CocoaError(.featureUnsupported))
                }
            }
        }
    }

    public func sendRinging(handle: String) async throws {
        try await complete { self.engine.sendRinging(handle, completion: $0) }
    }

    public func answer(handle: String) async throws {
        try await complete { self.engine.answer(handle, completion: $0) }
    }

    public func hangup(handle: String, statusCode: Int) async throws {
        try await complete { self.engine.hangup(handle, statusCode: statusCode, completion: $0) }
    }

    public func setHold(_ hold: Bool, handle: String) async throws {
        try await complete { self.engine.setHold(hold, call: handle, completion: $0) }
    }

    public func setMuted(_ muted: Bool, handle: String) async throws {
        try await complete { self.engine.setMuted(muted, call: handle, completion: $0) }
    }

    public func sendDTMF(_ digits: String, mode: DTMFMode, handle: String) async throws {
        try await complete {
            self.engine.sendDTMF(digits, method: mode == .sipInfo ? .sipInfo : .RFC4733, call: handle, completion: $0)
        }
    }

    public func transfer(handle: String, to uri: String) async throws {
        try await complete { self.engine.transfer(handle, to: uri, completion: $0) }
    }

    public func mediaInfo(handle: String) async -> NegotiatedMedia? {
        await withCheckedContinuation { done in
            engine.stats(forCall: handle) { stats in
                done.resume(returning: stats.map {
                    NegotiatedMedia(codec: $0.codec, clockRate: $0.clockRate, remoteAddress: $0.remoteAddress,
                                    txPackets: $0.txPackets, rxPackets: $0.rxPackets, rxLost: $0.rxLost,
                                    rxJitterMsec: $0.rxJitterMsec, rttMsec: $0.rttMsec,
                                    rxLevel: $0.rxLevel, txLevel: $0.txLevel)
                })
            }
        }
    }

    public func audioDevices() async -> [AudioDevice] {
        await withCheckedContinuation { done in
            engine.listAudioDevices { devices in
                done.resume(returning: devices.map {
                    AudioDevice(name: $0.name, inputChannels: $0.inputChannels, outputChannels: $0.outputChannels)
                })
            }
        }
    }

    public func selectAudioDevices(input: String?, output: String?) async throws {
        try await complete { self.engine.selectAudioInput(input, output: output, completion: $0) }
    }

    public func audioHardwareChanged() { engine.audioHardwareChanged() }

    public func setCodecOrder(_ codecs: [String]) async throws {
        try await complete { self.engine.setCodecOrder(codecs, completion: $0) }
    }

    public func availableCodecs() async -> [String] {
        await withCheckedContinuation { done in
            engine.availableCodecs { done.resume(returning: $0) }
        }
    }

    public func setSTUNServers(_ servers: [String]) { engine.setSTUNServers(servers) }
    public func handleNetworkChange() { engine.handleNetworkChange() }

    private func complete(_ body: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            body { done.resume(error: $0) }
        }
    }
}

private extension CheckedContinuation where T == Void, E == Error {
    func resume(error: Error?) {
        if let error { resume(throwing: error) } else { resume() }
    }
}

private extension SIPEvent {
    init?(_ event: OLEvent) {
        let handle = event.callHandle ?? ""
        let account = event.accountID.flatMap(UUID.init(uuidString:))
        switch event.kind {
        case .registrationStarted:
            guard let account else { return nil }
            self = .registrationStarted(account: account, renewing: event.renewing)
        case .registrationChanged:
            guard let account else { return nil }
            let network: NetworkFailureKind = switch event.failure {
            case .DNS: .dns
            case .TLS: .tls
            case .network: .network
            default: .none
            }
            self = .registrationChanged(account: account, code: event.statusCode, reason: event.reason ?? "",
                                        expiration: event.expiration, network: network)
        case .incomingCall:
            guard let account else { return nil }
            self = .incomingCall(handle: handle, account: account, remoteURI: event.remoteURI ?? "", sipCallID: event.sipCallID)
        case .callState:
            let phase: SIPCallPhase = switch event.callPhase {
            case .calling: .calling
            case .incoming: .incoming
            case .early: .early
            case .connecting: .connecting
            case .confirmed: .confirmed
            case .disconnected: .disconnected
            default: .null
            }
            self = .callPhase(handle: handle, phase: phase, code: event.statusCode, reason: event.reason ?? "", sipCallID: event.sipCallID)
        case .callMedia:
            let phase: SIPMediaPhase = switch event.mediaPhase {
            case .active: .active
            case .localHold: .localHold
            case .remoteHold: .remoteHold
            case .error: .error
            default: .none
            }
            self = .callMedia(handle: handle, phase: phase)
        case .callReinviteFailed:
            self = .reinviteFailed(handle: handle, code: event.statusCode, reason: event.reason ?? "")
        case .callTransferStatus:
            self = .transferStatus(handle: handle, code: event.statusCode, reason: event.reason ?? "", final: event.finalNotify)
        case .callDTMFReceived:
            self = .dtmfReceived(handle: handle, digit: event.digit ?? "")
        case .audioDevicesChanged:
            self = .audioDevicesChanged
        @unknown default:
            return nil
        }
    }
}
