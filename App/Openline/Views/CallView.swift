// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import OpenlineCore
import SwiftUI

struct CallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingKeypad = false
    @State private var showingTransfer = false

    var body: some View {
        Group {
            if let call = model.phone.activeCall {
                content(call)
            } else {
                Color.clear
            }
        }
        .frame(width: 340, height: 480)
        .background(.regularMaterial)
        .sheet(isPresented: $showingTransfer) { TransferSheet().environment(model) }
        .onChange(of: model.phone.activeCall?.state) { _, state in
            if let state { AccessibilityNotification.Announcement(String(localized: state.spokenName)).post() }
        }
    }

    @ViewBuilder private func content(_ call: SIPCall) -> some View {
        VStack(spacing: 14) {
            header(call)
            Spacer(minLength: 0)
            if call.state == .incoming {
                incomingControls
            } else if showingKeypad, call.state.isConnected {
                KeypadGrid { digit in model.perform { try await model.phone.sendDTMF(digit) } }
                Button("Hide Keypad") { showingKeypad = false }
            } else {
                activeControls(call)
            }
            Spacer(minLength: 0)
            if call.state != .incoming, !call.state.isTerminal {
                Button {
                    model.perform { try await model.phone.hangup() }
                } label: {
                    Label("Hang Up", systemImage: "phone.down.fill").frame(minWidth: 120)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(call.state == .ending)
            }
        }
        .padding(20)
        .padding(.top, 12)
        .animation(reduceMotion ? nil : .snappy, value: call.state)
    }

    private func header(_ call: SIPCall) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.displayName(call))
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            if call.contactName != nil, let user = call.remote.user {
                Text(user).foregroundStyle(.secondary)
            }
            statusLine(call)
            Text(model.accountName(call.accountID)).font(.caption).foregroundStyle(.secondary)
            if call.isRemoteHold {
                Text("The other party put you on hold").font(.caption).foregroundStyle(.orange)
            }
            if case let .failed(code, reason) = call.transfer {
                Text(code > 0 ? "Transfer failed: \(code) \(reason)" : "Transfer failed: \(reason)")
                    .font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            if case let .inProgress(destination) = call.transfer {
                Text("Transferring to \(destination)…").font(.caption).foregroundStyle(.secondary)
            }
            if let reason = call.failureReason, call.state.isTerminal {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func statusLine(_ call: SIPCall) -> some View {
        if call.state == .established, let answered = call.answeredAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date.timeIntervalSince(answered).callDuration)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(call.state.title).foregroundStyle(.secondary)
        }
    }

    private var incomingControls: some View {
        HStack(spacing: 32) {
            Button {
                model.perform { try await model.phone.decline() }
            } label: {
                Label("Decline", systemImage: "phone.down.fill").frame(minWidth: 90)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .controlSize(.large)
            Button {
                NSApp.activate()
                model.perform { try await model.phone.answer() }
            } label: {
                Label("Answer", systemImage: "phone.fill").frame(minWidth: 90)
            }
            .buttonStyle(.glassProminent)
            .tint(.green)
            .controlSize(.large)
        }
    }

    @ViewBuilder private func activeControls(_ call: SIPCall) -> some View {
        let connected = call.state.isConnected
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                control(call.isMuted ? "Unmute" : "Mute", symbol: call.isMuted ? "mic.slash.fill" : "mic.fill",
                        active: call.isMuted, enabled: connected) {
                    model.perform { try await model.phone.setMuted(!call.isMuted) }
                }
                control(call.state.isOnHold ? "Resume" : "Hold", symbol: call.state.isOnHold ? "play.fill" : "pause.fill",
                        active: call.state == .held, enabled: call.state == .established || call.state == .held) {
                    model.perform { try await model.phone.setHold(call.state != .held) }
                }
                control("Keypad", symbol: "circle.grid.3x3.fill", active: false, enabled: connected) { showingKeypad = true }
            }
            GridRow {
                control("Transfer", symbol: "arrow.turn.up.right", active: false,
                        enabled: call.state == .established || call.state == .held) { showingTransfer = true }
                AudioRouteMenu()
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
        }
    }

    private func control(_ title: LocalizedStringKey, symbol: String, active: Bool, enabled: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3).frame(height: 22)
                Text(title).font(.caption)
            }
            .frame(width: 76, height: 52)
        }
        .buttonStyle(.glass)
        .tint(active ? .accentColor : nil)
        .disabled(!enabled)
        .accessibilityValue(active ? Text("On") : Text("Off"))
    }
}

private extension CallState {
    var spokenName: LocalizedStringResource {
        switch self {
        case .incoming: "Incoming call"
        case .remoteRinging: "Ringing"
        case .established: "Call connected"
        case .held: "Call on hold"
        case .ended: "Call ended"
        case .failed: "Call failed"
        default: "Call updating"
        }
    }
}

struct AudioRouteMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Picker("Microphone", selection: device(\.inputDevice)) {
                Text("System Default").tag(String?.none)
                ForEach(model.phone.audioDevices.filter { $0.inputChannels > 0 }) { Text($0.name).tag(String?.some($0.name)) }
            }
            Picker("Speaker", selection: device(\.outputDevice)) {
                Text("System Default").tag(String?.none)
                ForEach(model.phone.audioDevices.filter { $0.outputChannels > 0 }) { Text($0.name).tag(String?.some($0.name)) }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "speaker.wave.2.fill").font(.title3).frame(height: 22)
                Text("Audio").font(.caption)
            }
            .frame(width: 76, height: 52)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .accessibilityLabel(Text("Audio devices"))
    }

    private func device(_ path: WritableKeyPath<ApplicationSettings, String?>) -> Binding<String?> {
        Binding(get: { model.phone.settings[keyPath: path] },
                set: { value in try? model.phone.updateSettings { $0[keyPath: path] = value } })
    }
}

struct TransferSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Blind Transfer").font(.headline)
            TextField("Extension, number or SIP address", text: $destination)
                .textFieldStyle(.roundedBorder)
                .onSubmit(transfer)
            let found = Array(model.phone.contacts.filter { $0.matches(search: destination) && $0.primaryTarget != nil }.prefix(4))
            ForEach(found) { contact in
                Button {
                    destination = contact.primaryTarget ?? ""
                } label: {
                    HStack {
                        Text(contact.name)
                        Spacer()
                        Text(contact.primaryTarget ?? "").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if DialTarget.isDialable(destination) {
                Text("The call will be sent to \(DialTarget.sanitized(destination)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Transfer", action: transfer)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!DialTarget.isDialable(destination))
            }
        }
        .padding()
        .frame(width: 300)
    }

    private func transfer() {
        guard DialTarget.isDialable(destination) else { return }
        let target = destination
        dismiss()
        model.perform { try await model.phone.transfer(to: target) }
    }
}
