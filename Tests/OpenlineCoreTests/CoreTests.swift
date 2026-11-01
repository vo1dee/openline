import XCTest
@testable import OpenlineCore

final class AccountTests: XCTestCase {
    func testMinimalAccountUsesServerForEverything() {
        let account = SIPAccount(server: "pbx.example.com", username: "101")
        XCTAssertEqual(account.addressOfRecord, "sip:101@pbx.example.com")
        XCTAssertEqual(account.registrarURI, "sip:pbx.example.com")
        XCTAssertEqual(account.effectiveAuthUsername, "101")
        XCTAssertNil(account.routeURI, "No port, transport or host difference: DNS SRV decides")
    }

    func testIndependentDomainRegistrarAuthAndProxy() {
        let account = SIPAccount(server: "edge.example.net", username: "101", authUsername: "auth-101",
                                 domain: "example.com", registrar: "reg.example.net", port: 5070,
                                 transport: .tcp, outboundProxy: "proxy.example.org:5080")
        XCTAssertEqual(account.addressOfRecord, "sip:101@example.com")
        XCTAssertEqual(account.registrarURI, "sip:reg.example.net:5070;transport=tcp")
        XCTAssertEqual(account.effectiveAuthUsername, "auth-101")
        XCTAssertEqual(account.routeURI, "sip:proxy.example.org:5080;lr;transport=tcp")
    }

    func testRegistrarDifferentFromDomainRoutesRequestsThroughIt() {
        let account = SIPAccount(server: "10.0.0.5", username: "101", domain: "pbx.local", port: 5080)
        XCTAssertEqual(account.routeURI, "sip:10.0.0.5:5080;lr")
        XCTAssertEqual(account.addressOfRecord, "sip:101@pbx.local")
    }

    func testIPv6Host() {
        let account = SIPAccount(server: "2001:db8::1", username: "101", port: 5060)
        XCTAssertEqual(account.registrarURI, "sip:[2001:db8::1]:5060")
    }

    func testValidation() {
        XCTAssertEqual(AccountValidator.validate(SIPAccount(server: "pbx.example.com", username: "101"), password: "x"), [])
        let empty = AccountValidator.validate(SIPAccount(), password: "")
        XCTAssertTrue(empty.contains(.init(field: .server, problem: .required)))
        XCTAssertTrue(empty.contains(.init(field: .username, problem: .required)))
        XCTAssertTrue(empty.contains(.init(field: .password, problem: .required)))
        XCTAssertTrue(AccountValidator.validate(SIPAccount(server: "bad host", username: "a b", port: 70000), password: nil).count >= 3)
        XCTAssertEqual(AccountValidator.validate(SIPAccount(server: "pbx", username: "1", registrationInterval: 5), password: nil),
                       [.init(field: .registrationInterval, problem: .intervalOutOfRange)])
        XCTAssertEqual(AccountValidator.validate(SIPAccount(server: "pbx", username: "1", outboundProxy: "sip:proxy:5060;lr"), password: nil), [])
    }

    func testNilPasswordMeansKeepExisting() {
        XCTAssertEqual(AccountValidator.validate(SIPAccount(server: "pbx", username: "1"), password: nil), [])
    }

    func testCredentialReferenceDerivesFromStableID() {
        let account = SIPAccount(server: "a", username: "b")
        XCTAssertTrue(account.credentialReference.contains(account.id.uuidString))
    }

    func testAccountNeverEncodesAPassword() throws {
        let json = String(decoding: try JSONEncoder().encode(SIPAccount(server: "a", username: "b")), as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("password"))
    }

    func testOutgoingSelection() {
        let a = SIPAccount(server: "a", username: "1")
        let b = SIPAccount(server: "b", username: "2", isDefault: true)
        let off = SIPAccount(server: "c", username: "3", isEnabled: false)
        XCTAssertEqual(AccountSelection.outgoing(from: [a, b, off], explicit: nil)?.id, b.id)
        XCTAssertEqual(AccountSelection.outgoing(from: [a, b, off], explicit: a.id)?.id, a.id)
        XCTAssertEqual(AccountSelection.outgoing(from: [a, b, off], explicit: off.id)?.id, b.id, "A disabled choice falls back")
        XCTAssertNil(AccountSelection.outgoing(from: [off], explicit: nil))
    }
}

