// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import OpenlineCore
import SwiftUI
import UniformTypeIdentifiers

struct ContactsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selection: UUID?
    @State private var editing: Contact?
    @State private var searchPresented = false
    @State private var importSummary: String?

    private var contacts: [Contact] { model.phone.contacts.filter { $0.matches(search: search) } }

    var body: some View {
        HSplitView {
            Group {
                if model.phone.contacts.isEmpty {
                    ContentUnavailableView {
                        Label("No Contacts", systemImage: "person.crop.circle")
                    } description: {
                        Text("Contacts are stored only on this Mac.")
                    } actions: {
                        Button("Add Contact") { editing = Contact(name: "") }
                    }
                } else if contacts.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    List(contacts, selection: $selection) { contact in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(contact.name).lineLimit(1)
                                if contact.isFavorite {
                                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                                        .accessibilityLabel(Text("Favorite"))
                                }
                            }
                            if let target = contact.primaryTarget {
                                Text(target).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(contact.id)
                        .contextMenu { menu(contact) }
                    }
                }
            }
            .frame(minWidth: 200, idealWidth: 240, maxHeight: .infinity)

            Group {
                if let contact = model.phone.contacts.first(where: { $0.id == selection }) {
                    ContactDetail(contact: contact, edit: { editing = contact })
                } else {
                    Text("Select a contact").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 260, maxHeight: .infinity)
        }
        .navigationTitle("Contacts")
        .searchable(text: $search, isPresented: $searchPresented, placement: .toolbar)
        .onChange(of: model.searchFocusRequest) { searchPresented = true }
        .toolbar {
            ToolbarItem {
                Button("Add Contact", systemImage: "plus") { editing = Contact(name: "") }
            }
            ToolbarItem {
                Menu("Import or Export", systemImage: "square.and.arrow.up.on.square") {
                    Button("Import CSV…", action: importCSV)
                    Button("Export CSV…", action: exportCSV).disabled(model.phone.contacts.isEmpty)
                }
            }
        }
        .sheet(item: $editing) { contact in
            ContactEditor(contact: contact).environment(model)
        }
        .onChange(of: model.contactDraftFromHistory) { _, draft in
            if let draft {
                editing = draft
                model.contactDraftFromHistory = nil
            }
        }
        .onAppear {
            if let draft = model.contactDraftFromHistory {
                editing = draft
                model.contactDraftFromHistory = nil
            }
        }
        .alert("Import Finished", isPresented: Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importSummary ?? "")
        }
    }

    @ViewBuilder private func menu(_ contact: Contact) -> some View {
        if let target = contact.primaryTarget {
            Button("Call") { model.call(target) }
        }
        Button(contact.isFavorite ? "Remove from Favorites" : "Add to Favorites") { toggleFavorite(contact) }
        Button("Edit") { editing = contact }
        Divider()
        Button("Delete", role: .destructive) { try? model.phone.deleteContact(contact.id) }
    }

    private func toggleFavorite(_ contact: Contact) {
        var updated = contact
        updated.isFavorite.toggle()
        try? model.phone.save(updated)
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try model.phone.importContacts(csv: String(contentsOf: url, encoding: .utf8))
            importSummary = String(localized: "\(result.new.count) added, \(result.skippedDuplicates.count) duplicates skipped, \(result.skippedInvalidRows.count) invalid rows skipped.")
        } catch {
            importSummary = error.localizedDescription
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Openline Contacts.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ContactCSV.export(model.phone.contacts).write(to: url, atomically: true, encoding: .utf8)
    }
}

struct ContactDetail: View {
    @Environment(AppModel.self) private var model
    let contact: Contact
    let edit: () -> Void

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text(contact.name).font(.title2.weight(.semibold))
                    if let company = contact.company { Text(company).foregroundStyle(.secondary) }
                }
            }
            Section {
                ForEach(contact.numbers) { number in target(Text(number.label.title), value: number.value) }
                if let ext = contact.internalExtension.nonEmpty { target(Text("Extension"), value: ext) }
                if let uri = contact.sipURI.nonEmpty { target(Text("SIP Address"), value: uri) }
            }
            if let notes = contact.notes.nonEmpty {
                Section("Notes") { Text(notes) }
            }
            Section {
                Button("Edit", action: edit)
            }
        }
        .formStyle(.grouped)
    }

    private func target(_ label: Text, value: String) -> some View {
        LabeledContent {
            HStack {
                Text(value).textSelection(.enabled)
                Button {
                    model.call(value)
                } label: {
                    Image(systemName: "phone.fill")
                }
                .accessibilityLabel(Text("Call \(value)"))
            }
        } label: {
            label
        }
    }
}

struct ContactEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var contact: Contact

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $contact.name)
                TextField("Company", text: optional(\.company))
                Section("Numbers") {
                    ForEach($contact.numbers) { $number in
                        HStack {
                            Picker("Label", selection: $number.label) {
                                ForEach(NumberLabel.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            TextField("Number", text: $number.value)
                                .labelsHidden()
                            Button {
                                contact.numbers.removeAll { $0.id == number.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Remove number"))
                        }
                    }
                    Button("Add Number") { contact.numbers.append(ContactNumber(value: "")) }
                }
                TextField("Internal Extension", text: optional(\.internalExtension))
                TextField("SIP Address", text: optional(\.sipURI))
                TextField("Notes", text: optional(\.notes), axis: .vertical)
                Toggle("Favorite", isOn: $contact.isFavorite)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    contact.numbers.removeAll { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }
                    try? model.phone.save(contact)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(contact.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 420, height: 500)
    }

    private func optional(_ path: WritableKeyPath<Contact, String?>) -> Binding<String> {
        Binding(get: { contact[keyPath: path] ?? "" }, set: { contact[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
}

struct FavoritesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let favorites = model.phone.contacts.filter(\.isFavorite)
        Group {
            if favorites.isEmpty {
                ContentUnavailableView("No Favorites", systemImage: "star",
                                       description: Text("Mark a contact as a favorite to call it from here."))
            } else {
                List(favorites) { contact in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(contact.name)
                            Text(contact.primaryTarget ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            if let target = contact.primaryTarget { model.call(target) }
                        } label: {
                            Image(systemName: "phone.fill")
                        }
                        .disabled(contact.primaryTarget == nil)
                        .accessibilityLabel(Text("Call \(contact.name)"))
                    }
                }
            }
        }
        .navigationTitle("Favorites")
    }
}
