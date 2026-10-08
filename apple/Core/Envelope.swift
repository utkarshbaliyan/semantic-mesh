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
    public let to: String?

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
    public func validate(now: Int64 = now()) throws {
        guard v == 1, UUID(uuidString: id) != nil, UUID(uuidString: sender) != nil,
              (0...8).contains(hops), created >= 0, created <= now + 300_000,
              expires > created, expires - created <= 3_600_000 else { throw MeshError.invalidEnvelope }
        if let to, UUID(uuidString: to) == nil { throw MeshError.invalidEnvelope }
        switch kind {
        case "text":
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf16.count <= 2000 else { throw MeshError.invalidEnvelope }
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
