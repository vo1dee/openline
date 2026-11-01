// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import OpenlineCore
import OpenlineKit
import SwiftUI

/// The one account editor, shared by first launch and Settings.
struct AccountForm: View {
    @Environment(AppModel.self) private var model
    @State var account: SIPAccount
    let isNew: Bool
    let finished: () -> Void
    var cancelTitle: LocalizedStringKey = "Cancel"

    @State private var password = ""
    @State private var turnPassword = ""
    @State private var showPassword = false
    @State private var advanced = false
    @State private var issues: [ValidationIssue] = []
    @State private var connecting = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    field("SIP Server", text: $account.server, prompt: "pbx.example.com", field: .server)
                    field("Extension / Username", text: $account.username, prompt: "101", field: .username)
                    LabeledContent("Password") {
                        HStack {
                            Group {
                                if showPassword {
                                    TextField("Password", text: $password, prompt: Text(isNew ? "" : "Unchanged"))
                                } else {
                                    SecureField("Password", text: $password, prompt: Text(isNew ? "" : "Unchanged"))
                                }
                            }
                            .labelsHidden()
                            .textContentType(.password)
                            .accessibilityIdentifier("account.password")
                            Button {
                                showPassword.toggle()
                            } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(showPassword ? Text("Hide password") : Text("Show password"))
                        }
                    }
                    if issues.contains(where: { $0.field == .password }) {
                        Text("Enter the account password.").font(.caption).foregroundStyle(.red)
                    }
                }
                Section {
                    TextField("Account Name", text: $account.label, prompt: Text(defaultLabel))
                }
                Section(isExpanded: $advanced) {
                    advancedFields
                } header: {
                    Button {
                        advanced.toggle()
                    } label: {
                        Label("Advanced", systemImage: advanced ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                }
            }
            .formStyle(.grouped)
            footer
        }
    }

    @ViewBuilder private var advancedFields: some View {
        optional("Authentication Username", \.authUsername, prompt: account.username, .username)
        optional("SIP Domain", \.domain, prompt: account.server, .domain)
        optional("Registrar", \.registrar, prompt: account.server, .registrar)
        TextField("SIP Port", value: $account.port, format: .number.grouping(.never), prompt: Text("Automatic"))
        if issues.contains(where: { $0.field == .port }) {
            Text("Enter a port between 1 and 65535.").font(.caption).foregroundStyle(.red)
        }
        Picker("Transport", selection: $account.transport) {
            Text(verbatim: "UDP").tag(SIPTransport.udp)
            Text(verbatim: "TCP").tag(SIPTransport.tcp)
            Text(verbatim: "TLS").tag(SIPTransport.tls)
        }
        optional("Outbound Proxy", \.outboundProxy, prompt: "", .outboundProxy)
        optional("SIP Realm", \.realm, prompt: String(localized: "Any"), nil)
        TextField("Registration Interval (seconds)", value: $account.registrationInterval, format: .number.grouping(.never))
        if issues.contains(where: { $0.field == .registrationInterval }) {
            Text("Use a value between 60 and 86400 seconds.").font(.caption).foregroundStyle(.red)
        }
        optional("STUN Server", \.stunServer, prompt: "", .stunServer)
        Toggle("Use ICE", isOn: $account.iceEnabled)
        optional("TURN Server", \.turnServer, prompt: "", nil)
        if account.turnServer.nonEmpty != nil {
            optional("TURN Username", \.turnUsername, prompt: "", nil)
            SecureField("TURN Password", text: $turnPassword)
        }
        Toggle("Rewrite Contact for NAT", isOn: $account.rewriteContact)
        Toggle("Rewrite SDP for NAT", isOn: $account.rewriteSDP)
        Picker("Secure Media (SRTP)", selection: $account.srtp) {
            Text("Off").tag(SRTPMode.disabled)
            Text("Optional").tag(SRTPMode.optional)
            Text("Required").tag(SRTPMode.mandatory)
        }
        if account.srtp != .disabled, account.transport != .tls {
            Text("SRTP keys travel in the signalling, so use TLS to keep them private.")
                .font(.caption).foregroundStyle(.orange)
        }
        Picker("DTMF", selection: $account.dtmf) {
            Text(verbatim: "RFC 4733").tag(DTMFMode.rfc4733)
            Text(verbatim: "SIP INFO").tag(DTMFMode.sipInfo)
        }
        Toggle("Use IPv6", isOn: $account.preferIPv6)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let state = visibleState {
                HStack(spacing: 6) {
                    if connecting, !state.isRegistered, !isFailure(state) { ProgressView().controlSize(.small) }
                    StatusDot(color: state.color)
                    Text(state.isRegistered ? "Connected" : state.title)
                    Spacer()
                }
                .font(.callout)
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(cancelTitle, role: .cancel, action: finished)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(connecting && isFailureOrIdle ? "Try Again" : "Save & Connect", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(connecting && !isFailureOrIdle)
            }
        }
        .padding()
    }

    private var defaultLabel: String { account.username.isEmpty ? String(localized: "Optional") : account.username }

    private var visibleState: AccountRegistrationState? {
        connecting ? model.phone.registration[account.id] : nil
    }

    private func isFailure(_ state: AccountRegistrationState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private var isFailureOrIdle: Bool {
        guard let state = visibleState else { return true }
        return isFailure(state)
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>, prompt: String, field: ValidationIssue.Field) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextField(title, text: text, prompt: Text(verbatim: prompt))
                .autocorrectionDisabled()
                .accessibilityIdentifier("account.\(field)")
            issue(field)
        }
    }

    private func optional(_ title: LocalizedStringKey, _ path: WritableKeyPath<SIPAccount, String?>, prompt: String,
                          _ field: ValidationIssue.Field?) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextField(title, text: Binding(get: { account[keyPath: path] ?? "" },
                                           set: { account[keyPath: path] = $0.isEmpty ? nil : $0 }),
                      prompt: Text(verbatim: prompt))
                .autocorrectionDisabled()
            if let field { issue(field) }
        }
    }

    @ViewBuilder private func issue(_ field: ValidationIssue.Field) -> some View {
        if let found = issues.first(where: { $0.field == field }) {
            Group {
                switch found.problem {
                case .required: Text("Required")
                case .invalidHost: Text("Enter a valid host name or address.")
                case .invalidUsername: Text("Usernames can't contain spaces or < > \" @ :")
                case .invalidPort, .intervalOutOfRange: EmptyView()
                }
            }
            .font(.caption)
            .foregroundStyle(.red)
        }
    }

    private func save() {
        account.server = account.server.trimmingCharacters(in: .whitespaces)
        account.username = account.username.trimmingCharacters(in: .whitespaces)
        let newPassword: String? = isNew || !password.isEmpty ? password : nil
        issues = AccountValidator.validate(account, password: newPassword)
        if !issues.isEmpty {
            if issues.contains(where: { ![.server, .username, .password].contains($0.field) }) { advanced = true }
            return
        }
        saveError = nil
        connecting = true
        let draft = account
        let turn = turnPassword.isEmpty ? nil : turnPassword
        Task {
            do {
                try await model.phone.saveAccount(draft, password: newPassword, turnPassword: turn)
                await waitForResult(draft.id)
            } catch PhoneError.accountInUse {
                connecting = false
                saveError = String(localized: "This account has a call in progress. Try again after it ends.")
            } catch {
                connecting = false
                saveError = error.localizedDescription
            }
        }
    }

    /// The form closes on a real registration result; a failure leaves it open
    /// so the user can correct the settings or keep the account as it is.
    private func waitForResult(_ id: UUID) async {
        for _ in 0..<700 {
            let state = model.phone.registration[id]
            if state?.isRegistered == true {
                try? await Task.sleep(for: .milliseconds(600))
                finished()
                return
            }
            if let state, isFailure(state) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var addingAccount = false

    var body: some View {
        Group {
            if addingAccount {
                AccountForm(account: SIPAccount(), isNew: true, finished: complete, cancelTitle: "Keep Offline")
                    .frame(width: 460, height: 460)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "phone.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Welcome to Openline").font(.title.bold())
                    Text("Connect your SIP account and start calling.").foregroundStyle(.secondary)
                    Button("Add SIP Account") { addingAccount = true }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    Button("Configure Later", action: complete)
                        .buttonStyle(.borderless)
                }
                .padding(40)
                .frame(width: 420)
            }
        }
        .interactiveDismissDisabled()
    }

    private func complete() {
        try? model.phone.updateSettings { $0.hasCompletedOnboarding = true }
    }
}
