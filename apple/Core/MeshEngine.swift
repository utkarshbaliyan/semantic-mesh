import Foundation

/// Transports carry complete JSON envelopes. Android RFCOMM adds a four-byte framing prefix.
public final class MeshEngine {
    public let identity: String
    public let store: MessageStore
    public var transmit: (Data, String?) -> Void = { _, _ in }
    public var authorizeIncoming: (Envelope, String) -> Bool = { _, _ in true }
    public var received: (Envelope) -> Void = { _ in }
    public var error: (Error) -> Void = { _ in }
    public init(identity: String, store: MessageStore) { self.identity = identity; self.store = store }
    public func send(text: String, to: String? = nil, now: Int64 = Envelope.now()) throws {
        let e = try Envelope.message(sender: identity, text: text, to: to, now: now)
        try store.insert(e, now: now); received(e); try forward(e, excluding: nil, now: now)
    }
    public func submit(_ e: Envelope, now: Int64 = Envelope.now()) throws {
        try store.insert(e, now: now); received(e); try forward(e, excluding: nil, now: now)
    }
    public func acknowledge(_ original: Envelope, now: Int64 = Envelope.now()) throws {
        if store.active(now: now).contains(where: { $0.kind == "ack" && $0.sender == identity && $0.ackFor == original.id }) { return }
        var ack = try Envelope.receipt(sender: identity, for: original, now: now)
        ack.groupID = original.groupID; ack.groupRevision = original.groupRevision
        try submit(ack, now: now)
    }
    public func receive(_ data: Data, from peer: String, now: Int64 = Envelope.now()) {
        do {
            let e = try Envelope.decode(data, now: now)
            guard authorizeIncoming(e, peer) else { return }
            guard try store.insert(e, now: now) else { return }
            received(e)
            if e.kind == "text", e.sender != identity, e.to == nil || e.to == identity {
                try acknowledge(e, now: now)
            }
            try forward(e, excluding: peer, now: now)
        } catch { self.error(error) }
    }
    public func sync(now: Int64 = Envelope.now()) {
        do { for e in store.active(now: now) { try forward(e, excluding: nil, now: now) } }
        catch { self.error(error) }
    }
    private func forward(_ e: Envelope, excluding peer: String?, now: Int64) throws {
        guard e.expires > now, e.hops < 8 else { return }
        transmit(try e.forwarded().encoded(), peer)
    }
}
