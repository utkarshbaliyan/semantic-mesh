import Foundation

public struct Envelope: Codable, Equatable {
    public static let maxBytes = 16_384
    public let v: Int
    public let id: String
    public let sender: String
    public let kind: String
    public let created: Int64
    public let expires: Int64
    public var hops: Int
    public let text: String?
    public let ackFor: String?
    public var to: String?
    public var groupID: String? = nil
    public var groupRevision: Int? = nil
    public var group: MeshGroup? = nil
    public var media: MediaDescriptor? = nil

    public static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    public static func message(sender: String, text: String, to: String? = nil, now: Int64 = now()) throws -> Envelope {
        let e = Envelope(v: 1, id: UUID().uuidString.lowercased(), sender: sender, kind: "text",
                         created: now, expires: now + 3_600_000, hops: 0, text: text, ackFor: nil, to: to)
        try e.validate(now: now); return e
    }
    public static func receipt(sender: String, for original: Envelope, now: Int64 = now()) throws -> Envelope {
        let e = Envelope(v: 1, id: UUID().uuidString.lowercased(), sender: sender, kind: "ack",
                         created: now, expires: now + 3_600_000, hops: 0, text: nil, ackFor: original.id, to: original.sender)
        try e.validate(now: now); return e
    }
    public static func groupUpdate(_ group: MeshGroup, to: String, now: Int64 = now()) throws -> Envelope {
        var e = Envelope(v: 1, id: UUID().uuidString.lowercased(), sender: group.ownerID, kind: "group",
                         created: now, expires: now + 3_600_000, hops: 0, text: nil, ackFor: nil, to: to)
        e.groupID = group.id; e.groupRevision = group.revision; e.group = group
        try e.validate(now: now); return e
    }
    public static func attachment(sender: String, media: MediaDescriptor, to: String?, group: MeshGroup? = nil, now: Int64 = now()) throws -> Envelope {
        var e = Envelope(v: 1, id: UUID().uuidString.lowercased(), sender: sender, kind: "media",
                         created: now, expires: now + 3_600_000, hops: 0, text: nil, ackFor: nil, to: to)
        e.media = media; e.groupID = group?.id; e.groupRevision = group?.revision
        try e.validate(now: now); return e
    }
    public static func ready(sender: String, for original: Envelope, now: Int64 = now()) throws -> Envelope {
        var e = Envelope(v: 1, id: UUID().uuidString.lowercased(), sender: sender, kind: "media_ready",
                         created: now, expires: now + 3_600_000, hops: 0, text: nil, ackFor: original.id, to: original.sender)
        e.groupID = original.groupID; e.groupRevision = original.groupRevision
        try e.validate(now: now); return e
    }
    public func validate(now: Int64 = now()) throws {
        guard v == 1, UUID(uuidString: id) != nil, UUID(uuidString: sender) != nil,
              (0...8).contains(hops), created >= 0, created <= now + 300_000,
              expires > created, expires - created <= 3_600_000 else { throw MeshError.invalidEnvelope }
        if let to, UUID(uuidString: to) == nil { throw MeshError.invalidEnvelope }
        if let groupID { guard UUID(uuidString: groupID) != nil, let groupRevision, groupRevision > 0 else { throw MeshError.invalidEnvelope } }
        if groupID == nil, groupRevision != nil { throw MeshError.invalidEnvelope }
        if kind != "group", group != nil { throw MeshError.invalidEnvelope }
        if kind != "media", media != nil { throw MeshError.invalidEnvelope }
        switch kind {
        case "text":
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf16.count <= 2000 else { throw MeshError.invalidEnvelope }
        case "group":
            guard let group, let to, group.ownerID == sender, group.id == groupID, group.revision == groupRevision,
                  UUID(uuidString: to) != nil else { throw MeshError.invalidEnvelope }
            try group.validate()
        case "media":
            guard let media else { throw MeshError.invalidEnvelope }; try media.validate()
        case "media_ready":
            guard let ackFor, UUID(uuidString: ackFor) != nil, to != nil else { throw MeshError.invalidEnvelope }
        case "ack":
            guard let ackFor, UUID(uuidString: ackFor) != nil, let to, UUID(uuidString: to) != nil else { throw MeshError.invalidEnvelope }
        default: throw MeshError.invalidEnvelope
        }
    }
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maxBytes else { throw MeshError.oversize }
        return data
    }
    public static func decode(_ data: Data, now: Int64 = now()) throws -> Envelope {
        guard !data.isEmpty, data.count <= maxBytes else { throw MeshError.oversize }
        let e = try JSONDecoder().decode(Envelope.self, from: data)
        try e.validate(now: now); return e
    }
    public func forwarded() throws -> Envelope {
        guard hops < 8 else { throw MeshError.hopLimit }
        var result = self; result.hops += 1; return result
    }
}
public enum MeshError: Error, LocalizedError {
    case invalidEnvelope, oversize, hopLimit, storeFull
    public var errorDescription: String? {
        switch self {
        case .invalidEnvelope: return "Invalid message or device clock."
        case .oversize: return "Message exceeds the frame limit."
        case .hopLimit: return "Message reached the hop limit."
        case .storeFull: return "Local message store is full."
        }
    }
}
