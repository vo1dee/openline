import XCTest
import OpenlineCore
@testable import OpenlineStore

final class StoreTests: XCTestCase {
    private func entry(_ id: UUID = UUID(), contact: UUID? = nil, outcome: CallOutcome = .answered, at: Date = Date()) -> CallHistoryEntry {
        CallHistoryEntry(id: id, dialTarget: "101", displayIdentity: "Alice", accountID: UUID(), direction: .outgoing, outcome: outcome,
                         startedAt: at, answeredAt: at, endedAt: at.addingTimeInterval(5), contactID: contact, sipStatus: 200, failureDetail: nil)
    }

    func testAccountPersistsWithoutSecretsAndKeepsOrder() throws {
        let db = try AppDatabase()
        let a = SIPAccount(label: "A", server: "a", username: "1")
        let b = SIPAccount(label: "B", server: "b", username: "2")
        try db.save(a)
        try db.save(b)
        var edited = a
        edited.label = "A2"
        try db.save(edited)
        XCTAssertEqual(try db.accounts().map(\.label), ["A2", "B"])
        try db.deleteAccount(a.id)
        XCTAssertEqual(try db.accounts().count, 1)
    }

    func testContactCRUDWithMultipleNumbers() throws {
        let db = try AppDatabase()
        var contact = Contact(name: "Alice", numbers: [ContactNumber(label: .work, value: "1"), ContactNumber(label: .mobile, value: "2")])
        try db.save(contact)
        XCTAssertEqual(try db.contacts().first?.numbers.map(\.value), ["1", "2"])
        contact.numbers.removeFirst()
        contact.isFavorite = true
        try db.save(contact)
        let stored = try db.contacts().first
        XCTAssertEqual(stored?.numbers.map(\.value), ["2"])
        XCTAssertEqual(stored?.isFavorite, true)
        try db.deleteContact(contact.id)
        XCTAssertTrue(try db.contacts().isEmpty)
    }

    func testHistoryIsIdempotent() throws {
        let db = try AppDatabase()
        let item = entry()
        try db.record(item)
        try db.record(item)
        XCTAssertEqual(try db.history().count, 1)
    }

    func testDeletingAContactKeepsHistory() throws {
        let db = try AppDatabase()
        let contact = Contact(name: "A")
        try db.save(contact)
        try db.record(entry(contact: contact.id))
        try db.deleteContact(contact.id)
        XCTAssertEqual(try db.history().count, 1)
        XCTAssertEqual(try db.history().first?.contactID, contact.id)
    }

    func testHistoryOrderAndDeletion() throws {
        let db = try AppDatabase()
        let old = entry(at: Date(timeIntervalSince1970: 100))
        let new = entry(at: Date(timeIntervalSince1970: 200))
        try db.record(old)
        try db.record(new)
        XCTAssertEqual(try db.history().map(\.id), [new.id, old.id])
        try db.deleteHistory(new.id)
        XCTAssertEqual(try db.history().map(\.id), [old.id])
        try db.clearHistory()
        XCTAssertTrue(try db.history().isEmpty)
    }

    func testSettingsRoundTrip() throws {
        let db = try AppDatabase()
        XCTAssertFalse(try db.settings().doNotDisturb)
        var settings = ApplicationSettings()
        settings.doNotDisturb = true
        settings.inputDevice = "USB"
        try db.save(settings)
        XCTAssertEqual(try db.settings(), settings)
    }

    func testDataSurvivesReopen() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try AppDatabase(path: path).save(Contact(name: "Kept"))
        XCTAssertEqual(try AppDatabase(path: path).contacts().first?.name, "Kept")
    }

    func testKeychainRoundTrip() throws {
        let store = KeychainCredentialStore(service: "org.openline.tests.\(UUID().uuidString)")
        let reference = "r"
        defer { try? store.deletePassword(for: reference) }
        XCTAssertNil(try store.password(for: reference))
        try store.setPassword("one", for: reference)
        try store.setPassword("two", for: reference)
        XCTAssertEqual(try store.password(for: reference), "two")
        try store.deletePassword(for: reference)
        XCTAssertNil(try store.password(for: reference))
    }
}
