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
