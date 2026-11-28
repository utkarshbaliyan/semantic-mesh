import Foundation
import SQLite3

/// SQLite wants to copy bound text/blobs rather than hold our pointers.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One encrypted SQLite database holding messages, receipts, relay frames and the contact/group blobs.
/// Stored payloads are sealed with the `SecretBox` key; routing columns are kept in the clear for queries.
public final class MeshDatabase {
    let handle: OpaquePointer
    public let secret: SecretBox
    public init(file: URL, secret: SecretBox) throws {
        self.secret = secret
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var h: OpaquePointer?
        guard sqlite3_open_v2(file.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let h else {
            throw MeshError.storeFull
        }
        handle = h
        sqlite3_busy_timeout(handle, 3000)
        try exec("PRAGMA journal_mode=WAL;")
        try exec("CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY, kind TEXT NOT NULL, sender TEXT NOT NULL, recipient TEXT, group_id TEXT, created INTEGER NOT NULL, expires INTEGER NOT NULL, payload BLOB NOT NULL);")
        try exec("CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(group_id, sender, recipient);")
        try exec("CREATE TABLE IF NOT EXISTS frames(id TEXT PRIMARY KEY, frm TEXT NOT NULL, dst TEXT NOT NULL, created INTEGER NOT NULL, expires INTEGER NOT NULL, bytes INTEGER NOT NULL, payload BLOB NOT NULL);")
        try exec("CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value BLOB NOT NULL);")
        var f = file; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? f.setResourceValues(values)
    }
    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw MeshError.storeFull }
    }
    func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw MeshError.storeFull }
        return stmt
    }
    func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, index) }
    }
    func bindBlob(_ stmt: OpaquePointer, _ index: Int32, _ value: Data) {
        value.withUnsafeBytes { raw in _ = sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(value.count), SQLITE_TRANSIENT) }
    }
    func blobColumn(_ stmt: OpaquePointer, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
    }

    public func kvGet(_ key: String) throws -> Data? {
        let stmt = try prepare("SELECT value FROM kv WHERE key=?;"); defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW, let sealed = blobColumn(stmt, 0) else { return nil }
        return try secret.open(sealed)
    }
    public func kvSet(_ key: String, _ data: Data) throws {
        let sealed = try secret.seal(data)
        let stmt = try prepare("INSERT OR REPLACE INTO kv(key, value) VALUES(?, ?);"); defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key); bindBlob(stmt, 2, sealed)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw MeshError.storeFull }
    }
}

/// Lets ContactBook and GroupBook persist their JSON state as an encrypted blob in the database.
public final class DatabaseBlobStore: BlobStore {
    private let db: MeshDatabase
    public init(_ db: MeshDatabase) { self.db = db }
    public func load(_ key: String) throws -> Data? { try db.kvGet(key) }
    public func save(_ key: String, _ data: Data) throws { try db.kvSet(key, data) }
}

/// Durable message and receipt store. History is kept until the user deletes it or a chat's disappearing
/// timer removes it; `active(now:)` is the delivery set (not yet expired) the mesh engine relays and dedups.
public final class MessageStore {
    public static let capacity = 20_000
    private let db: MeshDatabase
    public init(database: MeshDatabase) { self.db = database }
    /// Test/migration convenience: opens a private database at `file` with a file-based key (no Keychain).
    public convenience init(file: URL) throws {
        let secret = try SecretBox(directory: file.deletingLastPathComponent(), useKeychain: false)
        self.init(database: try MeshDatabase(file: file, secret: secret))
    }
    private func decode(_ blob: Data) throws -> Envelope { try JSONDecoder().decode(Envelope.self, from: db.secret.open(blob)) }

