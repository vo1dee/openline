// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import OpenlineCore
import OpenlineStore

public enum PhoneError: Error, Equatable, Sendable {
    case noAccount
    case nothingToDial
    case callInProgress
    case accountInUse
    case microphoneDenied
    case missingCredentials
    case engine(String)
}

@MainActor public protocol CallPresenting: AnyObject {
    func incomingCallBegan(_ call: SIPCall)
    func incomingCallResolved(_ call: SIPCall, missed: Bool)
    func callChanged(_ call: SIPCall?)
}

@MainActor public protocol Ringing: AnyObject {
    func startRinging(_ ringtone: Ringtone, volume: Double)
    func stopRinging()
}

public protocol MicrophoneAccess: Sendable {
    func ensureAccess() async -> Bool
}

/// Owns the SIP engine's lifetime and every policy above it: restoring accounts,
/// the single-call rule, reconnection and call history. It is independent of any
/// window, which is what keeps calls arriving while only the menu bar icon exists.
@MainActor @Observable public final class PhoneCoordinator {
    public private(set) var accounts: [SIPAccount] = []
    public private(set) var registration: [UUID: AccountRegistrationState] = [:]
    public private(set) var lastRegistrationResponse: [UUID: String] = [:]
    public private(set) var activeCall: SIPCall?
    public private(set) var contacts: [Contact] = []
    public private(set) var history: [CallHistoryEntry] = []
    public private(set) var settings = ApplicationSettings()
    public private(set) var audioDevices: [AudioDevice] = []
    public private(set) var availableCodecs: [String] = []
    public private(set) var engineFailure: String?
    public private(set) var lastCallError: PhoneError?
    public private(set) var receivedDTMF = ""
    public private(set) var isRunning = false

    public weak var presenter: (any CallPresenting)?

    private let sip: any SIPService
    private let database: AppDatabase
    private let credentials: any CredentialStore
    private let ringer: (any Ringing)?
    private let microphone: (any MicrophoneAccess)?
    private let policy: ReconnectPolicy
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let random: @Sendable () -> Double
    private let endedCallLinger: TimeInterval

    private var calls: [String: SIPCall] = [:]
    private var activeHandle: String?
    private var answeringHandle: String?
    private var earlyEvents: [String: [SIPEvent]] = [:]
    private var attempts: [UUID: Int] = [:]
    private var retries: [UUID: Task<Void, Never>] = [:]
    private var eventTask: Task<Void, Never>?
    private var transferTimeout: Task<Void, Never>?
    private var loadedAccounts: Set<UUID> = []

    public init(sip: any SIPService, database: AppDatabase, credentials: any CredentialStore,
                ringer: (any Ringing)? = nil, microphone: (any MicrophoneAccess)? = nil,
                policy: ReconnectPolicy = ReconnectPolicy(),
                sleep: (@Sendable (TimeInterval) async -> Void)? = nil,
                random: (@Sendable () -> Double)? = nil,
                endedCallLinger: TimeInterval = 2) {
        self.sip = sip
        self.database = database
        self.credentials = credentials
        self.ringer = ringer
        self.microphone = microphone
        self.policy = policy
        self.sleep = sleep ?? { try? await Task.sleep(for: .seconds($0)) }
        self.random = random ?? { Double.random(in: 0...1) }
        self.endedCallLinger = endedCallLinger
    }

    // MARK: Lifecycle

    public func start() async {
        do {
            settings = try database.settings()
            accounts = try database.accounts()
            contacts = try database.contacts()
            history = try database.history()
        } catch {
            engineFailure = error.localizedDescription
        }
        for account in accounts {
            registration[account.id] = account.isEnabled ? .offline : .disabled
        }
        let stream = sip.events
        eventTask = Task { [weak self] in
            for await event in stream {
                self?.handle(event)
            }
        }
        do {
            try await sip.start()
            isRunning = true
            availableCodecs = await sip.availableCodecs()
            try await sip.setCodecOrder(settings.codecOrder.filter(availableCodecs.contains))
            audioDevices = await sip.audioDevices()
            try await sip.selectAudioDevices(input: settings.inputDevice, output: settings.outputDevice)
            pushSTUNServers()
        } catch {
            engineFailure = error.localizedDescription
            return
        }
        for account in accounts where account.isEnabled {
            await loadIntoEngine(account)
        }
    }

