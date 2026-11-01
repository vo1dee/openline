// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
//
// Headless softphone for integration tests: the real engine, coordinator and
// database, without UI or sound hardware. Reads one command per line on stdin
// and answers with one JSON object per line on stdout.
import Foundation
import OpenlineCore
import OpenlineKit
import OpenlineSIP
import OpenlineStore

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: "--\(name)"), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

func reply(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

@MainActor func status(_ phone: PhoneCoordinator) -> [String: Any] {
    var result: [String: Any] = [:]
    result["accounts"] = phone.accounts.map { account in
        ["user": account.username, "state": String(describing: phone.registration[account.id] ?? .offline),
         "registered": phone.registration[account.id]?.isRegistered ?? false,
         "last": phone.lastRegistrationResponse[account.id] ?? ""] as [String: Any]
    }
    if let call = phone.activeCall {
        var info: [String: Any] = ["state": String(describing: call.state), "muted": call.isMuted,
                                   "direction": call.direction.rawValue, "remote": call.remote.label,
                                   "remoteHold": call.isRemoteHold, "transfer": String(describing: call.transfer),
                                   "contact": call.contactName ?? ""]
        if let media = call.media {
            info["media"] = ["codec": media.codec, "clockRate": media.clockRate, "tx": media.txPackets, "rx": media.rxPackets,
                             "rxLevel": media.rxLevel, "txLevel": media.txLevel, "lost": media.rxLost] as [String: Any]
        }
        result["call"] = info
    }
    result["dtmf"] = phone.receivedDTMF
    result["history"] = phone.history.map {
        ["target": $0.dialTarget, "identity": $0.displayIdentity, "direction": $0.direction.rawValue,
         "outcome": $0.outcome.rawValue, "duration": $0.connectedDuration, "status": $0.sipStatus ?? 0,
         "contact": $0.contactID?.uuidString ?? ""] as [String: Any]
    }
    if let error = phone.lastCallError { result["error"] = String(describing: error) }
    if let failure = phone.engineFailure { result["engineFailure"] = failure }
    return result
}

@MainActor func run() async {
    let directory = argument("dir") ?? NSTemporaryDirectory()
    let user = argument("user") ?? "1001"
    let log = argument("log").map { path -> (@Sendable (String) -> Void) in
        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = FileHandle(forWritingAtPath: path)!
        return { handle.write(Data(DiagnosticsSanitizer.sanitize($0).utf8)) }
    }
    let sip = PJSIPService(userAgent: "Openline-agent", logLevel: log == nil ? 0 : 5, log: log,
                           testAudio: .init(sourceWAV: argument("source") ?? "", recordWAV: "\(directory)/\(user)-received.wav",
                                             skipTLSVerification: CommandLine.arguments.contains("--skip-tls-verify")))
    let database = try! AppDatabase(path: "\(directory)/\(user).sqlite")
    let credentials = InMemoryCredentialStore()
    let phone = PhoneCoordinator(sip: sip, database: database, credentials: credentials,
                                 policy: ReconnectPolicy(base: Double(argument("retry-base") ?? "5") ?? 5, maximum: 60),
                                 endedCallLinger: 0.5)
    await phone.start()
    let (commands, feed) = AsyncStream.makeStream(of: String.self)
    Thread.detachNewThread {
        while let line = readLine() { feed.yield(line) }
        feed.finish()
    }
    reply(["ready": true])
    for await line in commands {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let command = parts.first else { continue }
        let rest = parts.count > 1 ? parts[1] : ""
        do {
            switch command {
            case "account":
                // account <user> <password> <server> <port> <transport> <srtp?> <dtmf?>
                let f = rest.split(separator: " ").map(String.init)
                let account = SIPAccount(label: f[0], server: f[2], username: f[0], port: Int(f[3]),
                                         transport: SIPTransport(rawValue: f[4]) ?? .udp,
                                         srtp: f.count > 5 ? SRTPMode(rawValue: f[5]) ?? .disabled : .disabled,
                                         dtmf: f.count > 6 ? DTMFMode(rawValue: f[6]) ?? .rfc4733 : .rfc4733)
                try await phone.saveAccount(account, password: f[1])
            case "disable": try await phone.setEnabled(false, account: phone.accounts.first { $0.username == rest }!.id)
            case "enable": try await phone.setEnabled(true, account: phone.accounts.first { $0.username == rest }!.id)
            case "remove": try await phone.removeAccount(phone.accounts.first { $0.username == rest }!.id)
            case "contact":
                let f = rest.split(separator: " ", maxSplits: 1).map(String.init)
                try phone.save(Contact(name: f[1], numbers: [ContactNumber(value: f[0])]))
            case "dnd": try phone.updateSettings { $0.doNotDisturb = rest == "on" }
            case "codecs": try phone.updateSettings { $0.codecOrder = rest.split(separator: " ").map(String.init) }
            case "dial": try await phone.dial(rest)
            case "answer": try await phone.answer()
            case "decline": try await phone.decline()
            case "hangup": try await phone.hangup()
            case "mute": try await phone.setMuted(rest == "on")
            case "hold": try await phone.setHold(rest == "on")
            case "dtmf": try await phone.sendDTMF(rest)
            case "transfer": try await phone.transfer(to: rest)
            case "network": phone.networkChanged()
            case "reconnect":
                for account in phone.accounts { await phone.reconnect(account: account.id) }
            case "quit":
                await phone.shutdown()
                reply(["bye": true])
                exit(0)
            default: break
            }
            await phone.refreshMediaInfo()
            reply(status(phone))
        } catch {
            var result = status(phone)
            result["commandError"] = String(describing: error)
            reply(result)
        }
    }
    await phone.shutdown()
}

await run()