final class RegistrationTests: XCTestCase {
    func testClassification() {
        let classify = { RegistrationFailure.classify(code: $0, reason: "r", network: .none) }
        XCTAssertEqual(classify(401), .incorrectCredentials)
        XCTAssertEqual(classify(407), .incorrectCredentials)
        XCTAssertEqual(classify(403), .forbidden)
        XCTAssertEqual(classify(404), .notFound)
        XCTAssertEqual(classify(408), .timedOut)
        XCTAssertEqual(classify(503), .serverUnreachable)
        XCTAssertEqual(classify(500), .server(code: 500, reason: "r"))
        XCTAssertEqual(RegistrationFailure.classify(code: 503, reason: "", network: .tls), .tlsCertificate)
        XCTAssertEqual(RegistrationFailure.classify(code: 502, reason: "", network: .dns), .dnsFailure)
    }

    func testBadCredentialsAreNeverRetried() {
        XCTAssertFalse(RegistrationFailure.incorrectCredentials.isRetryable)
        XCTAssertFalse(RegistrationFailure.forbidden.isRetryable)
        XCTAssertFalse(RegistrationFailure.tlsCertificate.isRetryable)
        XCTAssertTrue(RegistrationFailure.timedOut.isRetryable)
        XCTAssertTrue(RegistrationFailure.dnsFailure.isRetryable)
    }

    func testBackoffIsExponentialAndBounded() {
        let policy = ReconnectPolicy(base: 5, maximum: 300, jitter: 0)
        XCTAssertEqual((1...8).map { policy.delay(attempt: $0, random: 0.5) }, [5, 10, 20, 40, 80, 160, 300, 300])
        XCTAssertEqual(policy.delay(attempt: 1000, random: 0.5), 300)
    }

    func testJitterStaysInBounds() {
        let policy = ReconnectPolicy(base: 10, maximum: 300, jitter: 0.2)
        XCTAssertEqual(policy.delay(attempt: 1, random: 0), 8, accuracy: 0.001)
        XCTAssertEqual(policy.delay(attempt: 1, random: 1), 12, accuracy: 0.001)
        XCTAssertLessThanOrEqual(policy.delay(attempt: 20, random: 1), 300)
    }
}

final class CallStateMachineTests: XCTestCase {
    private func call(_ direction: CallDirection = .outgoing) -> SIPCall {
        SIPCall(accountID: UUID(), remote: CallerIdentity(parsing: "sip:1@x"), dialTarget: "1", direction: direction)
    }

    func testOutgoingHappyPath() {
        var c = call()
        XCTAssertTrue(c.apply(.placed))
        XCTAssertEqual(c.state, .outgoing)
        XCTAssertTrue(c.apply(.trying))
        XCTAssertEqual(c.state, .connecting)
        XCTAssertTrue(c.apply(.remoteRinging))
        XCTAssertEqual(c.state, .remoteRinging)
        XCTAssertTrue(c.apply(.connecting))
        XCTAssertTrue(c.apply(.confirmed))
        XCTAssertEqual(c.state, .established)
        XCTAssertTrue(c.apply(.hangupRequested))
        XCTAssertTrue(c.apply(.disconnected(answered: true)))
        XCTAssertEqual(c.state, .ended)
    }

    func testPlacingACallIsNotEstablished() {
        var c = call()
        c.apply(.placed)
        XCTAssertFalse(c.state.isConnected)
    }

    func testHoldCycleWaitsForConfirmation() {
        var c = call()
        c.apply(.placed)
        c.apply(.confirmed)
        c.apply(.holdRequested)
        XCTAssertEqual(c.state, .holding)
        XCTAssertFalse(c.apply(.holdRequested))
        c.apply(.holdConfirmed)
        XCTAssertEqual(c.state, .held)
        c.apply(.resumeRequested)
        XCTAssertEqual(c.state, .resuming)
        c.apply(.resumeConfirmed)
        XCTAssertEqual(c.state, .established)
    }

    func testRejectedHoldReturnsToPriorState() {
        var c = call()
        c.apply(.placed)
        c.apply(.confirmed)
        c.apply(.holdRequested)
        c.apply(.holdRejected)
        XCTAssertEqual(c.state, .established)
        c.apply(.holdRequested)
        c.apply(.holdConfirmed)
        c.apply(.resumeRequested)
        c.apply(.resumeRejected)
        XCTAssertEqual(c.state, .held)
    }

