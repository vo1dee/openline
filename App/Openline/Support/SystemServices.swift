// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Network
import OpenlineCore
import OpenlineKit
import UserNotifications

struct SystemMicrophoneAccess: MicrophoneAccess {
    func ensureAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}

/// Keeps only the newest lines, sanitized as they arrive, in memory.
final class DiagnosticLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity = 4000

    func append(_ line: String) {
        let clean = DiagnosticsSanitizer.sanitize(line)
        lock.withLock {
            lines.append(clean)
            if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        }
    }

    var text: String { lock.withLock { lines.joined() } }
}

/// Reports real network path changes, not the repeats NWPathMonitor also sends.
@MainActor final class NetworkMonitor {
    var onChange: (() -> Void)?
    private let monitor = NWPathMonitor()
    private var signature: String?
    private var debounce: Task<Void, Never>?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let current = "\(path.status)|\(path.availableInterfaces.map(\.name).joined(separator: ","))|\(path.gateways)"
            Task { @MainActor in self?.update(current) }
        }
        monitor.start(queue: DispatchQueue(label: "org.openline.network"))
    }

    private func update(_ current: String) {
        defer { signature = current }
        guard let previous = signature, previous != current else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }
}

enum CoreAudioDevices {
    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : value
    }

    static func all() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func id(named name: String) -> AudioObjectID? {
        all().first { string($0, kAudioObjectPropertyName) == name }
    }

    static func uid(named name: String?) -> String? {
        name.flatMap(id(named:)).flatMap { string($0, kAudioDevicePropertyDeviceUID) }
    }
}

/// Watches the device list and system defaults, including unplugged devices.
@MainActor final class AudioHardwareMonitor {
    var onChange: (() -> Void)?
    private var debounce: Task<Void, Never>?

    func start() {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.changed() }
            }
        }
    }

    private func changed() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }
}

/// Ringtones are synthesized, so the repository ships no third-party audio.
enum RingtoneSynth {
    private struct Segment {
        let frequencies: [Double]
        let seconds: Double
    }

    private static func pattern(_ ringtone: Ringtone) -> [Segment] {
        switch ringtone {
        case .classic:
            [Segment(frequencies: [440, 480], seconds: 1.2), Segment(frequencies: [], seconds: 2.4)]
        case .chime:
            [Segment(frequencies: [659], seconds: 0.25), Segment(frequencies: [784], seconds: 0.25),
             Segment(frequencies: [988], seconds: 0.5), Segment(frequencies: [], seconds: 1.6)]
        case .pulse:
            [Segment(frequencies: [800], seconds: 0.15), Segment(frequencies: [], seconds: 0.1),
             Segment(frequencies: [800], seconds: 0.15), Segment(frequencies: [], seconds: 1.4)]
        }
    }

    static func wav(_ ringtone: Ringtone) -> Data {
        let rate = 44100.0
        var samples: [Int16] = []
        for segment in pattern(ringtone) {
            let count = Int(segment.seconds * rate)
            for index in 0..<count {
                guard !segment.frequencies.isEmpty else {
                    samples.append(0)
                    continue
                }
                let time = Double(index) / rate
                let envelope = min(1, min(Double(index), Double(count - index)) / (rate * 0.01))
                let tone = segment.frequencies.map { sin(2 * .pi * $0 * time) }.reduce(0, +) / Double(segment.frequencies.count)
                samples.append(Int16(tone * envelope * 0.7 * Double(Int16.max)))
            }
        }
        return wav(samples: samples, rate: UInt32(rate))
    }

    static func testTone() -> Data {
        let rate = 44100.0
        let samples = (0..<Int(rate)).map { index -> Int16 in
            let envelope = min(1, min(Double(index), rate - Double(index)) / (rate * 0.02))
            return Int16(sin(2 * .pi * 660 * Double(index) / rate) * envelope * 0.5 * Double(Int16.max))
        }
        return wav(samples: samples, rate: UInt32(rate))
    }

    private static func wav(samples: [Int16], rate: UInt32) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(rate)
        append(rate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(bytes)
        for sample in samples { append(sample) }
        return data
    }
}

@MainActor final class ToneRinger: Ringing {
    private var player: AVAudioPlayer?

