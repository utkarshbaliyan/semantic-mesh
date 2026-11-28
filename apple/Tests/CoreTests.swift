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
        let expired = try Envelope.message(sender: UUID().uuidString, text: "old", now: now - Envelope.maxLifetime)
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

    private func featureDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }; return directory
    }
    private func sampleGroup() throws -> MeshGroup {
        let owner = try ChatProfile(id: UUID().uuidString, username: "owner")
        let member = try ChatProfile(id: UUID().uuidString, username: "member")
        return MeshGroup(id: UUID().uuidString.lowercased(), ownerID: owner.id, name: "Friends", revision: 1, members: [owner, member])
    }
    func testGroupOwnershipRevisionAndPersistence() throws {
        let file = featureDirectory().appendingPathComponent("groups.json")
        let book = try GroupBook(file: file); var group = try sampleGroup()
        XCTAssertThrowsError(try book.apply(group, from: group.members[1].id))
        try book.apply(group, from: group.ownerID)
        var conflict = group; conflict.name = "Forged edit"
        XCTAssertThrowsError(try book.apply(conflict, from: group.ownerID))
        group.revision = 2; group.name = "Renamed"
        try book.apply(group, from: group.ownerID)
        conflict.revision = 1
        XCTAssertThrowsError(try book.apply(conflict, from: group.ownerID))
        var hijack = group
        hijack = MeshGroup(id: group.id, ownerID: group.members[1].id, name: "Hijacked", revision: 3, members: group.members)
        XCTAssertThrowsError(try book.apply(hijack, from: hijack.ownerID))
        XCTAssertEqual(try GroupBook(file: file).group(group.id), group)
    }
    func testRemovedMemberAndStaleGroupTrafficRejected() throws {
        let book = try GroupBook(file: featureDirectory().appendingPathComponent("groups.json"))
        var group = try sampleGroup(); let removed = group.members[1].id
        try book.apply(group, from: group.ownerID)
        var e = try Envelope.message(sender: removed, text: "group text", to: group.ownerID, now: now)
        e.groupID = group.id; e.groupRevision = 1
        XCTAssertTrue(book.permits(e, local: group.ownerID, peer: removed))
        XCTAssertFalse(book.permits(e, local: removed, peer: group.ownerID))
        group.members.removeLast(); group.revision = 2; try book.apply(group, from: group.ownerID)
        XCTAssertFalse(book.permits(e, local: group.ownerID, peer: removed))
        e.groupRevision = 2
        XCTAssertFalse(book.permits(e, local: group.ownerID, peer: removed))
        XCTAssertTrue(book.audience(group.id).contains { $0.id == removed })
        XCTAssertFalse(book.group(group.id)!.contains(removed))
    }
    func testGroupBoundsAndControlEnvelopeValidation() throws {
        var group = try sampleGroup()
        let update = try Envelope.groupUpdate(group, to: group.members[1].id, now: now)
        XCTAssertEqual(try Envelope.decode(update.encoded(), now: now).group, group)
        var forged = update; forged.groupRevision = 2
        XCTAssertThrowsError(try forged.validate(now: now))
        group.members.append(group.members[1]); XCTAssertThrowsError(try group.validate())
        group = try sampleGroup(); group.name = String(repeating: "x", count: 61)
        XCTAssertThrowsError(try group.validate())
        group = try sampleGroup()
        for i in 0..<15 { group.members.append(try ChatProfile(id: UUID().uuidString, username: "person_\(i)")) }
        XCTAssertThrowsError(try group.validate())
    }
    func testMediaIntegrityPersistenceAndPruning() throws {
        let directory = featureDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("sample.m4a")
        try Data("fixture audio bytes".utf8).write(to: source)
        let vault = try MediaVault(directory: directory.appendingPathComponent("media"))
        let media = try vault.importFile(source, kind: "audio")
        XCTAssertTrue(vault.available(media))
        let restored = try MediaVault(directory: directory.appendingPathComponent("media"))
        XCTAssertTrue(restored.available(media))
        let corrupt = directory.appendingPathComponent("corrupt.m4a")
        try Data("corrupted contents".utf8).write(to: corrupt)
        let second = MediaDescriptor(id: UUID().uuidString.lowercased(), kind: media.kind, fileExtension: media.fileExtension, bytes: media.bytes, sha256: media.sha256)
        XCTAssertThrowsError(try vault.install(corrupt, as: second)); XCTAssertFalse(vault.available(second))
        let collision = MediaDescriptor(id: media.id, kind: media.kind, fileExtension: media.fileExtension, bytes: media.bytes, sha256: String(repeating: "0", count: 64))
        XCTAssertFalse(vault.available(collision))
        vault.prune(keeping: [media.id]); XCTAssertTrue(vault.available(media))
        vault.prune(keeping: []); XCTAssertFalse(vault.available(media))
    }
    func testMediaPathSizeAndTypeBounds() throws {
        for (ext, kind, bytes) in [("../mp3", "audio", Int64(12)), ("exe", "video", 12), ("m4a", "audio", MediaVault.maxBytes + 1), ("mp4", "video", 0)] {
            let media = MediaDescriptor(id: UUID().uuidString, kind: kind, fileExtension: ext, bytes: bytes, sha256: String(repeating: "a", count: 64))
            XCTAssertThrowsError(try media.validate())
        }
        let invalid = MediaDescriptor(id: "../../outside", kind: "audio", fileExtension: "m4a", bytes: 1, sha256: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try invalid.validate())
    }
    func testMediaQuotaRejectsNewFiles() throws {
        let directory = featureDirectory(), mediaDirectory = directory.appendingPathComponent("media")
        let vault = try MediaVault(directory: mediaDirectory)
        let full = mediaDirectory.appendingPathComponent("quota-fixture")
        _ = FileManager.default.createFile(atPath: full.path, contents: nil)
        let file = try FileHandle(forWritingTo: full)
        try file.truncate(atOffset: UInt64(MediaVault.quota)); try file.close()
        let source = directory.appendingPathComponent("sample.mp4")
        try Data("small fixture".utf8).write(to: source)
        XCTAssertThrowsError(try vault.importFile(source, kind: "video"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mediaDirectory.path).count, 1)
    }
    func testMediaReceiptOnlyAfterExplicitVerificationAndIsDeduplicated() throws {
        let engine = MeshEngine(identity: UUID().uuidString.lowercased(), store: try store())
        let media = MediaDescriptor(id: UUID().uuidString.lowercased(), kind: "video", fileExtension: "mp4", bytes: 12, sha256: String(repeating: "a", count: 64))
        let e = try Envelope.attachment(sender: UUID().uuidString.lowercased(), media: media, to: engine.identity, now: now)
        engine.receive(try e.encoded(), from: e.sender, now: now)
        XCTAssertEqual(engine.store.active(now: now).filter { $0.kind == "ack" }.count, 0)
        let ready = try Envelope.ready(sender: engine.identity, for: e, now: now)
        XCTAssertEqual(try Envelope.decode(ready.encoded(), now: now).ackFor, e.id)
        try engine.acknowledge(e, now: now); try engine.acknowledge(e, now: now)
        XCTAssertEqual(engine.store.active(now: now).filter { $0.kind == "ack" }.count, 1)
    }
    func testGroupReceiptPreservesMembershipRevision() throws {
        let group = try sampleGroup()
        let receiver = MeshEngine(identity: group.members[1].id, store: try store())
        var e = try Envelope.message(sender: group.ownerID, text: "hello members", to: receiver.identity, now: now)
        e.groupID = group.id; e.groupRevision = group.revision
        receiver.receive(try e.encoded(), from: e.sender, now: now)
        let ack = receiver.store.active(now: now).first { $0.kind == "ack" }!
        XCTAssertEqual(ack.groupID, group.id); XCTAssertEqual(ack.groupRevision, 1)
        XCTAssertEqual(ack.to, group.ownerID)
    }
    func testEmojiRoundTripAndUTF16Limit() throws {
        let text = "Hi 😀😂❤️👍🏽🎉🙏 — مرحبا"
        let e = try Envelope.message(sender: UUID().uuidString, text: text, now: now)
        XCTAssertEqual(try Envelope.decode(e.encoded(), now: now).text, text)
        XCTAssertThrowsError(try Envelope.message(sender: e.sender, text: String(repeating: "😀", count: 1001), now: now))
    }

    // MARK: Multi-hop relay
    private func relayRouter(_ id: String) throws -> RelayRouter {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return RelayRouter(local: id, store: try RelayStore(file: directory.appendingPathComponent("relay.json")))
    }
    func testSealedFrameRoundTripAndTamperRejection() throws {
        let a = UUID().uuidString.lowercased(), b = UUID().uuidString.lowercased(), c = UUID().uuidString.lowercased()
        let aKeys = NodeKeys(), bKeys = NodeKeys(), cKeys = NodeKeys()
        let e = try Envelope.message(sender: a, text: "secret 🔒", to: b, now: now)
        var frame = try SealedFrame.seal(e, keys: aKeys, recipient: bKeys.publicKeys)
        XCTAssertFalse(String(decoding: try frame.encoded(), as: UTF8.self).contains("secret"))
        XCTAssertEqual(try frame.open(keys: bKeys, local: b, sender: aKeys.publicKeys, now: now).text, "secret 🔒")
        frame = try frame.forwarded().forwarded()
        XCTAssertEqual(try SealedFrame.decode(frame.encoded(), now: now).open(keys: bKeys, local: b, sender: aKeys.publicKeys, now: now).id, e.id)
        XCTAssertThrowsError(try frame.open(keys: cKeys, local: c, sender: aKeys.publicKeys, now: now), "wrong recipient")
        XCTAssertThrowsError(try frame.open(keys: bKeys, local: b, sender: cKeys.publicKeys, now: now), "wrong sender keys")
        var json = try JSONSerialization.jsonObject(with: frame.encoded()) as! [String: Any]
        json["from"] = c
        let spoofed = try SealedFrame.decode(JSONSerialization.data(withJSONObject: json), now: now)
        XCTAssertThrowsError(try spoofed.open(keys: bKeys, local: b, sender: aKeys.publicKeys, now: now), "spoofed sender")
        json = try JSONSerialization.jsonObject(with: frame.encoded()) as! [String: Any]
        var box = Data(base64Encoded: json["box"] as! String)!; box[box.count - 1] ^= 1; json["box"] = box.base64EncodedString()
        let corrupted = try SealedFrame.decode(JSONSerialization.data(withJSONObject: json), now: now)
        XCTAssertFalse(corrupted.verify(aKeys.publicKeys))
        XCTAssertThrowsError(try corrupted.open(keys: bKeys, local: b, sender: aKeys.publicKeys, now: now), "corrupted box")
        XCTAssertEqual(SealedFrame.frameID(inner: e.id, to: b), frame.id)
        XCTAssertEqual(try SealedFrame.seal(e, keys: aKeys, recipient: bKeys.publicKeys).id, frame.id)
    }
    func testFourNodeChainDeliversOnceWithoutBackflow() throws {
        let ids = (0..<4).map { _ in UUID().uuidString.lowercased() }
        let routers = try ids.map { try relayRouter($0) }
        let keys = ids.map { _ in NodeKeys() }
        var queue: [(Int, Data, String)] = []
        var sends: [String] = []
        for (i, router) in routers.enumerated() {
            router.send = { data, peer in sends.append(ids[i] + ">" + peer); queue.append((ids.firstIndex(of: peer)!, data, ids[i])) }
        }
        // Chain: 0 - 1 - 2 - 3. Node 0 cannot see node 3.
        routers[0].setPeers([ids[1]], now: now); routers[1].setPeers([ids[0], ids[2]], now: now)
        routers[2].setPeers([ids[1], ids[3]], now: now); routers[3].setPeers([ids[2]], now: now)
        let e = try Envelope.message(sender: ids[0], text: "far away", to: ids[3], now: now)
        try routers[0].originate(SealedFrame.seal(e, keys: keys[0], recipient: keys[3].publicKeys), now: now)
        var delivered: [Envelope] = []; var hops: [Int] = []; var steps = 0
        while !queue.isEmpty {
            let (target, data, source) = queue.removeFirst(); steps += 1; XCTAssertLessThan(steps, 50)
            let frame = try SealedFrame.decode(data, now: now)
            if try routers[target].accept(frame, from: source, now: now) == .forMe {
                delivered.append(try frame.open(keys: keys[target], local: ids[target], sender: keys[0].publicKeys, now: now)); hops.append(frame.hops)
            }
        }
        XCTAssertEqual(delivered.map(\.text), ["far away"]); XCTAssertEqual(hops, [3])
        XCTAssertEqual(sends, [ids[0] + ">" + ids[1], ids[1] + ">" + ids[2], ids[2] + ">" + ids[3]])
        XCTAssertEqual(routers[1].carriedCount(now: now) + routers[2].carriedCount(now: now), 2)
        routers[1].flush(now: now); routers[2].flush(now: now)
        XCTAssertTrue(queue.isEmpty)
        let again = try SealedFrame.seal(e, keys: keys[0], recipient: keys[3].publicKeys).forwarded()
        XCTAssertEqual(try routers[3].accept(again, from: ids[2], now: now), .duplicate)
    }
    func testCarrierDeliversAfterMovingToDestination() throws {
        let a = UUID().uuidString.lowercased(), carrier = UUID().uuidString.lowercased(), b = UUID().uuidString.lowercased()
        let aKeys = NodeKeys(), bKeys = NodeKeys()
        let ra = try relayRouter(a), rc = try relayRouter(carrier), rb = try relayRouter(b)
        ra.send = { data, _ in _ = try? rc.accept(SealedFrame.decode(data, now: self.now), from: a, now: self.now) }
        var received: [SealedFrame] = []
        rc.send = { data, peer in if peer == b, let f = try? SealedFrame.decode(data, now: self.now), (try? rb.accept(f, from: carrier, now: self.now)) == .forMe { received.append(f) } }
        ra.setPeers([carrier], now: now); rc.setPeers([a], now: now)
        let e = try Envelope.message(sender: a, text: "carry me", to: b, now: now)
        try ra.originate(SealedFrame.seal(e, keys: aKeys, recipient: bKeys.publicKeys), now: now)
        XCTAssertEqual(rc.carriedCount(now: now), 1); XCTAssertTrue(received.isEmpty)
        rc.setPeers([b], now: now) // carrier walks away from A and meets B
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(try received[0].open(keys: bKeys, local: b, sender: aKeys.publicKeys, now: now).text, "carry me")
        let expired = e.expires + 1
        XCTAssertTrue(rc.store.active(now: expired).isEmpty)
    }
    func testRelayDropsForgedFramesFromKnownSenders() throws {
        let a = UUID().uuidString.lowercased(), b = UUID().uuidString.lowercased(), relay = UUID().uuidString.lowercased()
        let aKeys = NodeKeys(), impostor = NodeKeys(), bKeys = NodeKeys()
        let router = try relayRouter(relay)
        router.keysFor = { $0 == a ? aKeys.publicKeys : nil }
        let forged = try SealedFrame.seal(Envelope.message(sender: a, text: "fake", to: b, now: now), keys: impostor, recipient: bKeys.publicKeys)
        XCTAssertThrowsError(try router.accept(forged, from: UUID().uuidString, now: now))
        XCTAssertEqual(router.carriedCount(now: now), 0)
    }
    func testRelayDigestSkipsFramesThePeerAlreadyHas() throws {
        let a = UUID().uuidString.lowercased(), b = UUID().uuidString.lowercased()
        let aKeys = NodeKeys(), bKeys = NodeKeys()
        let router = try relayRouter(a)
        var sentTo: [(String, String)] = []  // (frameID, peer)
        router.send = { data, peer in if let f = try? SealedFrame.decode(data, now: self.now) { sentTo.append((f.id, peer)) } }
        let e1 = try Envelope.message(sender: a, text: "one", to: b, now: now)
        let e2 = try Envelope.message(sender: a, text: "two", to: b, now: now)
        let f1 = try SealedFrame.seal(e1, keys: aKeys, recipient: bKeys.publicKeys)
        let f2 = try SealedFrame.seal(e2, keys: aKeys, recipient: bKeys.publicKeys)
        try router.originate(f1, now: now); try router.originate(f2, now: now)
        // Peer b reports it already holds f1; after marking, only f2 should be offered.
        router.markKnown(RelayDigest(frameIDs: [f1.id]), for: b, now: now)
        sentTo.removeAll()
        router.setPeers([b], now: now)
        XCTAssertTrue(sentTo.contains { $0 == (f2.id, b) })
        XCTAssertFalse(sentTo.contains { $0.0 == f1.id })
        // The device's own digest lists both frames.
        let digest = router.digest(now: now)
        XCTAssertTrue(digest.contains(f1.id) && digest.contains(f2.id))
    }
    func testRelayDigestBloomHasNoFalseNegatives() throws {
        let ids = Set((0..<600).map { _ in UUID().uuidString.lowercased() })
        let digest = try RelayDigest.decode(RelayDigest(frameIDs: ids).encoded())
        for id in ids { XCTAssertTrue(digest.contains(id)) }  // Bloom filter: never a false negative
    }
    func testIdentityTagIsStableFourHexFromSigningKey() throws {
        let keys = NodeKeys().publicKeys
        XCTAssertTrue(keys.tag.range(of: "^[0-9A-F]{4}$", options: .regularExpression) != nil)
        XCTAssertEqual(keys.tag, PeerKeys.tag(forSignKey: keys.sign))
        XCTAssertEqual(keys.tag, keys.tag) // deterministic
        XCTAssertEqual(PeerKeys.tag(forSignKey: "not-base64!"), "----")
    }
    func testContactCardLinkRoundTripAndRejection() throws {
        let id = UUID().uuidString.lowercased()
        let keys = NodeKeys().publicKeys
        let card = try ContactCard(id: id, username: "Alice_1", keys: keys)
        let parsed = try ContactCard.parse(card.link)
        XCTAssertEqual(parsed.id, id)
        XCTAssertEqual(parsed.username, "alice_1")
        XCTAssertEqual(parsed.keys, keys)
        XCTAssertEqual(parsed.tag, keys.tag)
        XCTAssertThrowsError(try ContactCard.parse("https://add?id=x"))
        XCTAssertThrowsError(try ContactCard.parse("sm://add?id=\(id)&sign=\(keys.sign)")) // missing fields
        XCTAssertThrowsError(try ContactCard.parse("sm://add?id=not-a-uuid&sign=\(keys.sign)&box=\(keys.box)&name=alice"))
    }
    func testNicknamesAndVerifiedPersistAndOverrideUsername() throws {
        let directory = featureDirectory()
        let file = directory.appendingPathComponent("contacts.json")
        let id = UUID().uuidString.lowercased()
        let keys = NodeKeys().publicKeys
        do {
            let book = try ContactBook(file: file, defaultUsername: "owner")
            try book.addVerified(ContactCard(id: id, username: "bob", keys: keys))
            XCTAssertTrue(book.isVerified(id))
            XCTAssertEqual(book.tag(for: id), keys.tag)
            XCTAssertEqual(book.displayName(for: id), "bob")
            try book.setNickname("Roommate", for: id)
            XCTAssertEqual(book.displayName(for: id), "Roommate")
            XCTAssertThrowsError(try book.setNickname(String(repeating: "x", count: 41), for: id))
            XCTAssertThrowsError(try book.setNickname("x", for: UUID().uuidString.lowercased()))
        }
        let restored = try ContactBook(file: file, defaultUsername: "unused")
        XCTAssertEqual(restored.displayName(for: id), "Roommate")
        XCTAssertTrue(restored.isVerified(id))
        XCTAssertEqual(restored.tag(for: id), keys.tag)
        try restored.setNickname("", for: id)
        XCTAssertEqual(restored.displayName(for: id), "bob")
    }
    func testEncryptedStoreKeepsHistoryBeyondDeliveryWindowAndEncryptsAtRest() throws {
        let directory = featureDirectory()
        let file = directory.appendingPathComponent("mesh.sqlite")
        let sender = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        let e = try Envelope.message(sender: sender, text: "secret-at-rest-marker", to: other, now: now)
        do {
            let db = try MeshDatabase(file: file, secret: try SecretBox(directory: directory, useKeychain: false))
            let store = MessageStore(database: db)
            XCTAssertTrue(try store.insert(e, now: now))
            XCTAssertFalse(try store.insert(e, now: now))               // dedup
            XCTAssertEqual(store.active(now: now).count, 1)
            XCTAssertTrue(store.active(now: e.expires).isEmpty)          // delivery window closed
            XCTAssertEqual(store.stored().count, 1)                      // history remains
        }
        // The plaintext must not be on disk.
        let raw = try Data(contentsOf: file) + ((try? Data(contentsOf: directory.appendingPathComponent("mesh.sqlite-wal"))) ?? Data())
        XCTAssertTrue(raw.range(of: Data("secret-at-rest-marker".utf8)) == nil)
        // Reopen with the same key file: history survives restart; deletion works.
        let db2 = try MeshDatabase(file: file, secret: try SecretBox(directory: directory, useKeychain: false))
        let store2 = MessageStore(database: db2)
        XCTAssertEqual(store2.stored().count, 1)
        XCTAssertEqual(store2.active(now: now).first?.text, "secret-at-rest-marker")
        store2.deleteDirect(sender, other)
        XCTAssertTrue(store2.stored().isEmpty)
    }
    func testDisappearingSettingsPersist() throws {
        let directory = featureDirectory()
        let file = directory.appendingPathComponent("mesh.sqlite")
        do {
            let store = MessageStore(database: try MeshDatabase(file: file, secret: try SecretBox(directory: directory, useKeychain: false)))
            try store.setDisappearing(["c:abc": 86_400_000])
        }
        let store = MessageStore(database: try MeshDatabase(file: file, secret: try SecretBox(directory: directory, useKeychain: false)))
        XCTAssertEqual(store.disappearing()["c:abc"], 86_400_000)
    }
    func testRelayStoreProtectsOwnAndAddressedFramesWhenClearing() throws {
        let directory = featureDirectory()
        let local = UUID().uuidString.lowercased()
        let a = NodeKeys(), b = NodeKeys()
        let other1 = UUID().uuidString.lowercased(), other2 = UUID().uuidString.lowercased()
        let store = try RelayStore(file: directory.appendingPathComponent("mesh.sqlite"))
        // own outgoing (from local), addressed-to-me (to local), and carried-for-others.
        let mine = try SealedFrame.seal(Envelope.message(sender: local, text: "mine", to: other1, now: now), keys: a, recipient: b.publicKeys)
        let toMe = try SealedFrame.seal(Envelope.message(sender: other1, text: "to me", to: local, now: now), keys: a, recipient: b.publicKeys)
        let carried = try SealedFrame.seal(Envelope.message(sender: other1, text: "carry", to: other2, now: now), keys: a, recipient: b.publicKeys)
        XCTAssertTrue(try store.insert(mine, local: local, now: now))
        XCTAssertTrue(try store.insert(toMe, local: local, now: now))
        XCTAssertTrue(try store.insert(carried, local: local, now: now))
        XCTAssertFalse(try store.insert(carried, local: local, now: now)) // dedup
        XCTAssertEqual(store.usage(now: now).count, 3)
        store.clearCarried(local: local)
        let ids = Set(store.active(now: now).map(\.id))
        XCTAssertTrue(ids.contains(mine.id)); XCTAssertTrue(ids.contains(toMe.id)); XCTAssertFalse(ids.contains(carried.id))
    }
    func testInviteProofBindsIdentitiesAndExpires() throws {
        let a = NodeKeys(), b = NodeKeys()
        let from = UUID().uuidString.lowercased(), to = UUID().uuidString.lowercased()
        let sig = InviteProof.sign(keys: a, from: from, to: to, peerName: "@alice-1234", time: now)!
        XCTAssertTrue(InviteProof.verify(sig, keys: a.publicKeys, from: from, to: to, peerName: "@alice-1234", time: now, now: now + 1_000))
        XCTAssertFalse(InviteProof.verify(sig, keys: b.publicKeys, from: from, to: to, peerName: "@alice-1234", time: now, now: now))
        XCTAssertFalse(InviteProof.verify(sig, keys: a.publicKeys, from: to, to: from, peerName: "@alice-1234", time: now, now: now))
        XCTAssertFalse(InviteProof.verify(sig, keys: a.publicKeys, from: from, to: to, peerName: "@mallory-1234", time: now, now: now))
        XCTAssertFalse(InviteProof.verify(sig, keys: a.publicKeys, from: from, to: to, peerName: "@alice-1234", time: now, now: now + InviteProof.window + 1))
    }
    func testContactKeysPinnedOnFirstUse() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("contacts.json")
        let book = try ContactBook(file: file, defaultUsername: "local_user")
        let peer = try ChatProfile(id: UUID().uuidString, username: "peer_one")
        let keys = NodeKeys().publicKeys
        XCTAssertThrowsError(try book.pin(keys, for: peer.id), "not a contact")
        try book.accept(peer)
        XCTAssertTrue(try book.pin(keys, for: peer.id)); XCTAssertFalse(try book.pin(keys, for: peer.id))
        XCTAssertThrowsError(try book.pin(NodeKeys().publicKeys, for: peer.id), "changed keys")
        XCTAssertEqual(try ContactBook(file: file, defaultUsername: "local_user").keys(for: peer.id), keys)
        let nodeFile = directory.appendingPathComponent("node-keys.json")
        XCTAssertEqual(try NodeKeys(file: nodeFile).publicKeys, try NodeKeys(file: nodeFile).publicKeys)
        XCTAssertEqual(keys.fingerprint.count, 14)
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
            ("Queued contact chat", checks.testContactChatQueuesUntilReconnect),
            ("Group owner, revision and persistence", checks.testGroupOwnershipRevisionAndPersistence),
            ("Removed members and stale traffic", checks.testRemovedMemberAndStaleGroupTrafficRejected),
            ("Group control bounds", checks.testGroupBoundsAndControlEnvelopeValidation),
            ("Media integrity, persistence and pruning", checks.testMediaIntegrityPersistenceAndPruning),
            ("Media path, size and format bounds", checks.testMediaPathSizeAndTypeBounds),
            ("Media quota", checks.testMediaQuotaRejectsNewFiles),
            ("Verified media receipt and deduplication", checks.testMediaReceiptOnlyAfterExplicitVerificationAndIsDeduplicated),
            ("Group receipt revision", checks.testGroupReceiptPreservesMembershipRevision),
            ("Emoji and UTF16 bounds", checks.testEmojiRoundTripAndUTF16Limit),
            ("Sealed frame encryption and tamper rejection", checks.testSealedFrameRoundTripAndTamperRejection),
            ("Four-node chain, single delivery, no backflow", checks.testFourNodeChainDeliversOnceWithoutBackflow),
            ("Carrier store-and-forward", checks.testCarrierDeliversAfterMovingToDestination),
            ("Forged relay frames dropped", checks.testRelayDropsForgedFramesFromKnownSenders),
            ("Contact keys pinned on first use", checks.testContactKeysPinnedOnFirstUse),
            ("Friend invite proof", checks.testInviteProofBindsIdentitiesAndExpires),
            ("Identity tag from signing key", checks.testIdentityTagIsStableFourHexFromSigningKey),
            ("Contact card link round-trip", checks.testContactCardLinkRoundTripAndRejection),
            ("Nicknames and verified contacts", checks.testNicknamesAndVerifiedPersistAndOverrideUsername),
            ("Encrypted store history and at-rest", checks.testEncryptedStoreKeepsHistoryBeyondDeliveryWindowAndEncryptsAtRest),
            ("Disappearing settings persist", checks.testDisappearingSettingsPersist),
            ("Relay store protects own/addressed frames", checks.testRelayStoreProtectsOwnAndAddressedFramesWhenClearing),
            ("Relay digest skips known frames", checks.testRelayDigestSkipsFramesThePeerAlreadyHas),
            ("Relay digest Bloom no false negatives", checks.testRelayDigestBloomHasNoFalseNegatives)
        ]
        for (name, test) in tests { try test(); print("PASS: " + name) }
        print("\(tests.count) core checks passed. Physical radio delivery is not covered.")
    }
}
#endif
