// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import OpenlineCore
import SwiftUI

/// The call interface is an AppKit panel rather than a SwiftUI scene, so it can
/// appear from any state, including with every other window closed.
@MainActor final class CallPanelController {
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(for call: SIPCall, model: AppModel) {
        let panel = self.panel ?? makePanel(model: model)
        self.panel = panel
        if call.state == .incoming {
            panel.center()
            panel.orderFrontRegardless()
        } else {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel(model: AppModel) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: CallView().environment(model))
        panel.setContentSize(NSSize(width: 340, height: 480))
        panel.center()
        return panel
    }
}
