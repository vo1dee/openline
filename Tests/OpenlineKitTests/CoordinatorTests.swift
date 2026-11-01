import XCTest
import OpenlineCore
import OpenlineStore
@testable import OpenlineKit

/// Test double; production builds only ever receive PJSIPService.
final class FakeSIP: SIPService, @unchecked Sendable {
    let events: AsyncStream<SIPEvent>
    private let feed: AsyncStream<SIPEvent>.Continuation
    private let lock = NSLock()
    private var log: [String] = []
    var failNextCall = false
    var failHold = false

    init() {
        (events, feed) = AsyncStream.makeStream(of: SIPEvent.self)
    }

    func emit(_ event: SIPEvent) { feed.yield(event) }
    func note(_ entry: String) { lock.withLock { log.append(entry) } }
    var calls: [String] { lock.withLock { log } }

    func start() async throws { note("start") }
    func shutdown() async { note("shutdown") }
    func addAccount(_ account: SIPAccount, credentials: SIPAccountCredentials, register: Bool) async throws { note("add \(account.username) \(credentials.password)") }
    func removeAccount(_ id: UUID) async throws { note("remove") }
    func setRegistered(_ registered: Bool, account: UUID) async throws { note("register \(registered)") }
    func makeCall(uri: String, account: UUID) async throws -> String {
        if failNextCall { throw CocoaError(.featureUnsupported) }
        note("call \(uri)")
        emit(.callPhase(handle: "h1", phase: .calling, code: 0, reason: "", sipCallID: "sip-1"))
        return "h1"
    }
    func sendRinging(handle: String) async throws { note("ringing") }
    func answer(handle: String) async throws { note("answer") }
    func hangup(handle: String, statusCode: Int) async throws { note("hangup \(statusCode)") }
    func setHold(_ hold: Bool, handle: String) async throws {
        if failHold { throw CocoaError(.featureUnsupported) }
        note("hold \(hold)")
    }
    func setMuted(_ muted: Bool, handle: String) async throws { note("mute \(muted)") }
    func sendDTMF(_ digits: String, mode: DTMFMode, handle: String) async throws { note("dtmf \(digits)") }
    func transfer(handle: String, to uri: String) async throws { note("transfer \(uri)") }
    func mediaInfo(handle: String) async -> NegotiatedMedia? { nil }
    func audioDevices() async -> [AudioDevice] { [] }
    func selectAudioDevices(input: String?, output: String?) async throws {}
    func audioHardwareChanged() {}
    func setCodecOrder(_ codecs: [String]) async throws {}
    func availableCodecs() async -> [String] { ApplicationSettings.defaultCodecs }
    func setSTUNServers(_ servers: [String]) {}
    func handleNetworkChange() { note("network") }
}

@MainActor final class CoordinatorTests: XCTestCase {
    private var sip: FakeSIP!
    private var database: AppDatabase!
    private var phone: PhoneCoordinator!
    private var account: SIPAccount!

    override func setUp() async throws {
        sip = FakeSIP()
        database = try AppDatabase()
        phone = PhoneCoordinator(sip: sip, database: database, credentials: InMemoryCredentialStore(),
                                 sleep: { _ in try? await Task.sleep(for: .milliseconds(5)) }, random: { 0.5 }, endedCallLinger: 0)
        await phone.start()
        account = SIPAccount(server: "pbx", username: "101")
        try await phone.saveAccount(account, password: "secret")
    }

    private func settled(_ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func incoming(_ handle: String = "in1", from: String = "<sip:555@pbx>") {
        sip.emit(.incomingCall(handle: handle, account: account.id, remoteURI: from, sipCallID: "x"))
    }

    private func establishOutgoing() async throws {
        try await phone.dial("102")
        sip.emit(.callPhase(handle: "h1", phase: .confirmed, code: 200, reason: "OK", sipCallID: nil))
        sip.emit(.callMedia(handle: "h1", phase: .active))
        await settled(phone.activeCall?.state == .established)
    }

    func testFirstAccountBecomesDefaultAndPasswordGoesToEngineNotDatabase() async throws {
        XCTAssertTrue(phone.accounts[0].isDefault)
        XCTAssertTrue(sip.calls.contains("add 101 secret"))
        let json = try JSONEncoder().encode(database.accounts())
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("secret"))
    }

    func testOnlyOneDefaultAccount() async throws {
        var second = SIPAccount(server: "b", username: "2")
        second.isDefault = true
        try await phone.saveAccount(second, password: "p")
        XCTAssertEqual(phone.accounts.filter(\.isDefault).map(\.id), [second.id])
    }

    func testRegisteredOnlyAfterEngineConfirms() async throws {
        XCTAssertFalse(phone.registration[account.id]?.isRegistered ?? true)
        sip.emit(.registrationChanged(account: account.id, code: 200, reason: "OK", expiration: 300, network: .none))
        await settled(phone.registration[account.id]?.isRegistered == true)
    }

