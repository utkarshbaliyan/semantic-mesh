import Foundation
#if CORE_CHECKS
// Portable runner for Macs with Command Line Tools but no XCTest/Xcode installation.
class TestBase {
    private var cleanups: [() -> Void] = []
    func addTeardownBlock(_ cleanup: @escaping () -> Void) { cleanups.append(cleanup) }
    deinit { for cleanup in cleanups { cleanup() } }
}
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { precondition(a == b, "Expected equality", file: file, line: line) }
func XCTAssertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(value, "Expected true", file: file, line: line) }
func XCTAssertFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(!value, "Expected false", file: file, line: line) }
func XCTAssertLessThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { precondition(a < b, "Expected less than", file: file, line: line) }
func XCTAssertThrowsError<T>(_ action: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    do { _ = try action() } catch { return }
    preconditionFailure("Expected error: " + message, file: file, line: line)
}
#else
import XCTest
@testable import SemanticMeshCore
typealias TestBase = XCTestCase
#endif

final class CoreTests: TestBase {
    private let now: Int64 = 1_800_000_000_000
    private func store() throws -> MessageStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try MessageStore(file: directory.appendingPathComponent("messages.json"))
    }
    func testAndroidJSONCompatibility() throws {
        let json = """
        {"v":1,"id":"6e660c50-2cc6-45c6-b6ae-130646d40b54","sender":"85907c70-cbd6-41b1-9eb4-8b8ee7db9811","kind":"text","created":1800000000000,"expires":1800003600000,"hops":1,"text":"hello"}
        """
        let e = try Envelope.decode(Data(json.utf8), now: now)
        XCTAssertEqual(e.text, "hello"); XCTAssertEqual(e.hops, 1)
        XCTAssertEqual(try Envelope.decode(e.encoded(), now: now), e)
    }
    func testForwardPreservesIdentityExpiryAndOriginal() throws {
        let e = try Envelope.message(sender: UUID().uuidString, text: "hello", now: now)
        let next = try e.forwarded()
        XCTAssertEqual(next.id, e.id); XCTAssertEqual(next.expires, e.expires)
        XCTAssertEqual(e.hops, 0); XCTAssertEqual(next.hops, 1)
    }
    func testHopLimitAndOversizeRejected() throws {
        var e = try Envelope.message(sender: UUID().uuidString, text: "hello", now: now)
        for _ in 0..<8 { e = try e.forwarded() }
        XCTAssertThrowsError(try e.forwarded())
        XCTAssertThrowsError(try Envelope.decode(Data(repeating: 65, count: Envelope.maxBytes + 1), now: now))
    }
    func testInvalidFieldsRejected() throws {
        let e = try Envelope.message(sender: UUID().uuidString, text: "hello", now: now)
        let original = try JSONSerialization.jsonObject(with: e.encoded()) as! [String: Any]
        for field in ["v", "id", "sender", "kind", "created", "expires", "hops", "text"] {
            var broken = original; broken.removeValue(forKey: field)
            XCTAssertThrowsError(try Envelope.decode(JSONSerialization.data(withJSONObject: broken), now: now), field)
        }
        var future = original; future["created"] = now + 600_000
        XCTAssertThrowsError(try Envelope.decode(JSONSerialization.data(withJSONObject: future), now: now))
    }
    func testPersistenceDedupAndExpiry() throws {
        let store = try store()
        let e = try Envelope.message(sender: UUID().uuidString, text: "persist", now: now)
        XCTAssertTrue(try store.insert(e, now: now))
        XCTAssertFalse(try store.insert(e, now: now))
        XCTAssertEqual(store.active(now: now).count, 1)
        XCTAssertTrue(store.active(now: e.expires).isEmpty)
        XCTAssertFalse(try store.insert(e, now: e.expires))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("messages.json")
        XCTAssertTrue(try MessageStore(file: file).insert(e, now: now))
        XCTAssertEqual(try MessageStore(file: file).active(now: now), [e])
    }
    func testThreeNodeRelayReceiptsAndDuplicates() throws {
        let a = MeshEngine(identity: UUID().uuidString, store: try store())
        let b = MeshEngine(identity: UUID().uuidString, store: try store())
        let c = MeshEngine(identity: UUID().uuidString, store: try store())
        var queue: [(MeshEngine, Data, String)] = []
        a.transmit = { data, except in if except != "B" { queue.append((b, data, "A")) } }
        b.transmit = { data, except in
            if except != "A" { queue.append((a, data, "B")) }
            if except != "C" { queue.append((c, data, "B")) }
        }
        c.transmit = { data, except in if except != "B" { queue.append((b, data, "C")) } }
        try a.send(text: "Relay this", now: now)
        var deliveries = 0
        while !queue.isEmpty {
            let (target, data, source) = queue.removeFirst(); target.receive(data, from: source, now: now)
            deliveries += 1; XCTAssertLessThan(deliveries, 100)
            if deliveries >= 100 { break }
        }
        let cText = c.store.active(now: now).filter { $0.kind == "text" }
        XCTAssertEqual(cText.count, 1); XCTAssertEqual(cText.first?.hops, 2)
        let receipts = a.store.active(now: now).filter { $0.kind == "ack" && $0.to == a.identity }
        XCTAssertEqual(Set(receipts.map(\.sender)), Set([b.identity, c.identity]))
        b.sync(now: now)
        while !queue.isEmpty { let (target, data, source) = queue.removeFirst(); target.receive(data, from: source, now: now) }
        XCTAssertEqual(c.store.active(now: now).filter { $0.kind == "text" }.count, 1)
    }
    func testDisconnectedStoreAndForward() throws {
        let a = MeshEngine(identity: UUID().uuidString, store: try store())
        let b = MeshEngine(identity: UUID().uuidString, store: try store())
        let c = MeshEngine(identity: UUID().uuidString, store: try store())
        a.transmit = { data, _ in b.receive(data, from: "A", now: self.now) }
        try a.send(text: "Deliver later", now: now)
        XCTAssertTrue(c.store.active(now: now).isEmpty)
        b.transmit = { data, _ in c.receive(data, from: "B", now: self.now) }
        b.sync(now: now)
        XCTAssertEqual(c.store.active(now: now).filter { $0.kind == "text" }.first?.text, "Deliver later")
    }
    func testExpiredAndHopEightNeverForwarded() throws {
        let engine = MeshEngine(identity: UUID().uuidString, store: try store())
        var transmissions = 0; engine.transmit = { _, _ in transmissions += 1 }
        var e = try Envelope.message(sender: engine.identity, text: "limit", now: now)
        for _ in 0..<8 { e = try e.forwarded() }
        engine.receive(try e.encoded(), from: "B", now: now)
        XCTAssertEqual(transmissions, 0)
        let expired = try Envelope.message(sender: UUID().uuidString, text: "old", now: now - 3_600_000)
        engine.receive(try expired.encoded(), from: "B", now: now)
        XCTAssertEqual(engine.store.active(now: now).count, 1)
        XCTAssertEqual(transmissions, 0)
    }
    private func contactBook() throws -> ContactBook {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try ContactBook(file: directory.appendingPathComponent("contacts.json"), defaultUsername: "test_user")
    }
    func testUsernameValidationAndNormalization() throws {
        XCTAssertEqual(try ChatProfile.normalize("  Utkarsh_16 "), "utkarsh_16")
        for invalid in ["ab", "1user", "a b", "über", "_user", String(repeating: "a", count: 25)] {
            XCTAssertThrowsError(try ChatProfile.normalize(invalid), invalid)
        }
    }
    func testContactsPersistAndDuplicateNamesRemainDistinct() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("contacts.json")
        let book = try ContactBook(file: file, defaultUsername: "before")
        let first = try ChatProfile(id: UUID().uuidString, username: "same_name")
        let second = try ChatProfile(id: UUID().uuidString, username: "same_name")
        try book.accept(first); try book.accept(second); try book.setUsername("after")
        let restored = try ContactBook(file: file, defaultUsername: "unused")
        XCTAssertEqual(restored.username, "after")
        XCTAssertEqual(Set(restored.contacts.map(\.id)), Set([first.id, second.id]))
        try restored.accept(try ChatProfile(id: first.id, username: "renamed"))
        XCTAssertEqual(restored.contacts.count, 2)
        XCTAssertEqual(restored.profile(for: first.id)?.username, "renamed")
    }
    func testUnacceptedWrongRecipientAndSpoofedSenderRejected() throws {
        let book = try contactBook()
        let local = UUID().uuidString.lowercased()
        let profile = try ChatProfile(id: UUID().uuidString, username: "alice")
        let e = try Envelope.message(sender: profile.id, text: "private", to: local, now: now)
        XCTAssertFalse(book.allows(e, localIdentity: local, peerIdentity: profile.id))
        try book.accept(profile)
        XCTAssertTrue(book.allows(e, localIdentity: local, peerIdentity: profile.id))
        XCTAssertFalse(book.allows(e, localIdentity: UUID().uuidString, peerIdentity: profile.id))
        XCTAssertFalse(book.allows(e, localIdentity: local, peerIdentity: UUID().uuidString))
        let broadcast = try Envelope.message(sender: profile.id, text: "broadcast", now: now)
        XCTAssertFalse(book.allows(broadcast, localIdentity: local, peerIdentity: profile.id))
    }
    func testAuthorizationRunsBeforeStorageAndReceipt() throws {
        let book = try contactBook()
        let sender = try ChatProfile(id: UUID().uuidString, username: "alice")
        let engine = MeshEngine(identity: UUID().uuidString.lowercased(), store: try store())
        engine.authorizeIncoming = { e, peer in book.allows(e, localIdentity: engine.identity, peerIdentity: peer) }
        var receipts = 0
        engine.transmit = { data, _ in if (try? Envelope.decode(data, now: self.now))?.kind == "ack" { receipts += 1 } }
        let e = try Envelope.message(sender: sender.id, text: "only after acceptance", to: engine.identity, now: now)
        engine.receive(try e.encoded(), from: sender.id, now: now)
        XCTAssertTrue(engine.store.active(now: now).isEmpty); XCTAssertEqual(receipts, 0)
        try book.accept(sender)
        engine.receive(try e.encoded(), from: sender.id, now: now)
        XCTAssertEqual(engine.store.active(now: now).filter { $0.kind == "text" }.count, 1)
        XCTAssertEqual(receipts, 1)
        engine.receive(try e.encoded(), from: sender.id, now: now)
        XCTAssertEqual(receipts, 1)
    }
    func testDirectedMessagesOnlyGetDestinationReceipt() throws {
        let a = MeshEngine(identity: UUID().uuidString.lowercased(), store: try store())
        let b = MeshEngine(identity: UUID().uuidString.lowercased(), store: try store())
        let c = MeshEngine(identity: UUID().uuidString.lowercased(), store: try store())
        var queue: [(MeshEngine, Data, String)] = []
        a.transmit = { data, except in if except != "B" { queue.append((b, data, "A")) } }
        b.transmit = { data, except in
            if except != "A" { queue.append((a, data, "B")) }
            if except != "C" { queue.append((c, data, "B")) }
        }
        c.transmit = { data, except in if except != "B" { queue.append((b, data, "C")) } }
        try a.send(text: "for C", to: c.identity, now: now)
        while !queue.isEmpty { let (target, data, source) = queue.removeFirst(); target.receive(data, from: source, now: now) }
        let receipts = a.store.active(now: now).filter { $0.kind == "ack" }
        XCTAssertEqual(receipts.count, 1); XCTAssertEqual(receipts.first?.sender, c.identity)
        XCTAssertEqual(c.store.active(now: now).first { $0.kind == "text" }?.to, c.identity)
    }
    func testContactChatQueuesUntilReconnect() throws {
        let a = MeshEngine(identity: UUID().uuidString.lowercased(), store: try store())
        let b = MeshEngine(identity: UUID().uuidString.lowercased(), store: try store())
        try a.send(text: "queued chat", to: b.identity, now: now)
        XCTAssertTrue(b.store.active(now: now).isEmpty)
        a.transmit = { data, _ in b.receive(data, from: a.identity, now: self.now) }
        a.sync(now: now)
        XCTAssertEqual(b.store.active(now: now).first { $0.kind == "text" }?.text, "queued chat")
        XCTAssertEqual(b.store.active(now: now).first { $0.kind == "text" }?.to, b.identity)
    }

}

