// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import OpenlineCore
import SwiftUI

@main
struct OpenlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Openline", id: AppModel.mainWindowID) {
            RootView()
                .environment(model)
                .preferredColorScheme(model.phone.settings.appearance.colorScheme)
                .frame(minWidth: 640, minHeight: 460)
        }
        .defaultSize(width: 820, height: 560)
        // A window closed last session must not leave the next launch windowless.
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .commands { OpenlineCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(model.phone.settings.appearance.colorScheme)
        }

        MenuBarExtra(isInserted: model.menuBarIconVisible) {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
    }
}

struct OpenlineCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Call") { model.focusDialer() }
                .keyboardShortcut("n")
        }
        CommandGroup(after: .sidebar) {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { model.show(section) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
        CommandGroup(after: .textEditing) {
            Button("Search") { model.focusSearch() }
                .keyboardShortcut("f")
        }
    }
}

/// Lives as long as the app, so its environment can reopen a closed main window
/// from the menu bar and the Dock.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.menuBarSymbol)
            .accessibilityLabel(Text("Openline"))
            .task { model.reopenMainWindow = { openWindow(id: AppModel.mainWindowID) } }
    }
}

extension AppearancePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