    func testAccountFailuresAreIndependent() async throws {
        let other = SIPAccount(server: "b", username: "2")
        try await phone.saveAccount(other, password: "p")
        sip.emit(.registrationChanged(account: other.id, code: 200, reason: "OK", expiration: 300, network: .none))
        sip.emit(.registrationChanged(account: account.id, code: 401, reason: "Unauthorized", expiration: 0, network: .none))
        await settled(phone.registration[account.id] == .failed(.incorrectCredentials))
        XCTAssertTrue(phone.registration[other.id]?.isRegistered == true)
    }

    func testRetryableFailureReconnects() async throws {
        sip.emit(.registrationChanged(account: account.id, code: 503, reason: "x", expiration: 0, network: .none))
        await settled(sip.calls.contains("register true"))
    }

    func testBadCredentialsNeverRetry() async throws {
        sip.emit(.registrationChanged(account: account.id, code: 401, reason: "x", expiration: 0, network: .none))
        await settled(phone.registration[account.id] == .failed(.incorrectCredentials))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(sip.calls.contains("register true"))
    }

    func testNetworkChangeLeavesHealthyAccountsAlone() async throws {
        sip.emit(.registrationChanged(account: account.id, code: 200, reason: "OK", expiration: 300, network: .none))
        await settled(phone.registration[account.id]?.isRegistered == true)
        phone.networkChanged()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(sip.calls.contains("network"))
        XCTAssertFalse(sip.calls.contains("register true"))
    }

    func testDialNormalState() async throws {
        let call = try await phone.dial("102")
        XCTAssertTrue(sip.calls.contains("call sip:102@pbx"))
        XCTAssertFalse(call.state.isConnected)
    }

    func testEstablishedOnlyAfterConfirmation() async throws {
        try await phone.dial("102")
        await settled(phone.activeCall?.state == .connecting)
        XCTAssertNil(phone.activeCall?.answeredAt)
        sip.emit(.callPhase(handle: "h1", phase: .confirmed, code: 200, reason: "OK", sipCallID: nil))
        await settled(phone.activeCall?.state == .established)
        XCTAssertNotNil(phone.activeCall?.answeredAt)
    }

    func testSecondOutgoingCallRejected() async throws {
        try await phone.dial("102")
        do {
            try await phone.dial("103")
            XCTFail("Expected rejection")
        } catch {
            XCTAssertEqual(error as? PhoneError, .callInProgress)
        }
    }

    func testIncomingDuringCallGetsBusyAndDoesNotReplaceIt() async throws {
        try await establishOutgoing()
        let live = phone.activeCall?.id
        incoming("in2")
        await settled(sip.calls.contains("hangup 486"))
        XCTAssertEqual(phone.activeCall?.id, live)
        XCTAssertEqual(phone.activeCall?.state, .established)
        sip.emit(.callPhase(handle: "in2", phase: .disconnected, code: 486, reason: "Busy", sipCallID: nil))
        await settled(phone.history.count == 1)
        XCTAssertEqual(phone.history[0].outcome, .missed)
        XCTAssertEqual(phone.activeCall?.id, live)
    }

    func testDoNotDisturbRejects() async throws {
        try phone.updateSettings { $0.doNotDisturb = true }
        incoming()
        await settled(sip.calls.contains("hangup 486"))
        XCTAssertNil(phone.activeCall)
    }

    func testIncomingMatchesContact() async throws {
        try phone.save(Contact(name: "Alice", internalExtension: "555"))
        incoming()
        await settled(phone.activeCall?.contactName == "Alice")
        XCTAssertTrue(sip.calls.contains("ringing"))
    }

    func testDeclineIsRecorded() async throws {
        incoming()
        await settled(phone.activeCall?.state == .incoming)
        try await phone.decline()
        XCTAssertTrue(sip.calls.contains("hangup 603"))
        sip.emit(.callPhase(handle: "in1", phase: .disconnected, code: 603, reason: "Decline", sipCallID: nil))
        await settled(phone.history.first?.outcome == .declined)
    }

    func testCancelledIncomingIsMissed() async throws {
        incoming()
        await settled(phone.activeCall?.state == .incoming)
        sip.emit(.callPhase(handle: "in1", phase: .disconnected, code: 487, reason: "Terminated", sipCallID: nil))
        await settled(phone.history.first?.outcome == .missed)
    }

