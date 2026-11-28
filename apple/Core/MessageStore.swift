import Foundation
import CryptoKit

// MessageStore now lives in Database.swift (SQLite-backed, encrypted at rest).

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
    public static let maxNicknameLength = 40
    private struct State: Codable {
        var username: String; var contacts: [ChatProfile]; var keys: [String: PeerKeys]? = nil
        /// Local-only display names and QR/link-verified identities, keyed by contact id.
        var nicknames: [String: String]? = nil
        var verified: [String]? = nil
    }
    private let backend: BlobStore
    private let key: String
    private var state: State
    public var username: String { state.username }
    public var contacts: [ChatProfile] { state.contacts.sorted { $0.username == $1.username ? $0.id < $1.id : $0.username < $1.username } }
    public init(backend: BlobStore, key: String = "contacts", defaultUsername: String) throws {
        self.backend = backend; self.key = key
        if let data = try backend.load(key) {
            state = try JSONDecoder().decode(State.self, from: data)
            state.username = try ChatProfile.normalize(state.username)
            guard state.contacts.count <= 500 else { throw ProfileError.tooManyContacts }
            state.contacts = try state.contacts.map { try $0.validated() }
            guard Set(state.contacts.map(\.id)).count == state.contacts.count else { throw ProfileError.invalidIdentity }
            for (id, keys) in state.keys ?? [:] { guard state.contacts.contains(where: { $0.id == id }) else { throw ProfileError.invalidIdentity }; try keys.validate() }
            state.nicknames = (state.nicknames ?? [:]).filter { id, name in state.contacts.contains { $0.id == id } && !name.isEmpty }
            state.verified = (state.verified ?? []).filter { id in state.contacts.contains { $0.id == id } }
        } else { state = State(username: try ChatProfile.normalize(defaultUsername), contacts: []); try save(state) }
    }
    /// Test convenience: a file-backed book at the given path.
    public convenience init(file: URL, defaultUsername: String) throws {
        let backend = try FileBlobStore(directory: file.deletingLastPathComponent())
        try self.init(backend: backend, key: file.deletingPathExtension().lastPathComponent, defaultUsername: defaultUsername)
    }
    public func profile(for id: String) -> ChatProfile? { state.contacts.first { $0.id == id } }
    public func keys(for id: String) -> PeerKeys? { state.keys?[id] }
    public func nickname(for id: String) -> String? { state.nicknames?[id] }
    public func isVerified(_ id: String) -> Bool { state.verified?.contains(id) == true }
    /// A short tag derived from pinned keys, shown as username#TAG once keys are known.
    public func tag(for id: String) -> String? { state.keys?[id]?.tag }
    /// The name shown in the UI: a local nickname if set, otherwise the contact's chosen username.
    public func displayName(for id: String) -> String? { state.nicknames?[id] ?? profile(for: id)?.username }
    /// Sets or (with nil/empty) clears a local-only nickname for a contact.
    public func setNickname(_ name: String?, for id: String) throws {
        guard profile(for: id) != nil else { throw ProfileError.invalidIdentity }
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf16.count <= Self.maxNicknameLength else { throw ProfileError.invalidUsername }
        var next = state; var all = next.nicknames ?? [:]
        if trimmed.isEmpty { all.removeValue(forKey: id) } else { all[id] = trimmed }
        next.nicknames = all; try save(next); state = next
    }
    /// Adds a contact from a verified QR/link card: pins its keys and marks it verified.
    public func addVerified(_ card: ContactCard) throws {
        try accept(ChatProfile(id: card.id, username: card.username))
        try pin(card.keys, for: card.id)
        var next = state; var all = Set(next.verified ?? []); all.insert(card.id); next.verified = Array(all)
        try save(next); state = next
    }
    /// Trust on first use: the first keys received over an approved direct link are pinned; later changes are refused.
    @discardableResult public func pin(_ keys: PeerKeys, for id: String) throws -> Bool {
        try keys.validate()
        guard profile(for: id) != nil else { throw ProfileError.invalidIdentity }
        if let old = state.keys?[id] { guard old == keys else { throw RelayError.keyMismatch }; return false }
        var next = state; var all = next.keys ?? [:]; all[id] = keys; next.keys = all
        try save(next); state = next; return true
    }
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
        try backend.save(key, try JSONEncoder().encode(next))
    }
}

