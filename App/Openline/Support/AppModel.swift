// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Observation
import OpenlineCore
import OpenlineKit
import OpenlineSIP
import OpenlineStore
import ServiceManagement
import SwiftUI

enum AppSection: String, CaseIterable, Hashable {
    case keypad, recents, contacts, favorites

    var title: LocalizedStringKey {
        switch self {
        case .keypad: "Keypad"
        case .recents: "Recents"
        case .contacts: "Contacts"
        case .favorites: "Favorites"
        }
    }

    var symbol: String {
        switch self {
        case .keypad: "circle.grid.3x3.fill"
        case .recents: "clock"
        case .contacts: "person.crop.circle"
        case .favorites: "star"
        }
    }
}

/// Application shell state. The phone itself lives in `PhoneCoordinator`.
@MainActor @Observable final class AppModel: CallPresenting {
    static let mainWindowID = "main"
    static let shared = AppModel()

    let phone: PhoneCoordinator
    let diagnosticLog: DiagnosticLog
    let startupError: String?

    var section: AppSection = .keypad
    var dialText = ""
    var selectedAccount: UUID?
    var dialerFocusRequest = 0
    var searchFocusRequest = 0
    var isQuitting = false
    var reopenMainWindow: (() -> Void)?
    var contactDraftFromHistory: Contact?
    var audioTests = AudioTestBench()

    @ObservationIgnored private let callPanel = CallPanelController()
    @ObservationIgnored private let notifier = CallNotifier()
    @ObservationIgnored private let network = NetworkMonitor()
    @ObservationIgnored private let audioHardware = AudioHardwareMonitor()
    @ObservationIgnored private var started = false

    private init() {
        let log = DiagnosticLog()
        diagnosticLog = log
        var failure: String?
        let database: AppDatabase
        // UI tests run under a throwaway profile, away from the user's data.
        let profile = ProcessInfo.processInfo.environment["OPENLINE_TEST_PROFILE"]
        do {
            let url = try AppDatabase.defaultURL()
            let file = profile.map { url.deletingLastPathComponent().appending(path: "test-\($0).sqlite") } ?? url
            database = try AppDatabase(path: file.path)
        } catch {
            failure = error.localizedDescription
            database = try! AppDatabase()
        }
        let logging = (try? database.settings().diagnosticLogging) ?? false
        var logHandler: (@Sendable (String) -> Void)?
        if logging { logHandler = { log.append($0) } }
        let sip = PJSIPService(userAgent: "Openline/\(Bundle.main.shortVersion)", logLevel: logging ? 5 : 0, log: logHandler)
        phone = PhoneCoordinator(sip: sip, database: database, credentials: KeychainCredentialStore(service: profile.map { "org.openline.test.\($0)" } ?? "org.openline.sip"),
                                 ringer: ToneRinger(), microphone: SystemMicrophoneAccess())
        startupError = failure
        phone.presenter = self
        notifier.delegate = self
    }

    func start() {
        guard !started else { return }
        started = true
        notifier.requestAuthorization()
        Task {
            await phone.start()
            // Stays up past the first save, so the form can show the real result.
            if !phone.accounts.isEmpty { try? phone.updateSettings { $0.hasCompletedOnboarding = true } }
        }
        network.onChange = { [weak self] in self?.phone.networkChanged() }
        network.start()
        audioHardware.onChange = { [weak self] in self?.phone.audioHardwareChanged() }
        audioHardware.start()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.phone.networkChanged() }
        }
    }

    // MARK: Navigation

    func show(_ target: AppSection) {
        openMainWindow()
        section = target
    }

    func openMainWindow() {
        reopenMainWindow?()
        NSApp.activate()
    }

    func focusDialer() {
        show(.keypad)
        dialerFocusRequest += 1
    }

    func focusSearch() {
        if section == .keypad { dialerFocusRequest += 1 } else { searchFocusRequest += 1 }
    }

    func showCallPanel() {
        if let call = phone.activeCall { callPanel.show(for: call, model: self) }
    }

    // MARK: Calling

    func call(_ target: String, account: UUID? = nil) {
        Task {
            do {
                try await phone.dial(target, account: account ?? selectedAccount)
            } catch {
                presentCallError()
            }
        }
    }

    func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                presentCallError()
            }
        }
    }

    private func presentCallError() {
        if phone.lastCallError == .microphoneDenied { openMainWindow() }
    }

    func callTarget(for entry: CallHistoryEntry) { call(entry.dialTarget, account: entry.accountID) }

    func addToContacts(_ entry: CallHistoryEntry) {
        contactDraftFromHistory = Contact(name: entry.displayIdentity == entry.dialTarget ? "" : entry.displayIdentity,
                                          numbers: [ContactNumber(value: entry.dialTarget)])
        section = .contacts
    }

    // MARK: CallPresenting

    func incomingCallBegan(_ call: SIPCall) {
        callPanel.show(for: call, model: self)
        notifier.notifyIncoming(call, title: displayName(call), account: accountName(call.accountID))
    }

    func incomingCallResolved(_ call: SIPCall, missed: Bool) {
        notifier.clearIncoming()
        if missed { notifier.notifyMissed(title: displayName(call)) }
    }

    func callChanged(_ call: SIPCall?) {
        if let call {
            if !callPanel.isVisible, call.state.isLive { callPanel.show(for: call, model: self) }
        } else {
            callPanel.close()
        }
    }

    // MARK: Display helpers

    func displayName(_ call: SIPCall) -> String { call.contactName ?? call.remote.label }

    func accountName(_ id: UUID) -> String {
        phone.accounts.first { $0.id == id }?.displayName ?? String(localized: "Removed account")
    }

    func contact(_ id: UUID?) -> Contact? { id.flatMap { id in phone.contacts.first { $0.id == id } } }

    var menuBarIconVisible: Binding<Bool> {
        // The label holds the only always-alive openWindow action, so it stays
        // inserted until it has handed that action over.
        Binding(get: { self.phone.settings.showMenuBarIcon || self.reopenMainWindow == nil },
                set: { value in try? self.phone.updateSettings { $0.showMenuBarIcon = value } })
    }

    var menuBarSymbol: String {
        if phone.hasLiveCall { return "phone.connection.fill" }
        if phone.settings.doNotDisturb { return "moon.fill" }
        return registeredAccountCount > 0 ? "phone.fill" : "phone.badge.waveform"
    }

    var registeredAccountCount: Int { phone.registration.values.filter(\.isRegistered).count }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            try phone.updateSettings { $0.launchAtLogin = enabled }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
}