    @discardableResult public func insert(_ envelope: Envelope, now: Int64 = Envelope.now()) throws -> Bool {
        try envelope.validate(now: now)
        guard envelope.expires > now else { return false }
        if contains(envelope.id) { return false }
        enforceCapacity()
        let sealed = try db.secret.seal(try envelope.encoded())
        let stmt = try db.prepare("INSERT INTO messages(id, kind, sender, recipient, group_id, created, expires, payload) VALUES(?,?,?,?,?,?,?,?);")
        defer { sqlite3_finalize(stmt) }
        db.bindText(stmt, 1, envelope.id); db.bindText(stmt, 2, envelope.kind); db.bindText(stmt, 3, envelope.sender)
        db.bindText(stmt, 4, envelope.to); db.bindText(stmt, 5, envelope.groupID)
        sqlite3_bind_int64(stmt, 6, envelope.created); sqlite3_bind_int64(stmt, 7, envelope.expires)
        db.bindBlob(stmt, 8, sealed)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw MeshError.storeFull }
        return true
    }
    public func contains(_ id: String) -> Bool {
        guard let stmt = try? db.prepare("SELECT 1 FROM messages WHERE id=?;") else { return false }
        defer { sqlite3_finalize(stmt) }
        db.bindText(stmt, 1, id)
        return sqlite3_step(stmt) == SQLITE_ROW
    }
    private func query(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }) -> [Envelope] {
        guard let stmt = try? db.prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var out: [Envelope] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let blob = db.blobColumn(stmt, 0), let e = try? decode(blob) { out.append(e) } }
        return out
    }
    /// The delivery set: messages still within their lifetime. Used by the engine for relay, dedup and receipts.
    public func active(now: Int64 = Envelope.now()) -> [Envelope] {
        query("SELECT payload FROM messages WHERE expires>? ORDER BY rowid;") { sqlite3_bind_int64($0, 1, now) }
    }
    /// All retained messages, for showing chat history beyond the delivery lifetime.
    public func stored() -> [Envelope] { query("SELECT payload FROM messages ORDER BY rowid;") }

    public func delete(ids: [String]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let stmt = try? db.prepare("DELETE FROM messages WHERE id=?;") else { continue }
            db.bindText(stmt, 1, id); sqlite3_step(stmt); sqlite3_finalize(stmt)
        }
    }
    public func deleteDirect(_ a: String, _ b: String) {
        guard let stmt = try? db.prepare("DELETE FROM messages WHERE group_id IS NULL AND ((sender=? AND recipient=?) OR (sender=? AND recipient=?));") else { return }
        defer { sqlite3_finalize(stmt) }
        db.bindText(stmt, 1, a); db.bindText(stmt, 2, b); db.bindText(stmt, 3, b); db.bindText(stmt, 4, a)
        sqlite3_step(stmt)
    }
    public func deleteGroup(_ id: String) {
        guard let stmt = try? db.prepare("DELETE FROM messages WHERE group_id=?;") else { return }
        defer { sqlite3_finalize(stmt) }
        db.bindText(stmt, 1, id); sqlite3_step(stmt)
    }
    public func messageCount() -> Int {
        guard let stmt = try? db.prepare("SELECT COUNT(*) FROM messages;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }
    /// Disappearing retention per chat key (e.g. "c:<id>" / "g:<id>"), in milliseconds (0 = off).
    public func disappearing() -> [String: Int64] {
        guard let data = try? db.kvGet("disappearing"), let map = try? JSONDecoder().decode([String: Int64].self, from: data) else { return [:] }
        return map
    }
    public func setDisappearing(_ map: [String: Int64]) throws {
        try db.kvSet("disappearing", try JSONEncoder().encode(map))
    }
    private func enforceCapacity() {
        guard messageCount() >= Self.capacity else { return }
        try? db.exec("DELETE FROM messages WHERE id IN (SELECT id FROM messages ORDER BY rowid ASC LIMIT \(Self.capacity / 20));")
    }
}

/// Persistent store of sealed frames carried for the mesh, including this device's own outgoing frames.
/// Capped at 2,000 frames and 50 MB; when full it evicts the oldest frames carried for others, never
/// this device's own undelivered frames or frames addressed to it.
public final class RelayStore {
    public static let capacity = 2_000
    public static let maxBytes: Int64 = 50 * 1024 * 1024
    private let db: MeshDatabase
    public init(database: MeshDatabase) { self.db = database }
    public convenience init(file: URL) throws {
        let secret = try SecretBox(directory: file.deletingLastPathComponent(), useKeychain: false)
        self.init(database: try MeshDatabase(file: file, secret: secret))
    }
    private func decode(_ blob: Data) throws -> SealedFrame { try JSONDecoder().decode(SealedFrame.self, from: db.secret.open(blob)) }

    public func active(now: Int64 = Envelope.now()) -> [SealedFrame] {
        guard let stmt = try? db.prepare("SELECT payload FROM frames WHERE expires>? ORDER BY rowid;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, now)
        var out: [SealedFrame] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let blob = db.blobColumn(stmt, 0), let f = try? decode(blob) { out.append(f) } }
        return out
    }
    public func contains(_ id: String) -> Bool {
        guard let stmt = try? db.prepare("SELECT 1 FROM frames WHERE id=?;") else { return false }
        defer { sqlite3_finalize(stmt) }
        db.bindText(stmt, 1, id)
        return sqlite3_step(stmt) == SQLITE_ROW
    }
    private func counts(now: Int64) -> (count: Int, bytes: Int64) {
        guard let stmt = try? db.prepare("SELECT COUNT(*), COALESCE(SUM(bytes),0) FROM frames WHERE expires>?;") else { return (0, 0) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, now)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
        return (Int(sqlite3_column_int64(stmt, 0)), sqlite3_column_int64(stmt, 1))
    }
    public func usage(now: Int64 = Envelope.now()) -> (count: Int, bytes: Int64) { counts(now: now) }

    /// Evicts the oldest frame that is only carried for others. Returns false when none can be freed.
    private func evictOldestCarried(local: String) -> Bool {
        guard let stmt = try? db.prepare("DELETE FROM frames WHERE id=(SELECT id FROM frames WHERE frm<>? AND dst<>? ORDER BY created ASC, rowid ASC LIMIT 1);") else { return false }
        defer { sqlite3_finalize(stmt) }
        db.bindText(stmt, 1, local); db.bindText(stmt, 2, local)
        return sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db.handle) > 0
    }
    @discardableResult public func insert(_ frame: SealedFrame, local: String, now: Int64 = Envelope.now()) throws -> Bool {
        try frame.validate(now: now)
        guard frame.expires > now else { return false }
        guard !contains(frame.id) else { return false }
        let bytes = Int64(try frame.encoded().count)
        while true {
            let (count, used) = counts(now: now)
            if count < Self.capacity && used + bytes <= Self.maxBytes { break }
            guard evictOldestCarried(local: local) else { throw MeshError.storeFull }
        }
        let sealed = try db.secret.seal(try frame.encoded())
        let stmt = try db.prepare("INSERT INTO frames(id, frm, dst, created, expires, bytes, payload) VALUES(?,?,?,?,?,?,?);")
        defer { sqlite3_finalize(stmt) }
        db.bindText(stmt, 1, frame.id); db.bindText(stmt, 2, frame.from); db.bindText(stmt, 3, frame.to)
        sqlite3_bind_int64(stmt, 4, frame.created); sqlite3_bind_int64(stmt, 5, frame.expires); sqlite3_bind_int64(stmt, 6, bytes)
        db.bindBlob(stmt, 7, sealed)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw MeshError.storeFull }
        return true
    }
    /// Drops every frame carried only for others (the "clear relay cache" action).
    public func clearCarried(local: String) {
        guard let stmt = try? db.prepare("DELETE FROM frames WHERE frm<>? AND dst<>?;") else { return }
        defer { sqlite3_finalize(stmt) }
        db.bindText(stmt, 1, local); db.bindText(stmt, 2, local); sqlite3_step(stmt)
    }
}