    /// Ends any call, unregisters, releases media and stops the engine threads.
    public func shutdown() async {
        for task in retries.values { task.cancel() }
        retries.removeAll()
        ringer?.stopRinging()
        await sip.shutdown()
        // Calls torn down by the engine report nothing further: record them here.
        for handle in Array(calls.keys) { finish(handle: handle, code: 0, reason: "Application quit") }
        eventTask?.cancel()
        isRunning = false
    }

    public var hasLiveCall: Bool { activeCall?.state.isLive ?? false }

    // MARK: Accounts

    /// `password` nil keeps the stored secret. Rejected while the account is in a call.
    public func saveAccount(_ account: SIPAccount, password: String?, turnPassword: String? = nil) async throws {
        if activeCall?.accountID == account.id, hasLiveCall { throw PhoneError.accountInUse }
        var saved = account
        if let password { try credentials.setPassword(password, for: saved.credentialReference) }
        if let turnPassword { try credentials.setPassword(turnPassword, for: turnReference(saved)) }
        if accounts.isEmpty || !accounts.contains(where: { $0.isDefault && $0.id != saved.id }) { saved.isDefault = true }
        if saved.isDefault {
            for var other in accounts where other.isDefault && other.id != saved.id {
                other.isDefault = false
                try database.save(other)
            }
        }
        try database.save(saved)
        accounts = try database.accounts()
        pushSTUNServers()
        await cancelRetry(saved.id)
        if loadedAccounts.contains(saved.id) {
            try? await sip.removeAccount(saved.id)
            loadedAccounts.remove(saved.id)
        }
        if saved.isEnabled {
            registration[saved.id] = .offline
            await loadIntoEngine(saved)
        } else {
            registration[saved.id] = .disabled
        }
    }

    public func removeAccount(_ id: UUID) async throws {
        if activeCall?.accountID == id, hasLiveCall { throw PhoneError.accountInUse }
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        await cancelRetry(id)
        if loadedAccounts.remove(id) != nil { try await sip.removeAccount(id) }
        try credentials.deletePassword(for: account.credentialReference)
        try credentials.deletePassword(for: turnReference(account))
        try database.deleteAccount(id)
        accounts = try database.accounts()
        registration[id] = nil
        lastRegistrationResponse[id] = nil
        if let first = accounts.first, !accounts.contains(where: \.isDefault) {
            var promoted = first
            promoted.isDefault = true
            try database.save(promoted)
            accounts = try database.accounts()
        }
    }

    public func setEnabled(_ enabled: Bool, account id: UUID) async throws {
        guard var account = accounts.first(where: { $0.id == id }) else { return }
        account.isEnabled = enabled
        try await saveAccount(account, password: nil)
    }

    public func setDefault(account id: UUID) throws {
        for var account in accounts {
            account.isDefault = account.id == id
            try database.save(account)
        }
        accounts = try database.accounts()
    }

    public func reconnect(account id: UUID) async {
        await cancelRetry(id)
        guard let account = accounts.first(where: { $0.id == id }), account.isEnabled else { return }
        if loadedAccounts.contains(id) {
            registration[id] = .registering
            try? await sip.setRegistered(true, account: id)
        } else {
            await loadIntoEngine(account)
        }
    }

    public func password(for account: SIPAccount) -> String? {
        try? credentials.password(for: account.credentialReference)
    }

    private func turnReference(_ account: SIPAccount) -> String { account.credentialReference + "-turn" }

    private func loadIntoEngine(_ account: SIPAccount) async {
        guard isRunning else { return }
        let password: String
        do {
            guard let stored = try credentials.password(for: account.credentialReference) else {
                registration[account.id] = .failed(.credentialUnavailable)
                return
            }
            password = stored
        } catch {
            lastRegistrationResponse[account.id] = error.localizedDescription
            registration[account.id] = .failed(.credentialUnavailable)
            return
        }
        let turn = try? credentials.password(for: turnReference(account))
        do {
            registration[account.id] = .registering
            try await sip.addAccount(account, credentials: SIPAccountCredentials(password: password, turnPassword: turn), register: true)
            loadedAccounts.insert(account.id)
        } catch {
            lastRegistrationResponse[account.id] = error.localizedDescription
            registration[account.id] = .failed(.server(code: 0, reason: error.localizedDescription))
        }
    }

    private func pushSTUNServers() {
        guard isRunning else { return }
        sip.setSTUNServers(Array(Set(accounts.compactMap { $0.stunServer.nonEmpty })).sorted())
    }