    func testTransferFailureRestoresCall() {
        var c = call()
        c.apply(.placed)
        c.apply(.confirmed)
        XCTAssertTrue(c.apply(.transferRequested))
        XCTAssertEqual(c.state, .transferring)
        XCTAssertTrue(c.apply(.transferFailed))
        XCTAssertEqual(c.state, .established)
    }

    func testTransferNotPossibleBeforeConnection() {
        var c = call()
        c.apply(.placed)
        XCTAssertFalse(c.apply(.transferRequested))
    }

    func testUnansweredDisconnectFails() {
        var c = call()
        c.apply(.placed)
        c.apply(.disconnected(answered: false))
        XCTAssertEqual(c.state, .failed)
    }

    func testTerminalStatesIgnoreEverything() {
        var c = call()
        c.apply(.placed)
        c.apply(.disconnected(answered: false))
        for event: CallEvent in [.confirmed, .disconnected(answered: true), .hangupRequested, .holdRequested] {
            XCTAssertFalse(c.apply(event))
        }
        XCTAssertEqual(c.state, .failed)
    }

    func testRepeatedDisconnectIsIgnored() {
        var c = call()
        c.apply(.placed)
        c.apply(.confirmed)
        XCTAssertTrue(c.apply(.disconnected(answered: true)))
        XCTAssertFalse(c.apply(.disconnected(answered: true)))
    }

    func testOutcomeClassification() {
        func classify(_ d: CallDirection, answered: Bool = false, local: Bool = false, policy: Bool = false, code: Int = 0) -> CallOutcome {
            CallOutcome.classify(direction: d, answered: answered, endedLocally: local, rejectedByPolicy: policy, statusCode: code)
        }
        XCTAssertEqual(classify(.incoming, answered: true), .answered)
        XCTAssertEqual(classify(.incoming, code: 487), .missed)
        XCTAssertEqual(classify(.incoming, local: true), .declined)
        XCTAssertEqual(classify(.incoming, policy: true, code: 486), .missed)
        XCTAssertEqual(classify(.outgoing, local: true, code: 487), .cancelled)
        XCTAssertEqual(classify(.outgoing, code: 486), .busy)
        XCTAssertEqual(classify(.outgoing, code: 603), .declined)
        XCTAssertEqual(classify(.outgoing, code: 404), .failed)
    }

    func testSingleCallPolicy() {
        XCTAssertEqual(IncomingCallDecision.decide(hasLiveCall: false, doNotDisturb: false), .present)
        XCTAssertEqual(IncomingCallDecision.decide(hasLiveCall: true, doNotDisturb: false), .rejectBusy)
        XCTAssertEqual(IncomingCallDecision.decide(hasLiveCall: false, doNotDisturb: true), .rejectDoNotDisturb)
        XCTAssertEqual(IncomingCallDecision.busyHere, 486)
    }

    func testHistoryFilter() {
        let entry = CallHistoryEntry(id: UUID(), dialTarget: "1", displayIdentity: "1", accountID: UUID(), direction: .incoming,
                                     outcome: .missed, startedAt: Date(), answeredAt: nil, endedAt: Date(), contactID: nil,
                                     sipStatus: nil, failureDetail: nil)
        XCTAssertTrue(HistoryFilter.missed.matches(entry))
        XCTAssertTrue(HistoryFilter.incoming.matches(entry))
        XCTAssertFalse(HistoryFilter.outgoing.matches(entry))
        XCTAssertEqual(entry.connectedDuration, 0)
    }
}

final class DialingTests: XCTestCase {
    private let account = SIPAccount(server: "edge.example.net", username: "101", domain: "pbx.example.com")

    private func uri(_ input: String) -> String? { DialTarget.requestURI(for: input, account: account) }

