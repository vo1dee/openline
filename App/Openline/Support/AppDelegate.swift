// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
        // SwiftUI can remember that the window was closed last session.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
            if !hasWindow { AppModel.shared.openMainWindow() }
        }
    }

    /// Closing the window must not end the SIP registration.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { AppModel.shared.openMainWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard !model.isQuitting else { return .terminateLater }
        if model.phone.hasLiveCall {
            let alert = NSAlert()
            alert.messageText = String(localized: "End the current call and quit?")
            alert.informativeText = String(localized: "Your call will be disconnected. You won't receive calls until you open Openline again.")
            alert.addButton(withTitle: String(localized: "End Call and Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        model.isQuitting = true
        Task { @MainActor in
            // Unregistering is best effort: an unreachable server can't block quit.
            let shutdown = Task { await model.phone.shutdown() }
            let deadline = Task { try? await Task.sleep(for: .seconds(4)) }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await shutdown.value }
                group.addTask { await deadline.value }
                await group.next()
                group.cancelAll()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
