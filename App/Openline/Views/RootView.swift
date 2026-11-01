// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import OpenlineCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.section) {
                ForEach(AppSection.allCases, id: \.self) { section in
                    Label(section.title, systemImage: section.symbol)
                }
                if !model.phone.accounts.isEmpty {
                    Section("Accounts") {
                        ForEach(model.phone.accounts) { account in
                            AccountStatusRow(account: account)
                                .selectionDisabled()
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if let call = model.phone.activeCall, call.state.isLive {
                    CallBanner(call: call)
                }
                if let error = model.phone.lastCallError {
                    ErrorBanner(message: error.title) { model.phone.clearCallError() }
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: onboardingVisible) { OnboardingView().environment(model) }
        .task { model.reopenMainWindow = { openWindow(id: AppModel.mainWindowID) } }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .keypad: KeypadView()
        case .recents: RecentsView()
        case .contacts: ContactsView()
        case .favorites: FavoritesView()
        }
    }

    private var onboardingVisible: Binding<Bool> {
        Binding(get: { !model.phone.settings.hasCompletedOnboarding && model.phone.isRunning },
                set: { _ in })
    }
}

struct AccountStatusRow: View {
    @Environment(AppModel.self) private var model
    let account: SIPAccount

    var body: some View {
        let state = model.phone.registration[account.id] ?? .offline
        HStack(spacing: 6) {
            StatusDot(color: state.color)
            VStack(alignment: .leading, spacing: 0) {
                Text(account.displayName).lineLimit(1)
                Text(state.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct CallBanner: View {
    @Environment(AppModel.self) private var model
    let call: SIPCall

    var body: some View {
        HStack {
            Image(systemName: "phone.connection.fill").foregroundStyle(.green).accessibilityHidden(true)
            Text(model.displayName(call)).fontWeight(.medium).lineLimit(1)
            Text(call.state.title).foregroundStyle(.secondary)
            Spacer()
            Button("Show Call") { model.showCallPanel() }
            Button("Hang Up", role: .destructive) { model.perform { try await model.phone.hangup() } }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct ErrorBanner: View {
    let message: LocalizedStringKey
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).accessibilityHidden(true)
            Text(message).lineLimit(2)
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Open Phone") { model.openMainWindow() }
        Divider()
        Text(summary)
        ForEach(model.phone.accounts) { account in
            let state = model.phone.registration[account.id] ?? .offline
            Text("\(account.displayName): \(Text(state.title))")
        }
        if let call = model.phone.activeCall, call.state.isLive {
            Divider()
            Text("\(model.displayName(call)) – \(Text(call.state.title))")
            Button("Show Call") { model.showCallPanel() }
            Button(call.isMuted ? "Unmute" : "Mute") {
                model.perform { try await model.phone.setMuted(!call.isMuted) }
            }
            .disabled(!call.state.isConnected)
            Button("Hang Up") { model.perform { try await model.phone.hangup() } }
        }
        let recent = Array(model.phone.history.prefix(5))
        if !recent.isEmpty {
            Divider()
            Menu("Recent Calls") {
                ForEach(recent) { entry in
                    Button(entry.displayIdentity) { model.callTarget(for: entry) }
                }
            }
        }
        Divider()
        Toggle("Do Not Disturb", isOn: Binding(get: { model.phone.settings.doNotDisturb },
                                               set: { value in try? model.phone.updateSettings { $0.doNotDisturb = value } }))
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Openline") { NSApp.terminate(nil) }
    }

    private var summary: LocalizedStringKey {
        let total = model.phone.accounts.filter(\.isEnabled).count
        if total == 0 { return "No accounts enabled" }
        return "\(model.registeredAccountCount) of \(total) accounts registered"
    }
}
