// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import OpenlineCore
import SwiftUI

struct RecentsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = HistoryFilter.all
    @State private var search = ""
    @State private var confirmingClear = false
    @State private var searchPresented = false

    private var entries: [CallHistoryEntry] {
        model.phone.history.filter { entry in
            filter.matches(entry) && (search.isEmpty || displayName(entry).localizedCaseInsensitiveContains(search)
                                      || entry.dialTarget.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        Group {
            if model.phone.history.isEmpty {
                ContentUnavailableView("No Recent Calls", systemImage: "clock",
                                       description: Text("Calls you make and receive appear here."))
            } else if entries.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(entries) { entry in
                    row(entry)
                }
            }
        }
        .navigationTitle("Recents")
        .searchable(text: $search, isPresented: $searchPresented, placement: .toolbar)
        .onChange(of: model.searchFocusRequest) { searchPresented = true }
        .toolbar {
            ToolbarItem {
                Picker("Filter", selection: $filter) {
                    ForEach(HistoryFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            ToolbarItem {
                Button("Clear History", systemImage: "trash") { confirmingClear = true }
                    .disabled(model.phone.history.isEmpty)
            }
        }
        .confirmationDialog("Clear all call history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { try? model.phone.clearHistory() }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func displayName(_ entry: CallHistoryEntry) -> String {
        model.contact(entry.contactID)?.name ?? entry.displayIdentity
    }

    private func row(_ entry: CallHistoryEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(entry))
                .foregroundStyle(entry.outcome == .missed || entry.outcome == .failed ? .red : .secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName(entry))
                    .fontWeight(entry.outcome == .missed ? .semibold : .regular)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(entry.outcome.title)
                    if entry.answeredAt != nil {
                        Text(entry.connectedDuration.callDuration).monospacedDigit()
                    }
                    if model.phone.accounts.count > 1 {
                        Text(model.accountName(entry.accountID))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .onTapGesture(count: 2) { model.callTarget(for: entry) }
        .contextMenu {
            Button("Call Back") { model.callTarget(for: entry) }
            Button("Copy Number") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.dialTarget, forType: .string)
            }
            if entry.contactID == nil {
                Button("Add to Contacts") { model.addToContacts(entry) }
            }
            Divider()
            Button("Delete", role: .destructive) { try? model.phone.deleteHistoryEntry(entry.id) }
        }
    }

    private func symbol(_ entry: CallHistoryEntry) -> String {
        if entry.outcome == .missed { return "phone.arrow.down.left.fill" }
        return entry.direction == .incoming ? "phone.arrow.down.left" : "phone.arrow.up.right"
    }
}