    func testRepeatedDisconnectWritesOneRecord() async throws {
        try await establishOutgoing()
        for _ in 0..<3 { sip.emit(.callPhase(handle: "h1", phase: .disconnected, code: 200, reason: "", sipCallID: nil)) }
        await settled(phone.history.count == 1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(try database.history().count, 1)
    }

    func testLateEventsAfterEndAreIgnored() async throws {
        try await establishOutgoing()
        sip.emit(.callPhase(handle: "h1", phase: .disconnected, code: 200, reason: "", sipCallID: nil))
        await settled(phone.activeCall == nil)
        sip.emit(.callMedia(handle: "h1", phase: .active))
        sip.emit(.reinviteFailed(handle: "h1", code: 500, reason: "x"))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(phone.activeCall)
    }

    func testMuteIsPublishedAfterEngineSuccess() async throws {
        try await establishOutgoing()
        try await phone.setMuted(true)
        XCTAssertEqual(phone.activeCall?.isMuted, true)
        XCTAssertEqual(phone.activeCall?.state, .established)
    }

    func testHoldConfirmedByMediaNotByRequest() async throws {
        try await establishOutgoing()
        try await phone.setHold(true)
        XCTAssertEqual(phone.activeCall?.state, .holding)
        sip.emit(.callMedia(handle: "h1", phase: .localHold))
        await settled(phone.activeCall?.state == .held)
        try await phone.setHold(false)
        XCTAssertEqual(phone.activeCall?.state, .resuming)
        sip.emit(.callMedia(handle: "h1", phase: .active))
        await settled(phone.activeCall?.state == .established)
    }

    func testRejectedHoldRestoresState() async throws {
        try await establishOutgoing()
        try await phone.setHold(true)
        sip.emit(.reinviteFailed(handle: "h1", code: 488, reason: "Not acceptable"))
        await settled(phone.activeCall?.state == .established)
    }

    func testEngineHoldErrorRestoresState() async throws {
        try await establishOutgoing()
        sip.failHold = true
        do { try await phone.setHold(true) } catch {}
        XCTAssertEqual(phone.activeCall?.state, .established)
    }

    func testTransferWaitsForFinalNotifyBeforeEndingLeg() async throws {
        try await establishOutgoing()
        try await phone.transfer(to: "103")
        XCTAssertEqual(phone.activeCall?.state, .transferring)
        XCTAssertFalse(sip.calls.contains { $0.hasPrefix("hangup") })
        sip.emit(.transferStatus(handle: "h1", code: 100, reason: "Trying", final: false))
        sip.emit(.transferStatus(handle: "h1", code: 200, reason: "OK", final: true))
        await settled(sip.calls.contains("hangup 0"))
    }

    func testFailedTransferKeepsCall() async throws {
        try await establishOutgoing()
        try await phone.transfer(to: "666")
        sip.emit(.transferStatus(handle: "h1", code: 404, reason: "Not Found", final: true))
        await settled(phone.activeCall?.state == .established)
        XCTAssertEqual(phone.activeCall?.transfer, .failed(code: 404, reason: "Not Found"))
    }

    func testDTMFDoesNotTouchDialTarget() async throws {
        try await establishOutgoing()
        try await phone.sendDTMF("12x#")
        XCTAssertTrue(sip.calls.contains("dtmf 12#"))
        XCTAssertEqual(phone.activeCall?.dialTarget, "102")
    }

    func testAccountChangeRejectedDuringCall() async throws {
        try await establishOutgoing()
        do {
            try await phone.removeAccount(account.id)
            XCTFail("Expected rejection")
        } catch {
            XCTAssertEqual(error as? PhoneError, .accountInUse)
        }
    }

    func testRemovingAccountDeletesCredentialsButKeepsHistory() async throws {
        try await establishOutgoing()
        sip.emit(.callPhase(handle: "h1", phase: .disconnected, code: 200, reason: "", sipCallID: nil))
        await settled(phone.activeCall == nil)
        try await phone.removeAccount(account.id)
        XCTAssertTrue(phone.accounts.isEmpty)
        XCTAssertEqual(phone.history.count, 1)
    }

    func testEngineFailureOnDialIsRecorded() async throws {
        sip.failNextCall = true
        do { try await phone.dial("102") } catch {}
        await settled(phone.history.first?.outcome == .failed)
        XCTAssertNil(phone.activeCall.flatMap { $0.state.isLive ? $0 : nil })
    }

    func testShutdownRecordsLiveCall() async throws {
        try await establishOutgoing()
        await phone.shutdown()
        XCTAssertEqual(phone.history.first?.outcome, .answered)
        XCTAssertTrue(sip.calls.contains("shutdown"))
    }

    func testImportNeverDeletes() throws {
        try phone.save(Contact(name: "Keep", internalExtension: "1"))
        _ = try phone.importContacts(csv: "name,extension\nNew,2\n")
        XCTAssertEqual(Set(phone.contacts.map(\.name)), ["Keep", "New"])
    }

    func testDiagnosticsContainNoCredentials() async throws {
        XCTAssertFalse(phone.diagnosticsReport.contains("secret"))
    }
}