public struct MeshGroup: Codable, Equatable, Identifiable {
    public let id: String
    public let ownerID: String
    public var name: String
    public var revision: Int
    public var members: [ChatProfile]
    public func validate() throws {
        guard UUID(uuidString: id) != nil, UUID(uuidString: ownerID) != nil, revision > 0,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf16.count <= 60,
              (1...16).contains(members.count), members.contains(where: { $0.id == ownerID }),
              Set(members.map(\.id)).count == members.count else { throw FeatureError.invalidGroup }
        for member in members { _ = try member.validated() }
    }
    public func contains(_ id: String) -> Bool { members.contains { $0.id == id } }
}
public final class GroupBook {
    private struct Entry: Codable { var group: MeshGroup; var audience: [ChatProfile] }
    private let backend: BlobStore
    private let key: String
    private var entries: [Entry]
    public var groups: [MeshGroup] { entries.map(\.group).sorted { $0.name < $1.name } }
    public init(backend: BlobStore, key: String = "groups") throws {
        self.backend = backend; self.key = key
        if let data = try backend.load(key) { entries = try JSONDecoder().decode([Entry].self, from: data) }
        else { entries = [] }
        guard entries.count <= 100, Set(entries.map { $0.group.id }).count == entries.count else { throw FeatureError.invalidGroup }
        for entry in entries {
            try entry.group.validate()
            guard entry.audience.count <= 500, Set(entry.audience.map(\.id)).count == entry.audience.count,
                  entry.group.members.allSatisfy({ member in entry.audience.contains(where: { $0.id == member.id }) }) else { throw FeatureError.invalidGroup }
            for profile in entry.audience { _ = try profile.validated() }
        }
    }
    public func group(_ id: String) -> MeshGroup? { entries.first { $0.group.id == id }?.group }
    public func audience(_ id: String) -> [ChatProfile] { entries.first { $0.group.id == id }?.audience ?? [] }
    public func apply(_ group: MeshGroup, from sender: String) throws {
        try group.validate()
        guard sender == group.ownerID else { throw FeatureError.ownerOnly }
        var next = entries
        if let index = next.firstIndex(where: { $0.group.id == group.id }) {
            let old = next[index]
            guard old.group.ownerID == sender else { throw FeatureError.ownerOnly }
            if group.revision == old.group.revision { guard group == old.group else { throw FeatureError.staleGroup }; return }
            guard group.revision > old.group.revision else { throw FeatureError.staleGroup }
            var audience = old.audience
            for profile in group.members where !audience.contains(where: { $0.id == profile.id }) { audience.append(profile) }
            guard audience.count <= 500 else { throw FeatureError.invalidGroup }
            next[index] = Entry(group: group, audience: audience)
        } else {
            guard next.count < 100 else { throw FeatureError.invalidGroup }
            next.append(Entry(group: group, audience: group.members))
        }
        try backend.save(key, try JSONEncoder().encode(next)); entries = next
    }
    /// Test convenience: a file-backed book at the given path.
    public convenience init(file: URL) throws {
        let backend = try FileBlobStore(directory: file.deletingLastPathComponent())
        try self.init(backend: backend, key: file.deletingPathExtension().lastPathComponent)
    }
    public func permits(_ envelope: Envelope, local: String, peer: String) -> Bool {
        guard let id = envelope.groupID, let group = group(id), envelope.groupRevision == group.revision,
              group.contains(local), group.contains(peer), envelope.sender == peer, envelope.to == local else { return false }
        return envelope.kind == "text" || envelope.kind == "media"
    }
}

public struct MediaDescriptor: Codable, Equatable {
    public let id: String
    public let kind: String
    public let fileExtension: String
    public let bytes: Int64
    public let sha256: String
    public func validate() throws {
        let allowed = kind == "audio" ? ["m4a", "mp3", "aac", "wav", "caf"] : kind == "video" ? ["mp4", "mov", "m4v"] : []
        guard UUID(uuidString: id) != nil, allowed.contains(fileExtension), (1...MediaVault.maxBytes).contains(bytes),
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw FeatureError.invalidMedia }
    }
}
public enum FeatureError: Error, LocalizedError {
    case invalidGroup, ownerOnly, staleGroup, invalidMedia, mediaQuota
    public var errorDescription: String? {
        switch self {
        case .invalidGroup: return "Use a group name up to 60 characters and at most 16 members."
        case .ownerOnly: return "Only the group owner can change membership."
        case .staleGroup: return "Group membership is out of date. Reconnect with the owner."
        case .invalidMedia: return "Choose supported audio or video up to 20 MB."
        case .mediaQuota: return "Media storage limit reached (1 GB)."
        }
    }
}

public final class MediaVault {
    public static let maxBytes: Int64 = 20 * 1024 * 1024
    public static let quota: Int64 = 1024 * 1024 * 1024
    private let directory: URL
    public init(directory: URL) throws { self.directory = directory; try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    /// Total bytes of stored media files, for the Storage settings section.
    public func usage() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        return files.reduce(Int64(0)) { $0 + ((try? size($1)) ?? 0) }
    }
    public func clearAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
    public func url(for media: MediaDescriptor) throws -> URL { try media.validate(); return directory.appendingPathComponent(media.id + "_" + media.sha256 + "." + media.fileExtension) }
    public func available(_ media: MediaDescriptor) -> Bool { guard let url = try? url(for: media), let bytes = try? size(url) else { return false }; return bytes == media.bytes }
    private func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 65536), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func size(_ url: URL) throws -> Int64 { (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0 }
    public func importFile(_ source: URL, kind: String) throws -> MediaDescriptor {
        let bytes = try size(source)
        guard bytes > 0, bytes <= Self.maxBytes else { throw FeatureError.invalidMedia }
        let media = MediaDescriptor(id: UUID().uuidString.lowercased(), kind: kind, fileExtension: source.pathExtension.lowercased(), bytes: bytes, sha256: try digest(source))
        try media.validate(); try install(source, as: media); return media
    }
    public func install(_ source: URL, as media: MediaDescriptor) throws {
        try media.validate()
        guard try size(source) == media.bytes, try digest(source) == media.sha256 else { throw FeatureError.invalidMedia }
        let destination = try url(for: media)
        if available(media) { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let used = try files.reduce(Int64(0)) { try $0 + size($1) }
        guard used + media.bytes <= Self.quota else { throw FeatureError.mediaQuota }
        // A crash must not leave a partial file at a path that appears delivered.
        let staging = directory.appendingPathComponent(".incoming-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        guard try size(staging) == media.bytes, try digest(staging) == media.sha256 else { throw FeatureError.invalidMedia }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: staging, to: destination)
    }
    public func prune(keeping ids: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where !ids.contains(String(file.lastPathComponent.prefix(36))) { try? FileManager.default.removeItem(at: file) }
    }
}