    func testExtension() { XCTAssertEqual(uri("101"), "sip:101@pbx.example.com") }
    func testInternationalKeepsPlus() { XCTAssertEqual(uri("+380 50 123-45-67"), "sip:+380501234567@pbx.example.com") }
    func testSIPURIUnchanged() { XCTAssertEqual(uri("sip:101@other.example.com"), "sip:101@other.example.com") }
    func testBareAddressOfRecord() { XCTAssertEqual(uri("alice@example.com"), "sip:alice@example.com") }
    func testFeatureCodeStar() { XCTAssertEqual(uri("*72"), "sip:*72@pbx.example.com") }
    func testHashIsEscapedOnTheWire() { XCTAssertEqual(uri("*21#"), "sip:*21%23@pbx.example.com") }
    func testLeadingZeroNotNormalized() { XCTAssertEqual(uri("0501234567"), "sip:0501234567@pbx.example.com") }
    func testEmpty() { XCTAssertNil(uri("  - ")) }
    func testPunctuationOnlyRemovedForDisplay() { XCTAssertEqual(DialTarget.sanitized(" (050) 123 "), "050123") }

    func testCallerParsing() {
        let caller = CallerIdentity(parsing: "\"Alice B\" <sip:101@pbx.example.com;transport=udp>;tag=abc")
        XCTAssertEqual(caller.displayName, "Alice B")
        XCTAssertEqual(caller.user, "101")
        XCTAssertEqual(caller.host, "pbx.example.com")
        XCTAssertEqual(caller.label, "Alice B")
    }

    func testCallerWithoutName() {
        let caller = CallerIdentity(parsing: "<sip:+380501234567@1.2.3.4>")
        XCTAssertNil(caller.displayName)
        XCTAssertEqual(caller.label, "+380501234567")
    }

    func testEscapedCallerIsDecoded() {
        XCTAssertEqual(CallerIdentity(parsing: "sip:*21%23@x").user, "*21#")
    }
}

final class MatchingTests: XCTestCase {
    func testExactAndPunctuation() {
        XCTAssertTrue(NumberMatcher.matches("+380 (50) 123-45-67", "+380501234567"))
        XCTAssertTrue(NumberMatcher.matches("sip:101@pbx", "101"))
    }

    func testInternationalPrefixForms() {
        XCTAssertTrue(NumberMatcher.matches("00380501234567", "+380501234567"))
    }

    func testNationalTrunkForm() {
        XCTAssertTrue(NumberMatcher.matches("0501234567", "+380501234567"))
    }

    func testShortSuffixNeverMatches() {
        XCTAssertFalse(NumberMatcher.matches("101", "+380501234101"))
        XCTAssertFalse(NumberMatcher.matches("4567", "+380501234567"))
        XCTAssertFalse(NumberMatcher.matches("0101", "+380101"))
    }

    func testDifferentSubscribers() {
        XCTAssertFalse(NumberMatcher.matches("+380501234567", "+380501234568"))
    }

    func testSameDigitsDifferentCountryNeedAnExactKey() {
        XCTAssertFalse(NumberMatcher.matches("+380501234567", "+1501234567"))
    }

    func testEmptyNeverMatches() {
        XCTAssertFalse(NumberMatcher.matches("", ""))
    }

    func testContactMatch() {
        let alice = Contact(name: "Alice", numbers: [ContactNumber(value: "+380 50 123 45 67")], internalExtension: "101")
        let bob = Contact(name: "Bob", sipURI: "sip:bob@example.com")
        XCTAssertEqual(ContactMatcher.match(CallerIdentity(parsing: "sip:101@pbx"), in: [alice, bob])?.name, "Alice")
        XCTAssertEqual(ContactMatcher.match(CallerIdentity(parsing: "sip:0501234567@pbx"), in: [alice, bob])?.name, "Alice")
        XCTAssertEqual(ContactMatcher.match(CallerIdentity(parsing: "sip:bob@example.com"), in: [alice, bob])?.name, "Bob")
        XCTAssertNil(ContactMatcher.match(CallerIdentity(parsing: "sip:999@pbx"), in: [alice, bob]))
    }

    func testAmbiguousMatchReturnsNothing() {
        let a = Contact(name: "A", internalExtension: "101")
        let b = Contact(name: "B", internalExtension: "101")
        XCTAssertNil(ContactMatcher.match(CallerIdentity(parsing: "sip:101@pbx"), in: [a, b]))
    }

