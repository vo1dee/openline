// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import OpenlineCore
import OpenlineKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Accounts", systemImage: "person.crop.circle") { AccountsSettings() }
            Tab("Audio", systemImage: "speaker.wave.2") { AudioSettings() }
            Tab("Calls", systemImage: "phone") { CallSettings() }
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") { AdvancedSettings() }
        }
        .frame(width: 560, height: 460)
    }
}

extension View {
    /// Writes one settings field straight through to the coordinator.
    @MainActor func settingBinding<T>(_ model: AppModel, _ path: WritableKeyPath<ApplicationSettings, T>) -> Binding<T> {
        Binding(get: { model.phone.settings[keyPath: path] },
                set: { value in try? model.phone.updateSettings { $0[keyPath: path] = value } })
    }
}

struct AccountsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: EditTarget?
    @State private var pendingRemoval: SIPAccount?
    @State private var problem: String?

    private struct EditTarget: Identifiable {
        let account: SIPAccount
        let isNew: Bool
        var id: UUID { account.id }
    }

    var body: some View {
        VStack(alignment: .leading) {
            List(model.phone.accounts) { account in
                let state = model.phone.registration[account.id] ?? .offline
                HStack {
                    StatusDot(color: state.color)
                    VStack(alignment: .leading) {
                        HStack(spacing: 4) {
                            Text(account.displayName)
                            if account.isDefault {
                                Text("Default").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text(state.title).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Enabled", isOn: Binding(get: { account.isEnabled },
                                                    set: { value in run { try await model.phone.setEnabled(value, account: account.id) } }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    Button("Edit") { editing = EditTarget(account: account, isNew: false) }
                    Menu {
                        Button("Reconnect") { Task { await model.phone.reconnect(account: account.id) } }
                            .disabled(!account.isEnabled)
                        Button("Make Default") { try? model.phone.setDefault(account: account.id) }
                            .disabled(account.isDefault)
                        Divider()
                        Button("Remove…", role: .destructive) { pendingRemoval = account }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(Text("More actions for \(account.displayName)"))
                }
                .accessibilityElement(children: .contain)
            }
            .overlay {
                if model.phone.accounts.isEmpty {
                    ContentUnavailableView("No Accounts", systemImage: "person.crop.circle.badge.plus")
                }
            }
            Button("Add Account…") { editing = EditTarget(account: SIPAccount(), isNew: true) }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .sheet(item: $editing) { target in
            AccountForm(account: target.account, isNew: target.isNew) { editing = nil }
                .environment(model)
                .frame(width: 460, height: 460)
        }
        .confirmationDialog("Remove this account?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("Remove Account", role: .destructive) {
                if let account = pendingRemoval { run { try await model.phone.removeAccount(account.id) } }
            }
        } message: {
            Text("Its password is deleted from the Keychain. Call history is kept.")
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        problem = nil
        Task {
            do {
                try await action()
            } catch PhoneError.accountInUse {
                problem = String(localized: "This account has a call in progress. Try again after it ends.")
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

struct AudioSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var tests = model.audioTests
        Form {
            Section {
                Picker("Microphone", selection: settingBinding(model, \.inputDevice)) {
                    Text("System Default").tag(String?.none)
                    ForEach(model.phone.audioDevices.filter { $0.inputChannels > 0 }) { Text($0.name).tag(String?.some($0.name)) }
                }
                LabeledContent("Input Level") {
                    ProgressView(value: tests.inputLevel).frame(width: 180)
                }
                Button(tests.isMeasuring ? "Stop Test" : "Test Microphone") {
                    if tests.isMeasuring {
                        tests.stopMeter()
                    } else {
                        Task { await tests.startMeter(device: model.phone.settings.inputDevice) }
                    }
                }
                .disabled(model.phone.hasLiveCall)
                if let failure = tests.failure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                Picker("Speaker", selection: settingBinding(model, \.outputDevice)) {
                    Text("System Default").tag(String?.none)
                    ForEach(model.phone.audioDevices.filter { $0.outputChannels > 0 }) { Text($0.name).tag(String?.some($0.name)) }
                }
                Button("Test Speaker") {
                    tests.playTestTone(volume: 0.7, device: model.phone.settings.outputDevice)
                }
                .disabled(model.phone.hasLiveCall)
            }
            Section {
                Picker("Ringtone", selection: settingBinding(model, \.ringtone)) {
                    ForEach(Ringtone.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Slider(value: settingBinding(model, \.ringtoneVolume), in: 0...1) { Text("Ringtone Volume") }
                Button("Preview Ringtone") {
                    tests.previewRingtone(model.phone.settings.ringtone, volume: model.phone.settings.ringtoneVolume,
                                          device: model.phone.settings.outputDevice)
                }
                .disabled(model.phone.hasLiveCall)
            }
        }
        .formStyle(.grouped)
        .task { await model.phone.refreshAudioDevices() }
        .onDisappear { tests.stopMeter() }
    }
}

struct CallSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle("Do Not Disturb", isOn: settingBinding(model, \.doNotDisturb))
                Text("Incoming calls are refused with SIP 486 Busy Here and logged as missed. This is separate from macOS Focus.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Default Outgoing Account", selection: defaultAccount) {
                    ForEach(model.phone.accounts) { Text($0.displayName).tag($0.id as UUID?) }
                }
                .disabled(model.phone.accounts.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    private var defaultAccount: Binding<UUID?> {
        Binding(get: { model.phone.accounts.first(where: \.isDefault)?.id },
                set: { id in if let id { try? model.phone.setDefault(account: id) } })
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: Binding(get: { model.phone.settings.launchAtLogin },
                                                        set: { model.setLaunchAtLogin($0) }))
                Toggle("Show Menu Bar Icon", isOn: settingBinding(model, \.showMenuBarIcon))
                Text("Openline keeps running when you close its window, so calls still arrive. Quit it to go offline; while it isn't running, you can't receive calls.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Appearance", selection: settingBinding(model, \.appearance)) {
                    ForEach(AppearancePreference.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model
    @State private var liveLog = ""

    var body: some View {
        Form {
            Section("Codecs") {
                List {
                    ForEach(model.phone.settings.codecOrder.filter(model.phone.availableCodecs.contains), id: \.self) { codec in
                        Text(codecName(codec))
                    }
                    .onMove { from, to in
                        try? model.phone.updateSettings { $0.codecOrder.move(fromOffsets: from, toOffset: to) }
                    }
                }
                .frame(height: 100)
                Text("Drag to set the order. Applies to all accounts, from the next call.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                ForEach(model.phone.accounts) { account in
                    LabeledContent(account.displayName) {
                        Text(model.phone.lastRegistrationResponse[account.id] ?? String(localized: "No response yet"))
                    }
                }
                if let media = model.phone.activeCall?.media {
                    LabeledContent("Codec") { Text(verbatim: "\(media.codec)/\(media.clockRate)") }
                    LabeledContent("Packets") { Text("Sent \(media.txPackets), received \(media.rxPackets), lost \(media.rxLost)") }
                    LabeledContent("Jitter") { Text("\(media.rxJitterMsec) ms") }
                }
                Toggle("Detailed SIP Logging", isOn: settingBinding(model, \.diagnosticLogging))
                Text("Takes effect after relaunching. The log contains phone numbers and addresses, stays in memory and has credentials removed.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Export Diagnostics…", action: export)
            }
            Section("About") {
                LabeledContent("Version") { Text(Bundle.main.shortVersion) }
                Text("Openline is free software under the GNU GPL version 3 or later. It uses PJSIP, Opus, libsrtp, WebRTC AEC3 and GRDB; see THIRD_PARTY_LICENSES.md.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                await model.phone.refreshMediaInfo()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func codecName(_ id: String) -> String {
        let parts = id.split(separator: "/")
        return parts.count >= 2 ? "\(parts[0]) (\(Int(parts[1]).map { $0 / 1000 } ?? 0) kHz)" : id
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Openline Diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let report = model.phone.diagnosticsReport + "\n\n" + model.diagnosticLog.text
        try? report.write(to: url, atomically: true, encoding: .utf8)
    }
}
