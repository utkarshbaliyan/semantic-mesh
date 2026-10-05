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
            ("Expiry and hop-eight stop", checks.testExpiredAndHopEightNeverForwarded)
        ]
        for (name, test) in tests { try test(); print("PASS: " + name) }
        print("8 core checks passed. Physical radio delivery is not covered.")
    }
}
#endif
