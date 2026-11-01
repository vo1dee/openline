// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import OpenlineCore
import OpenlineKit
import SwiftUI

extension AccountRegistrationState {
    var title: LocalizedStringKey {
        switch self {
        case .disabled: "Disabled"
        case .offline: "Offline"
        case .registering: "Registering…"
        case .reconnecting: "Reconnecting…"
        case .registered: "Registered"
        case .failed(let failure): failure.title
        }
    }

    var color: Color {
        switch self {
        case .registered: .green
        case .registering, .reconnecting: .orange
        case .failed: .red
        case .disabled, .offline: .secondary
        }
    }
}

extension RegistrationFailure {
    var title: LocalizedStringKey {
        switch self {
        case .incorrectCredentials: "Incorrect credentials"
        case .credentialUnavailable: "Password unavailable in Keychain"
        case .forbidden: "Authentication failed"
        case .notFound: "Extension not found on server"
        case .timedOut: "Registration timed out"
        case .serverUnreachable: "Server unreachable"
        case .dnsFailure: "Server name not found"
        case .tlsCertificate: "TLS certificate error"
        case let .server(code, reason):
            code > 0 ? "Server error \(code): \(reason)" : "\(reason)"
        }
    }
}

extension CallState {
    var title: LocalizedStringKey {
        switch self {
        case .idle: "Idle"
        case .incoming: "Incoming call"
        case .outgoing: "Calling…"
        case .connecting: "Connecting…"
        case .remoteRinging: "Ringing…"
        case .established: "Connected"
        case .holding: "Putting on hold…"
        case .held: "On hold"
        case .resuming: "Resuming…"
        case .transferring: "Transferring…"
        case .ending: "Ending…"
        case .ended: "Call ended"
        case .failed: "Call failed"
        }
    }
}

extension CallOutcome {
    var title: LocalizedStringKey {
        switch self {
        case .answered: "Answered"
        case .missed: "Missed"
        case .declined: "Declined"
        case .busy: "Busy"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }
}

extension HistoryFilter {
    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .incoming: "Incoming"
        case .outgoing: "Outgoing"
        case .missed: "Missed"
        case .failed: "Failed"
        case .declined: "Declined"
        }
    }
}

extension NumberLabel {
    var title: LocalizedStringKey {
        switch self {
        case .work: "Work"
        case .mobile: "Mobile"
        case .home: "Home"
        case .other: "Other"
        }
    }
}

extension PhoneError {
    var title: LocalizedStringKey {
        switch self {
        case .noAccount: "Add and enable a SIP account to place calls."
        case .nothingToDial: "Enter a number, extension or SIP address."
        case .callInProgress: "Finish the current call first."
        case .accountInUse: "This account has a call in progress. Try again after it ends."
        case .microphoneDenied: "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."
        case .missingCredentials: "The password for this account is missing."
        case .engine(let message): "\(message)"
        }
    }
}

extension Ringtone {
    var title: LocalizedStringKey {
        switch self {
        case .classic: "Classic"
        case .chime: "Chime"
        case .pulse: "Pulse"
        }
    }
}

extension AppearancePreference {
    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

extension TimeInterval {
    /// Connected time such as 1:05 or 1:02:03.
    var callDuration: String {
        Duration.seconds(self).formatted(self >= 3600 ? .time(pattern: .hourMinuteSecond) : .time(pattern: .minuteSecond))
    }
}

/// Coloured dot paired with text, so state never relies on colour alone.
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}