    func startRinging(_ ringtone: Ringtone, volume: Double) {
        stopRinging()
        guard let created = try? AVAudioPlayer(data: RingtoneSynth.wav(ringtone)) else { return }
        created.numberOfLoops = -1
        created.volume = Float(volume)
        created.play()
        player = created
    }

    func stopRinging() {
        player?.stop()
        player = nil
    }
}

/// Settings-only audio checks, separate from call media.
@MainActor @Observable final class AudioTestBench {
    private(set) var inputLevel: Float = 0
    private(set) var isMeasuring = false
    private(set) var failure: String?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var player: AVAudioPlayer?

    func playTestTone(volume: Double, device: String?) {
        failure = nil
        player = try? AVAudioPlayer(data: RingtoneSynth.testTone())
        player?.volume = Float(volume)
        if let uid = CoreAudioDevices.uid(named: device) { player?.currentDevice = uid }
        player?.play()
    }

    func previewRingtone(_ ringtone: Ringtone, volume: Double, device: String?) {
        player = try? AVAudioPlayer(data: RingtoneSynth.wav(ringtone))
        player?.volume = Float(volume)
        if let uid = CoreAudioDevices.uid(named: device) { player?.currentDevice = uid }
        player?.play()
    }

    func startMeter(device: String?) async {
        guard !isMeasuring else { return }
        failure = nil
        guard await SystemMicrophoneAccess().ensureAccess() else {
            failure = String(localized: "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone.")
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let name = device, let id = CoreAudioDevices.id(named: name) {
            input.withAUAudioUnit { try? $0.setDeviceID(id) }
        }
        let format = input.outputFormat(forBus: 0)
        let sink = LevelSink { [weak self] level in
            Task { @MainActor in self?.inputLevel = level }
        }
        do {
            try input.installAudioTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in sink.handle(AVAudioPCMBuffer(copying: buffer)) }
            try engine.start()
            self.engine = engine
            isMeasuring = true
        } catch {
            input.removeTap(onBus: 0)
            failure = error.localizedDescription
        }
    }

    func stopMeter() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isMeasuring = false
        inputLevel = 0
    }
}

/// Converts tap buffers to a 0...1 level on the audio tap's own thread.
private struct LevelSink: Sendable {
    let report: @Sendable (Float) -> Void

    func handle(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<frames { sum += channel[index] * channel[index] }
        let rms = frames > 0 ? (sum / Float(frames)).squareRoot() : 0
        report(min(1, max(0, (20 * log10(max(rms, 0.00001)) + 60) / 60)))
    }
}

@MainActor protocol CallNotifierDelegate: AnyObject {
    func notificationAnswered()
    func notificationDeclined()
    func notificationOpened()
}

/// A convenience on top of the call panel, which always appears regardless of
/// notification permission.
@MainActor final class CallNotifier: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    weak var delegate: (any CallNotifierDelegate)?
    private let incomingID = "incoming-call"
    private let center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier == nil ? nil : .current()

    func requestAuthorization() {
        guard let center else { return }
        center.delegate = self
        let answer = UNNotificationAction(identifier: "answer", title: String(localized: "Answer"), options: [.foreground])
        let decline = UNNotificationAction(identifier: "decline", title: String(localized: "Decline"), options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: "incoming", actions: [answer, decline], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyIncoming(_ call: SIPCall, title: String, account: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(localized: "Incoming call on \(account)")
        content.categoryIdentifier = "incoming"
        center?.add(UNNotificationRequest(identifier: incomingID, content: content, trigger: nil))
    }

    func clearIncoming() {
        center?.removeDeliveredNotifications(withIdentifiers: [incomingID])
    }

    func notifyMissed(title: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Missed call")
        content.body = title
        center?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        switch response.actionIdentifier {
        case "answer": delegate?.notificationAnswered()
        case "decline": delegate?.notificationDeclined()
        default: delegate?.notificationOpened()
        }
    }
}

extension AppModel: CallNotifierDelegate {
    func notificationAnswered() {
        NSApp.activate()
        perform { try await self.phone.answer() }
    }

    func notificationDeclined() {
        perform { try await self.phone.decline() }
    }

    func notificationOpened() { openMainWindow() }
}
