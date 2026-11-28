import Foundation
import CryptoKit

/// Public keys a contact pins on first direct connection (trust on first use).
public struct PeerKeys: Codable, Equatable {
    public let sign: String
    public let box: String
    public init(sign: String, box: String) throws { self.sign = sign; self.box = box; try validate() }
    public func validate() throws { _ = try signingKey(); _ = try agreementKey() }
    func signingKey() throws -> Curve25519.Signing.PublicKey {
        guard let raw = Data(base64Encoded: sign), raw.count == 32 else { throw RelayError.invalidKeys }
        return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }
    func agreementKey() throws -> Curve25519.KeyAgreement.PublicKey {
        guard let raw = Data(base64Encoded: box), raw.count == 32 else { throw RelayError.invalidKeys }
        return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
    }
    /// Short code people can compare in person.
    public var fingerprint: String {
        let digest = SHA256.hash(data: Data((sign + "|" + box).utf8))
        return digest.prefix(6).map { String(format: "%02X", $0) }.joined().chunked(4).joined(separator: " ")
    }
}
private extension String {
    func chunked(_ size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map { i in
            let start = index(startIndex, offsetBy: i); return String(self[start..<(index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex)])
        }
    }
}

/// This device's long-term private keys.
public final class NodeKeys {
    private struct Stored: Codable { let sign: String; let box: String }
    let signing: Curve25519.Signing.PrivateKey
    let agreement: Curve25519.KeyAgreement.PrivateKey
    public let publicKeys: PeerKeys
    public init() {
        signing = .init(); agreement = .init()
        publicKeys = try! PeerKeys(sign: signing.publicKey.rawRepresentation.base64EncodedString(),
                                   box: agreement.publicKey.rawRepresentation.base64EncodedString())
    }
    public init(file: URL) throws {
        if FileManager.default.fileExists(atPath: file.path) {
            let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file))
            guard let s = Data(base64Encoded: stored.sign), let b = Data(base64Encoded: stored.box) else { throw RelayError.invalidKeys }
            signing = try .init(rawRepresentation: s); agreement = try .init(rawRepresentation: b)
        } else {
            signing = .init(); agreement = .init()
            let stored = Stored(sign: signing.rawRepresentation.base64EncodedString(), box: agreement.rawRepresentation.base64EncodedString())
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            try JSONEncoder().encode(stored).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try JSONEncoder().encode(stored).write(to: file, options: .atomic)
            #endif
            var protected = file; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protected.setResourceValues(values)
        }
        publicKeys = try PeerKeys(sign: signing.publicKey.rawRepresentation.base64EncodedString(),
                                  box: agreement.publicKey.rawRepresentation.base64EncodedString())
    }
}

/// Sent once over each approved direct link so both sides can pin each other's keys.
public struct KeyAnnouncement: Codable, Equatable {
    public let v: Int
    public let kind: String
    public let id: String
    public let keys: PeerKeys
    public init(id: String, keys: PeerKeys) { v = 2; kind = "keys"; self.id = id; self.keys = keys }
    public static func decode(_ data: Data) throws -> KeyAnnouncement {
        guard data.count <= 1024 else { throw MeshError.oversize }
        let a = try JSONDecoder().decode(KeyAnnouncement.self, from: data)
        guard a.v == 2, a.kind == "keys", UUID(uuidString: a.id) != nil else { throw RelayError.invalidFrame }
        try a.keys.validate(); return a
    }
}

/// An end-to-end encrypted, signed envelope that any device may carry toward `to`.
/// Relays see only routing fields; `hops` is the only field they may change.
public struct SealedFrame: Codable, Equatable {
    public static let maxInnerBytes = 10_000
    public let v: Int
    public let kind: String
    public let id: String
    public let from: String
    public let to: String
    public let created: Int64
    public let expires: Int64
    public var hops: Int
    public let box: String
    public let sig: String