    private func cancelRetry(_ id: UUID) async {
        retries[id]?.cancel()
        retries[id] = nil
        attempts[id] = nil
    }

    private func scheduleRetry(_ id: UUID) {
        guard retries[id] == nil, accounts.contains(where: { $0.id == id && $0.isEnabled }) else { return }
        let attempt = (attempts[id] ?? 0) + 1
        attempts[id] = attempt
        let delay = policy.delay(attempt: attempt, random: random())
        let sleep = self.sleep
        retries[id] = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            self?.performRetry(id, attempt: attempt)
        }
    }

    private func performRetry(_ id: UUID, attempt: Int) {
        retries[id] = nil
        registration[id] = .reconnecting(attempt: attempt)
        let sip = self.sip
        Task { try? await sip.setRegistered(true, account: id) }
    }

    /// Network path change or wake from sleep. Only accounts already in a
    /// retryable failure restart their backoff; healthy ones are left alone.
    public func networkChanged() {
        sip.handleNetworkChange()
        for (id, state) in registration {
            guard case .failed(let failure) = state, failure.isRetryable else { continue }
            retries[id]?.cancel()
            retries[id] = nil
            attempts[id] = nil
            scheduleRetry(id)
        }
    }

    // MARK: Calling

    @discardableResult
    public func dial(_ input: String, account explicit: UUID? = nil) async throws -> SIPCall {
        lastCallError = nil
        guard !hasLiveCall else { throw recordError(.callInProgress) }
        guard let account = AccountSelection.outgoing(from: accounts, explicit: explicit) else { throw recordError(.noAccount) }
        guard let uri = DialTarget.requestURI(for: input, account: account) else { throw recordError(.nothingToDial) }
        if let microphone, !(await microphone.ensureAccess()) { throw recordError(.microphoneDenied) }
        guard !hasLiveCall else { throw recordError(.callInProgress) }

        let dialled = DialTarget.sanitized(input)
        var call = SIPCall(accountID: account.id, remote: CallerIdentity(parsing: uri), dialTarget: dialled, direction: .outgoing)
        if let contact = ContactMatcher.match(CallerIdentity(parsing: uri), in: contacts) {
            call.contactID = contact.id
            call.contactName = contact.name
        }
        call.apply(.placed)
        publish(call)
        do {
            let handle = try await sip.makeCall(uri: uri, account: account.id)
            call = activeCall ?? call
            call.engineHandle = handle
            calls[handle] = call
            activeHandle = handle
            publish(call)
            for event in earlyEvents.removeValue(forKey: handle) ?? [] { handle_(event) }
            return activeCall ?? call
        } catch {
            call.failureCode = 0
            call.failureReason = error.localizedDescription
            call.apply(.disconnected(answered: false))
            finalize(call)
            throw recordError(.engine(error.localizedDescription))
        }
    }

    public func answer() async throws {
        guard var call = activeCall, call.state == .incoming, let handle = activeHandle else { return }
        // The call stays incoming until the engine reports otherwise, so a double
        // click or the notification action must not answer it a second time.
        guard answeringHandle != handle else { return }
        answeringHandle = handle
        defer { answeringHandle = nil }
        ringer?.stopRinging()
        if let microphone, !(await microphone.ensureAccess()) {
            call.endedLocally = true
            update(call, handle: handle)
            try? await sip.hangup(handle: handle, statusCode: 480)
            throw recordError(.microphoneDenied)
        }
        try await perform { try await self.sip.answer(handle: handle) }
    }

    public func decline() async throws {
        guard var call = activeCall, call.state == .incoming, let handle = activeHandle,
              answeringHandle != handle else { return }
        ringer?.stopRinging()
        call.endedLocally = true
        call.apply(.hangupRequested)
        update(call, handle: handle)
        try await perform { try await self.sip.hangup(handle: handle, statusCode: 603) }
    }

    public func hangup() async throws {
        guard var call = activeCall, call.state.isLive else { return }
        guard let handle = activeHandle else { return }
        ringer?.stopRinging()
        call.endedLocally = true
        call.apply(.hangupRequested)
        update(call, handle: handle)
        try await perform { try await self.sip.hangup(handle: handle, statusCode: 0) }
    }

    /// The published flag changes only after the engine has rerouted audio.
    public func setMuted(_ muted: Bool) async throws {
        guard let call = activeCall, call.state.isConnected, let handle = activeHandle else { return }
        try await perform { try await self.sip.setMuted(muted, handle: handle) }
        guard var latest = calls[handle] else { return }
        latest.isMuted = muted
        update(latest, handle: handle)
    }

    public func setHold(_ hold: Bool) async throws {
        guard var call = activeCall, let handle = activeHandle else { return }
        guard call.apply(hold ? .holdRequested : .resumeRequested) else { return }
        update(call, handle: handle)
        do {
            try await perform { try await self.sip.setHold(hold, handle: handle) }
        } catch {
            if var latest = calls[handle] {
                latest.apply(hold ? .holdRejected : .resumeRejected)
                update(latest, handle: handle)
            }
            throw error
        }
    }

    public func sendDTMF(_ digits: String) async throws {
        let valid = digits.filter(DialTarget.keypadDigits.contains)
        guard !valid.isEmpty, let call = activeCall, call.state.isConnected, let handle = activeHandle else { return }
        let mode = accounts.first { $0.id == call.accountID }?.dtmf ?? .rfc4733
        try await perform { try await self.sip.sendDTMF(valid, mode: mode, handle: handle) }
    }

    public func transfer(to input: String) async throws {
        guard var call = activeCall, let handle = activeHandle,
              let account = accounts.first(where: { $0.id == call.accountID }) else { return }
        guard let uri = DialTarget.requestURI(for: input, account: account) else { throw recordError(.nothingToDial) }
        guard call.apply(.transferRequested) else { return }
        call.transfer = .inProgress(destination: DialTarget.sanitized(input))
        update(call, handle: handle)
        do {
            try await perform { try await self.sip.transfer(handle: handle, to: uri) }
        } catch {
            transferEnded(handle: handle, code: 0, reason: error.localizedDescription)
            throw error
        }
        // A server that never sends the final NOTIFY must not strand the call.
        transferTimeout?.cancel()
        let sleep = self.sleep
        transferTimeout = Task { [weak self] in
            await sleep(32)
            guard !Task.isCancelled else { return }
            self?.transferEnded(handle: handle, code: 408, reason: "No transfer result from server")
        }
    }

    public func refreshMediaInfo() async {
        guard let handle = activeHandle, activeCall?.state.isConnected == true,
              let media = await sip.mediaInfo(handle: handle), var call = calls[handle] else { return }
        call.media = media
        update(call, handle: handle)
    }

    public func clearCallError() { lastCallError = nil }

    private func perform(_ work: () async throws -> Void) async throws {
        do {
            try await work()
        } catch {
            throw recordError(.engine(error.localizedDescription))
        }
    }

    @discardableResult
    private func recordError(_ error: PhoneError) -> PhoneError {
        lastCallError = error
        return error
    }

    // MARK: Engine events

    private func handle(_ event: SIPEvent) {
        handle_(event)
    }

    private func handle_(_ event: SIPEvent) {
        switch event {
        case let .registrationStarted(account, renewing):
            // A periodic refresh of a good registration is not a visible change.
            if renewing, registration[account]?.isRegistered == false, !isRetrying(account) {
                registration[account] = .registering
            }
        case let .registrationChanged(account, code, reason, expiration, network):
            registrationChanged(account, code: code, reason: reason, expiration: expiration, network: network)
        case let .incomingCall(handle, account, remoteURI, sipCallID):
            incomingCall(handle: handle, account: account, remoteURI: remoteURI, sipCallID: sipCallID)
        case let .callPhase(handle, phase, code, reason, sipCallID):
            guard var call = known(handle, event) else { return }
            if let sipCallID, !sipCallID.isEmpty { call.sipCallID = sipCallID }
            callPhase(&call, handle: handle, phase: phase, code: code, reason: reason)
        case let .callMedia(handle, phase):
            guard var call = known(handle, event) else { return }
            callMedia(&call, handle: handle, phase: phase)
        case let .reinviteFailed(handle, code, reason):
            guard var call = calls[handle] else { return }
            if call.apply(.holdRejected) || call.apply(.resumeRejected) {
                call.failureReason = "\(code) \(reason)"
                update(call, handle: handle)
            }
        case let .transferStatus(handle, code, reason, final):
            transferStatus(handle: handle, code: code, reason: reason, final: final)
        case let .dtmfReceived(_, digit):
            receivedDTMF += digit
        case .audioDevicesChanged:
            let sip = self.sip
            Task { [weak self] in
                let devices = await sip.audioDevices()
                self?.audioDevices = devices
            }
        }
    }

    private func isRetrying(_ account: UUID) -> Bool {
        if case .reconnecting = registration[account] { return true }
        return false
    }

    /// `makeCall` can emit state before its completion reports the handle.
    private func known(_ handle: String, _ event: SIPEvent) -> SIPCall? {
        if let call = calls[handle] { return call }
        earlyEvents[handle, default: []].append(event)
        return nil
    }

    private func registrationChanged(_ id: UUID, code: Int, reason: String, expiration: Int, network: NetworkFailureKind) {
        lastRegistrationResponse[id] = code > 0 ? "\(code) \(reason)" : reason
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        if (200...299).contains(code) {
            if expiration > 0 {
                registration[id] = .registered(expiresIn: expiration)
                retries[id]?.cancel()
                retries[id] = nil
                attempts[id] = nil
            } else {
                registration[id] = account.isEnabled ? .offline : .disabled
            }
            return
        }
        let failure = RegistrationFailure.classify(code: code, reason: reason, network: network)
        registration[id] = .failed(failure)
        if failure.isRetryable { scheduleRetry(id) }
    }

    private func incomingCall(handle: String, account: UUID, remoteURI: String, sipCallID: String?) {
        let identity = CallerIdentity(parsing: remoteURI)
        var call = SIPCall(accountID: account, remote: identity, dialTarget: identity.user ?? identity.uri, direction: .incoming)
        call.engineHandle = handle
        call.sipCallID = sipCallID
        if let contact = ContactMatcher.match(identity, in: contacts) {
            call.contactID = contact.id
            call.contactName = contact.name
        }
        call.apply(.received)
        let sip = self.sip
        switch IncomingCallDecision.decide(hasLiveCall: hasLiveCall, doNotDisturb: settings.doNotDisturb) {
        case .present:
            calls[handle] = call
            activeHandle = handle
            publish(call)
            ringer?.startRinging(settings.ringtone, volume: settings.ringtoneVolume)
            presenter?.incomingCallBegan(call)
            Task { try? await sip.sendRinging(handle: handle) }
        case .rejectBusy, .rejectDoNotDisturb:
            call.rejectedByPolicy = true
            calls[handle] = call
            Task { try? await sip.hangup(handle: handle, statusCode: IncomingCallDecision.busyHere) }
        }
    }

    private func callPhase(_ call: inout SIPCall, handle: String, phase: SIPCallPhase, code: Int, reason: String) {
        switch phase {
        case .calling: call.apply(.trying)
        case .early:
            if call.direction == .outgoing { call.apply(.remoteRinging) }
        case .connecting: call.apply(.connecting)
        case .confirmed:
            let wasIncoming = call.state == .incoming || call.direction == .incoming && call.answeredAt == nil
            if call.apply(.confirmed) {
                call.answeredAt = Date()
                if wasIncoming, call.direction == .incoming {
                    ringer?.stopRinging()
                    presenter?.incomingCallResolved(call, missed: false)
                }
            }
        case .disconnected:
            finish(handle: handle, code: code, reason: reason)
            return
        case .incoming, .null: break
        }
        update(call, handle: handle)
    }

    private func callMedia(_ call: inout SIPCall, handle: String, phase: SIPMediaPhase) {
        switch phase {
        case .localHold:
            call.apply(.holdConfirmed)
            call.isRemoteHold = false
        case .active:
            call.apply(.resumeConfirmed)
            call.isRemoteHold = false
        case .remoteHold:
            // Our own resume arriving while the far end still holds us.
            call.apply(.resumeConfirmed)
            call.isRemoteHold = true
        case .none, .error: break
        }
        update(call, handle: handle)
    }

    private func transferStatus(handle: String, code: Int, reason: String, final: Bool) {
        guard final || code >= 300 else { return }
        guard calls[handle]?.state == .transferring else { return }
        if (200...299).contains(code) {
            transferTimeout?.cancel()
            // Blind transfer succeeded, so this leg is finished unless the
            // server already ended it.
            guard var call = calls[handle] else { return }
            call.endedLocally = true
            call.apply(.hangupRequested)
            call.transfer = .none
            update(call, handle: handle)
            let sip = self.sip
            Task { try? await sip.hangup(handle: handle, statusCode: 0) }
        } else {
            transferEnded(handle: handle, code: code, reason: reason)
        }
    }

    private func transferEnded(handle: String, code: Int, reason: String) {
        transferTimeout?.cancel()
        guard var call = calls[handle], call.state == .transferring else { return }
        call.apply(.transferFailed)
        call.transfer = .failed(code: code, reason: reason)
        update(call, handle: handle)
    }

    private func finish(handle: String, code: Int, reason: String) {
        guard var call = calls.removeValue(forKey: handle) else { return }
        let answered = call.answeredAt != nil
        if !answered || code >= 300 {
            call.failureCode = code > 0 ? code : nil
            call.failureReason = reason.isEmpty ? nil : reason
        }
        call.endedAt = Date()
        call.apply(.disconnected(answered: answered))
        if handle == activeHandle {
            activeHandle = nil
            ringer?.stopRinging()
            transferTimeout?.cancel()
            if call.direction == .incoming, !answered {
                presenter?.incomingCallResolved(call, missed: !call.endedLocally)
            }
        }
        finalize(call)
    }

    private func finalize(_ call: SIPCall) {
        if let entry = CallHistoryEntry(call: call) {
            do {
                try database.record(entry)
                history = try database.history()
            } catch {
                engineFailure = error.localizedDescription
            }
        }
        guard !call.rejectedByPolicy else { return }
        publish(call)
        let linger = endedCallLinger
        let sleep = self.sleep
        let id = call.id
        Task { [weak self] in
            await sleep(linger)
            guard let self, self.activeCall?.id == id, self.activeCall?.state.isTerminal == true else { return }
            self.publish(nil)
        }
    }

    private func update(_ call: SIPCall, handle: String) {
        calls[handle] = call
        if handle == activeHandle { publish(call) }
    }

    private func publish(_ call: SIPCall?) {
        activeCall = call
        presenter?.callChanged(call)
    }

    // MARK: Contacts and history

    public func save(_ contact: Contact) throws {
        var stamped = contact
        stamped.modifiedAt = Date()
        try database.save(stamped)
        contacts = try database.contacts()
    }

    public func deleteContact(_ id: UUID) throws {
        try database.deleteContact(id)
        contacts = try database.contacts()
    }

    public func importContacts(csv: String) throws -> ContactCSV.ImportResult {
        let result = ContactCSV.importContacts(csv, existing: contacts)
        try database.save(contacts: result.new)
        contacts = try database.contacts()
        return result
    }

    public func deleteHistoryEntry(_ id: UUID) throws {
        try database.deleteHistory(id)
        history = try database.history()
    }

    public func clearHistory() throws {
        try database.clearHistory()
        history = []
    }

    // MARK: Settings

    public func updateSettings(_ change: (inout ApplicationSettings) -> Void) throws {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        try database.save(updated)
        let previous = settings
        settings = updated
        guard isRunning else { return }
        let sip = self.sip
        if updated.inputDevice != previous.inputDevice || updated.outputDevice != previous.outputDevice {
            Task { try? await sip.selectAudioDevices(input: updated.inputDevice, output: updated.outputDevice) }
        }
        if updated.codecOrder != previous.codecOrder {
            let codecs = updated.codecOrder.filter(availableCodecs.contains)
            Task { try? await sip.setCodecOrder(codecs) }
        }
    }

    public func refreshAudioDevices() async {
        audioDevices = await sip.audioDevices()
    }

    /// Core Audio reported a change; the engine re-resolves its devices.
    public func audioHardwareChanged() {
        sip.audioHardwareChanged()
    }

    public var diagnosticsReport: String {
        var lines = ["Openline diagnostics", "Date: \(Date().ISO8601Format())", ""]
        for account in accounts {
            lines.append("Account \(account.displayName)")
            lines.append("  Transport: \(account.transport.rawValue)")
            lines.append("  Registrar: \(account.registrarURI)")
            lines.append("  Route: \(account.routeURI ?? "none")")
            lines.append("  State: \(String(describing: registration[account.id] ?? .offline))")
            lines.append("  Last response: \(lastRegistrationResponse[account.id] ?? "none")")
        }
        if let call = activeCall {
            lines.append("Call state: \(call.state)")
            if let media = call.media {
                lines.append("  Codec: \(media.codec)/\(media.clockRate)")
                lines.append("  RTP: tx \(media.txPackets) rx \(media.rxPackets) lost \(media.rxLost) jitter \(media.rxJitterMsec)ms rtt \(media.rttMsec)ms")
            }
        }
        lines.append("Audio devices: \(audioDevices.map(\.name).joined(separator: ", "))")
        lines.append("Codecs: \(settings.codecOrder.joined(separator: ", "))")
        return DiagnosticsSanitizer.sanitize(lines.joined(separator: "\n"))
    }
}