#if CORE_CHECKS
@main struct CoreCheckRunner {
    static func main() throws {
        let checks = CoreTests()
        let tests: [(String, () throws -> Void)] = [
            ("Android JSON compatibility", checks.testAndroidJSONCompatibility),
            ("Forwarding invariants", checks.testForwardPreservesIdentityExpiryAndOriginal),
            ("Hop and frame bounds", checks.testHopLimitAndOversizeRejected),
            ("Invalid fields", checks.testInvalidFieldsRejected),
            ("Persistence, dedup and expiry", checks.testPersistenceDedupAndExpiry),
            ("Three-node relay and receipts", checks.testThreeNodeRelayReceiptsAndDuplicates),
            ("Disconnected store and forward", checks.testDisconnectedStoreAndForward),
            ("Expiry and hop-eight stop", checks.testExpiredAndHopEightNeverForwarded),
            ("Username validation", checks.testUsernameValidationAndNormalization),
            ("Persistent contacts and duplicate names", checks.testContactsPersistAndDuplicateNamesRemainDistinct),
            ("Contact, recipient and sender authorization", checks.testUnacceptedWrongRecipientAndSpoofedSenderRejected),
            ("Acceptance before storage or receipts", checks.testAuthorizationRunsBeforeStorageAndReceipt),
            ("Directed delivery receipts", checks.testDirectedMessagesOnlyGetDestinationReceipt),
            ("Queued contact chat", checks.testContactChatQueuesUntilReconnect)
        ]
        for (name, test) in tests { try test(); print("PASS: " + name) }
        print("14 core checks passed. Physical radio delivery is not covered.")
    }
}
#endif
