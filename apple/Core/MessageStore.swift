import Foundation

/// Used on the main queue by the app. Atomic file replacement completes before a receipt is created.
public final class MessageStore {
    private let file: URL
    private var entries: [Envelope]
    public init(file: URL) throws {
        self.file = file
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
            entries = try JSONDecoder().decode([Envelope].self, from: Data(contentsOf: file))
            guard entries.count <= 5000 else { throw MeshError.storeFull }
            // Expired entries remain eligible for cleanup even if they predate current validation rules.
            for e in entries { try e.validate(now: max(Envelope.now(), e.created)) }
        } else { entries = [] }
    }
    public func active(now: Int64 = Envelope.now()) -> [Envelope] { entries.filter { $0.expires > now } }
    @discardableResult public func insert(_ envelope: Envelope, now: Int64 = Envelope.now()) throws -> Bool {
        try envelope.validate(now: now)
        guard envelope.expires > now else { return false }
        var next = active(now: now)
        guard !next.contains(where: { $0.id == envelope.id }) else { return false }
        guard next.count < 5000 else { throw MeshError.storeFull }
        next.append(envelope)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        var protected = file
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
        entries = next
        return true
    }
}

/// Usernames are local aliases, not globally registered or authenticated accounts.
public struct ChatProfile: Codable, Equatable, Identifiable {
    public let id: String
    public let username: String
    public init(id: String, username: String) throws {
        guard let uuid = UUID(uuidString: id) else { throw ProfileError.invalidIdentity }
        self.id = uuid.uuidString.lowercased()
        self.username = try Self.normalize(username)
    }
    public static func normalize(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.range(of: "^[a-z][a-z0-9_]{2,23}$", options: .regularExpression) != nil else { throw ProfileError.invalidUsername }
        return value
    }
    public func validated() throws -> ChatProfile { try ChatProfile(id: id, username: username) }
    public var label: String { "@\(username) · \(id.prefix(8))" }
}

public enum ProfileError: Error, LocalizedError {
    case invalidUsername, invalidIdentity, tooManyContacts
    public var errorDescription: String? {
        switch self {
        case .invalidUsername: return "Use 3–24 letters, numbers or underscores, starting with a letter."
        case .invalidIdentity: return "Invalid peer identity."
        case .tooManyContacts: return "Contact limit reached."
        }
    }
}

public final class ContactBook {
    private struct State: Codable { var username: String; var contacts: [ChatProfile] }
    private let file: URL
    private var state: State
    public var username: String { state.username }
    public var contacts: [ChatProfile] { state.contacts.sorted { $0.username == $1.username ? $0.id < $1.id : $0.username < $1.username } }
    public init(file: URL, defaultUsername: String) throws {
        self.file = file
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            state.username = try ChatProfile.normalize(state.username)
            guard state.contacts.count <= 500 else { throw ProfileError.tooManyContacts }
            state.contacts = try state.contacts.map { try $0.validated() }
            guard Set(state.contacts.map(\.id)).count == state.contacts.count else { throw ProfileError.invalidIdentity }
        } else { state = State(username: try ChatProfile.normalize(defaultUsername), contacts: []); try save(state) }
    }
    public func profile(for id: String) -> ChatProfile? { state.contacts.first { $0.id == id } }
    public func setUsername(_ username: String) throws {
        var next = state; next.username = try ChatProfile.normalize(username)
        try save(next); state = next
    }
    public func accept(_ profile: ChatProfile) throws {
        let profile = try profile.validated()
        var next = state; next.contacts.removeAll { $0.id == profile.id }
        guard next.contacts.count < 500 else { throw ProfileError.tooManyContacts }
        next.contacts.append(profile); try save(next); state = next
    }
    /// Direct chats cannot enter storage without accepted contact + correct source and recipient.
    public func allows(_ e: Envelope, localIdentity: String, peerIdentity: String) -> Bool {
        profile(for: peerIdentity) != nil && e.sender == peerIdentity && e.to == localIdentity && e.sender != localIdentity
    }
    private func save(_ next: State) throws {
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        var protected = file; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
    }
}
