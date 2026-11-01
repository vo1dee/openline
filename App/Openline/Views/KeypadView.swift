// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import OpenlineCore
import SwiftUI

struct DialKey: Identifiable {
    var id: String { digit }
    let digit: String
    let letters: String

    static let all: [DialKey] = [
        .init(digit: "1", letters: ""), .init(digit: "2", letters: "ABC"), .init(digit: "3", letters: "DEF"),
        .init(digit: "4", letters: "GHI"), .init(digit: "5", letters: "JKL"), .init(digit: "6", letters: "MNO"),
        .init(digit: "7", letters: "PQRS"), .init(digit: "8", letters: "TUV"), .init(digit: "9", letters: "WXYZ"),
        .init(digit: "*", letters: ""), .init(digit: "0", letters: "+"), .init(digit: "#", letters: ""),
    ]
}

struct KeypadGrid: View {
    let press: (String) -> Void

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(0..<4) { row in
                GridRow {
                    ForEach(DialKey.all[(row * 3)..<(row * 3 + 3)]) { key in
                        Button {
                            press(key.digit)
                        } label: {
                            VStack(spacing: 0) {
                                Text(key.digit).font(.title2.monospacedDigit())
                                Text(key.letters).font(.caption2).foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            .frame(width: 54, height: 44)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel(key.digit == "*" ? Text("Star") : key.digit == "#" ? Text("Pound") : Text(key.digit))
                    }
                }
            }
        }
    }
}

struct KeypadView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                TextField("Number, extension or SIP address", text: $model.dialText)
                    .textFieldStyle(.plain)
                    .font(.title2.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .focused($fieldFocused)
                    .onSubmit(dial)
                    .accessibilityLabel(Text("Dial target"))
                if !model.dialText.isEmpty {
                    Button {
                        model.dialText.removeLast()
                    } label: {
                        Image(systemName: "delete.left")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Delete last character"))
                    Button {
                        model.dialText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Clear"))
                }
            }
            .frame(maxWidth: 360)

            matches

            KeypadGrid { model.dialText.append($0) }

            HStack(spacing: 12) {
                if model.phone.accounts.filter(\.isEnabled).count > 1 {
                    Picker("Account", selection: selectedAccount) {
                        ForEach(model.phone.accounts.filter(\.isEnabled)) { account in
                            Text(account.displayName).tag(account.id as UUID?)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Button(action: dial) {
                    Label("Call", systemImage: "phone.fill")
                        .frame(minWidth: 96)
                }
                .buttonStyle(.glassProminent)
                .tint(.green)
                .controlSize(.large)
                .disabled(!DialTarget.isDialable(model.dialText) && lastDialled == nil)
                .help(model.dialText.isEmpty ? Text("Redial") : Text("Call"))
            }
            Spacer(minLength: 0)
        }
        .padding()
        .onChange(of: model.dialerFocusRequest) { fieldFocused = true }
        .onAppear { fieldFocused = true }
    }

    @ViewBuilder private var matches: some View {
        let query = model.dialText
        let found = query.count < 2 ? [] : Array(model.phone.contacts.filter { $0.matches(search: query) }.prefix(3))
        if !found.isEmpty {
            VStack(spacing: 2) {
                ForEach(found) { contact in
                    Button {
                        if let target = contact.primaryTarget { model.dialText = target }
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
            }
            .frame(maxWidth: 300)
        }
    }

    private var selectedAccount: Binding<UUID?> {
        Binding(get: { model.selectedAccount ?? AccountSelection.outgoing(from: model.phone.accounts, explicit: nil)?.id },
                set: { model.selectedAccount = $0 })
    }

    private var lastDialled: String? {
        model.phone.history.first { $0.direction == .outgoing }?.dialTarget
    }

    private func dial() {
        if DialTarget.isDialable(model.dialText) {
            model.call(model.dialText)
        } else if let lastDialled {
            model.dialText = lastDialled
        }
    }
}