    func testSearch() {
        let alice = Contact(name: "Alice Smith", company: "Acme", numbers: [ContactNumber(value: "+380 50 123 45 67")],
                            internalExtension: "101", sipURI: "sip:alice@example.com")
        for query in ["ali", "ACME", "123 45", "1234567", "101", "alice@ex"] {
            XCTAssertTrue(alice.matches(search: query), query)
        }
        XCTAssertFalse(alice.matches(search: "zzz"))
    }
}

final class CSVTests: XCTestCase {
    func testRoundTrip() {
        let contact = Contact(name: "Smith, \"Al\"", company: "Acme", numbers: [ContactNumber(label: .work, value: "+1"), ContactNumber(label: .mobile, value: "+2")],
                              internalExtension: "101", sipURI: "sip:a@b", notes: "line1\nline2", isFavorite: true)
        let result = ContactCSV.importContacts(ContactCSV.export([contact]), existing: [])
        XCTAssertEqual(result.new.count, 1)
        let imported = result.new[0]
        XCTAssertEqual(imported.name, contact.name)
        XCTAssertEqual(imported.notes, contact.notes)
        XCTAssertEqual(imported.numbers.map(\.value), ["+1", "+2"])
        XCTAssertTrue(imported.isFavorite)
    }

    func testDuplicatesSkippedAndReported() {
        let existing = Contact(name: "Alice", numbers: [ContactNumber(value: "101")])
        let csv = "name,work\nAlice,101\nalice,101\nBob,102\nBob,102\n"
        let result = ContactCSV.importContacts(csv, existing: [existing])
        XCTAssertEqual(result.new.map(\.name), ["Bob"])
        XCTAssertEqual(result.skippedDuplicates, ["Alice", "alice", "Bob"])
    }

    func testSameNameDifferentNumberIsNotADuplicate() {
        let existing = Contact(name: "Alice", numbers: [ContactNumber(value: "101")])
        XCTAssertEqual(ContactCSV.importContacts("name,work\nAlice,102\n", existing: [existing]).new.count, 1)
    }

    func testRowWithoutNameIsReported() {
        let result = ContactCSV.importContacts("name,work\n,101\nOk,102\n", existing: [])
        XCTAssertEqual(result.skippedInvalidRows, [2])
        XCTAssertEqual(result.new.count, 1)
    }

    func testHeaderCaseAndUnknownColumnsIgnored() {
        let result = ContactCSV.importContacts("\u{FEFF}NAME,Mystery,EXTENSION\r\nAl,x,5\r\n", existing: [])
        XCTAssertEqual(result.new.first?.internalExtension, "5")
    }

    func testFormulasAreNeutralizedOnExport() {
        XCTAssertTrue(ContactCSV.export([Contact(name: "=cmd()")]).contains("'=cmd()"))
    }

    func testInternationalNumberIsNotDefanged() {
        XCTAssertTrue(ContactCSV.export([Contact(name: "A", numbers: [ContactNumber(value: "+380501234567")])]).contains(",+380501234567,"))
    }
}

final class SanitizerTests: XCTestCase {
    func testSecretsRemoved() {
        let input = """
        REGISTER sip:pbx SIP/2.0
        Authorization: Digest username="101", realm="x", nonce="abc", response="deadbeef"
        Proxy-Authorization: Digest response="1"
        WWW-Authenticate: Digest nonce="zzz"
        password=hunter2
        Via: SIP/2.0/UDP 1.2.3.4
        """
        let output = DiagnosticsSanitizer.sanitize(input)
        for secret in ["deadbeef", "hunter2", "abc", "zzz"] { XCTAssertFalse(output.contains(secret), secret) }
        XCTAssertTrue(output.contains("Via: SIP/2.0/UDP 1.2.3.4"))
    }
}

final class SettingsTests: XCTestCase {
    func testOlderStoredSettingsKeepDefaultsForNewKeys() throws {
        let decoded = try JSONDecoder().decode(ApplicationSettings.self, from: Data(#"{"doNotDisturb":true}"#.utf8))
        XCTAssertTrue(decoded.doNotDisturb)
        XCTAssertEqual(decoded.codecOrder, ApplicationSettings.defaultCodecs)
    }

    func testLaunchAtLoginDefaultsOff() { XCTAssertFalse(ApplicationSettings().launchAtLogin) }
}