    /// Same inner envelope + recipient always maps to the same frame ID, so re-sealing never duplicates.
    public static func frameID(inner: String, to: String) -> String {
        let d = Array(SHA256.hash(data: Data(("sm-frame|" + inner + "|" + to).utf8)))
        let hex = d.prefix(16).map { String(format: "%02x", $0) }.joined()
        let p = Array(hex)
        return [String(p[0..<8]), String(p[8..<12]), String(p[12..<16]), String(p[16..<20]), String(p[20..<32])].joined(separator: "-")
    }
    private static func header(_ id: String, _ from: String, _ to: String, _ created: Int64, _ expires: Int64) -> Data {
        Data("sm-relay-v2|\(id)|\(from)|\(to)|\(created)|\(expires)".utf8)
    }
    private static func key(_ local: Curve25519.KeyAgreement.PrivateKey, _ remote: Curve25519.KeyAgreement.PublicKey, from: String, to: String) throws -> SymmetricKey {
        try local.sharedSecretFromKeyAgreement(with: remote).hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data("semantic-mesh-relay-v2".utf8), sharedInfo: Data((from + ">" + to).utf8), outputByteCount: 32)
    }
    private var signed: Data { Self.header(id, from, to, created, expires) + Data(box.utf8) }

    public static func seal(_ e: Envelope, keys: NodeKeys, recipient: PeerKeys) throws -> SealedFrame {
        guard let to = e.to, to != e.sender else { throw RelayError.invalidFrame }
        var inner = e; inner.hops = 0
        let plain = try inner.encoded()
        guard plain.count <= maxInnerBytes else { throw MeshError.oversize }
        let id = frameID(inner: e.id, to: to)
        let aad = header(id, e.sender, to, e.created, e.expires)
        let sealed = try ChaChaPoly.seal(plain, using: key(keys.agreement, recipient.agreementKey(), from: e.sender, to: to), authenticating: aad)
        let box = sealed.combined.base64EncodedString()
        let sig = try keys.signing.signature(for: aad + Data(box.utf8)).base64EncodedString()
        let frame = SealedFrame(v: 2, kind: "sealed", id: id, from: e.sender, to: to, created: e.created, expires: e.expires, hops: 0, box: box, sig: sig)
        _ = try frame.encoded(); return frame
    }
    public func validate(now: Int64) throws {
        guard v == 2, kind == "sealed", UUID(uuidString: id) != nil, UUID(uuidString: from) != nil, UUID(uuidString: to) != nil,
              from != to, (0...8).contains(hops), created >= 0, created <= now + 300_000,
              expires > created, expires - created <= 3_600_000,
              let b = Data(base64Encoded: box), b.count > 28, b.count <= Self.maxInnerBytes + 28,
              let s = Data(base64Encoded: sig), s.count == 64 else { throw RelayError.invalidFrame }
    }
    public func verify(_ sender: PeerKeys) -> Bool {
        guard let s = Data(base64Encoded: sig), let key = try? sender.signingKey() else { return false }
        return key.isValidSignature(s, for: signed)
    }
    /// Verifies, decrypts and checks the inner envelope matches the routing header.
    public func open(keys: NodeKeys, local: String, sender: PeerKeys, now: Int64 = Envelope.now()) throws -> Envelope {
        try validate(now: now)
        guard to == local, verify(sender), let combined = Data(base64Encoded: box) else { throw RelayError.badSignature }
        let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: combined),
                                        using: Self.key(keys.agreement, sender.agreementKey(), from: from, to: to),
                                        authenticating: Self.header(id, from, to, created, expires))
        let e = try Envelope.decode(plain, now: now)
        guard e.sender == from, e.to == to, e.created == created, e.expires == expires,
              Self.frameID(inner: e.id, to: to) == id else { throw RelayError.invalidFrame }
        return e
    }
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Envelope.maxBytes else { throw MeshError.oversize }
        return data
    }
    public static func decode(_ data: Data, now: Int64 = Envelope.now()) throws -> SealedFrame {
        guard !data.isEmpty, data.count <= Envelope.maxBytes else { throw MeshError.oversize }
        let f = try JSONDecoder().decode(SealedFrame.self, from: data)
        try f.validate(now: now); return f
    }
    public func forwarded() throws -> SealedFrame {
        guard hops < 8 else { throw MeshError.hopLimit }
        var next = self; next.hops += 1; return next
    }
}

public enum RelayError: Error, LocalizedError {
    case invalidKeys, invalidFrame, badSignature, keyMismatch
    public var errorDescription: String? {
        switch self {
        case .invalidKeys: return "Invalid contact keys."
        case .invalidFrame: return "Invalid relayed message."
        case .badSignature: return "Relayed message failed verification and was dropped."
        case .keyMismatch: return "Contact keys changed. Possible impersonation: message rejected."
        }
    }
}

/// Persistent store of frames carried for the mesh, including this device's own outgoing frames.
public final class RelayStore {
    public static let capacity = 500
    private let file: URL
    private var frames: [SealedFrame]
    public init(file: URL) throws {
        self.file = file
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path),
           let saved = try? JSONDecoder().decode([SealedFrame].self, from: Data(contentsOf: file)) {
            let now = Envelope.now()
            frames = Array(saved.filter { (try? $0.validate(now: max(now, $0.created))) != nil && $0.expires > now }.prefix(Self.capacity))
        } else { frames = [] }
    }
    public func active(now: Int64 = Envelope.now()) -> [SealedFrame] { frames.filter { $0.expires > now } }
    public func contains(_ id: String) -> Bool { frames.contains { $0.id == id } }
    /// Returns false for duplicates. When full, evicts the soonest-expiring frame carried for others.
    @discardableResult public func insert(_ frame: SealedFrame, local: String, now: Int64 = Envelope.now()) throws -> Bool {
        try frame.validate(now: now)
        guard frame.expires > now else { return false }
        var next = active(now: now)
        guard !next.contains(where: { $0.id == frame.id }) else { return false }
        if next.count >= Self.capacity {
            guard let victim = next.indices.filter({ next[$0].from != local && next[$0].to != local }).min(by: { next[$0].expires < next[$1].expires })
            else { throw MeshError.storeFull }
            next.remove(at: victim)
        }
        next.append(frame)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        var protected = file; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
        frames = next
        return true
    }
}

/// Epidemic store-and-forward: every frame is offered once to every connected peer, except where it came
/// from and its originator. A frame whose destination is directly connected goes only to that destination.
public final class RelayRouter {
    public enum Outcome: Equatable { case duplicate, forMe, carried }
    public let local: String
    public let store: RelayStore
    public var send: (Data, String) -> Void = { _, _ in }
    /// Signing keys for contacts; frames from known senders with bad signatures are dropped, not carried.
    public var keysFor: (String) -> PeerKeys? = { _ in nil }
    public private(set) var peers: Set<String> = []
    private var offered: [String: Set<String>] = [:]
    public init(local: String, store: RelayStore) { self.local = local; self.store = store }

    public func setPeers(_ next: Set<String>, now: Int64 = Envelope.now()) {
        // Peers that drop are offered everything again when they return; receivers deduplicate.
        for gone in peers.subtracting(next) { for id in offered.keys { offered[id]?.remove(gone) } }
        peers = next; flush(now: now)
    }
    public func originate(_ frame: SealedFrame, now: Int64 = Envelope.now()) throws {
        guard frame.from == local else { throw RelayError.invalidFrame }
        if try store.insert(frame, local: local, now: now) { flush(now: now) }
    }
    public func accept(_ frame: SealedFrame, from peer: String, now: Int64 = Envelope.now()) throws -> Outcome {
        try frame.validate(now: now)
        if let keys = keysFor(frame.from), !frame.verify(keys) { throw RelayError.badSignature }
        guard frame.from != local, try store.insert(frame, local: local, now: now) else { return .duplicate }
        offered[frame.id, default: []].insert(peer)
        if frame.to == local { return .forMe }
        flush(now: now); return .carried
    }
    public func carriedCount(now: Int64 = Envelope.now()) -> Int { store.active(now: now).filter { $0.from != local && $0.to != local }.count }
    public func flush(now: Int64 = Envelope.now()) {
        let live = store.active(now: now)
        offered = offered.filter { id, _ in live.contains { $0.id == id } }
        for frame in live where frame.to != local && frame.hops < 8 {
            let targets: Set<String> = peers.contains(frame.to) ? Set([frame.to]) : peers.subtracting([frame.from])
            for peer in targets.sorted() where !(offered[frame.id]?.contains(peer) ?? false) {
                guard let data = try? frame.forwarded().encoded() else { continue }
                offered[frame.id, default: []].insert(peer)
                send(data, peer)
            }
        }
    }
}
