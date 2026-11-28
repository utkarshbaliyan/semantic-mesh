import Foundation
import CryptoKit
import Security

/// A 256-bit symmetric key used to encrypt stored data (message text, frame payloads, contact and
/// group blobs) at rest with ChaCha20-Poly1305. The key lives in the Keychain
/// (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly). When the Keychain is unavailable — as on
/// ad-hoc-signed Mac builds — it falls back to a key file excluded from backups, and reports which.
public final class SecretBox {
    public enum Source: String { case keychain, file }
    public let source: Source
    private let key: SymmetricKey
    private static let service = "org.semanticmesh.apple"
    private static let account = "db-key-v1"

    /// `useKeychain` is false in unit tests so the login Keychain is never touched.
    public init(directory: URL, useKeychain: Bool = true) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keyFile = directory.appendingPathComponent("db-key.bin")
        if useKeychain, let existing = Self.keychainRead() {
            key = SymmetricKey(data: existing); source = .keychain
        } else if useKeychain {
            let fresh = SymmetricKey(size: .bits256)
            if Self.keychainWrite(Data(fresh.rawBytes)) { key = fresh; source = .keychain }
            else { (key, source) = try Self.fileKey(keyFile) }
        } else {
            (key, source) = try Self.fileKey(keyFile)
        }
    }

    private static func fileKey(_ file: URL) throws -> (SymmetricKey, Source) {
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count == 32 else { throw MeshError.invalidEnvelope }
            return (SymmetricKey(data: data), .file)
        }
        let fresh = SymmetricKey(size: .bits256)
        #if os(iOS)
        try Data(fresh.rawBytes).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try Data(fresh.rawBytes).write(to: file, options: .atomic)
        #endif
        var protected = file; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? protected.setResourceValues(values)
        return (fresh, .file)
    }

    public func seal(_ data: Data) throws -> Data { try ChaChaPoly.seal(data, using: key).combined }
    public func open(_ data: Data) throws -> Data { try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: key) }

    private static func keychainRead() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, data.count == 32 else { return nil }
        return data
    }
    private static func keychainWrite(_ data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}

private extension SymmetricKey {
    var rawBytes: [UInt8] { withUnsafeBytes { Array($0) } }
}

/// Persistence backend for the contact and group books: a key→blob map they read and write.
/// Backed by the encrypted database in the app, or by plain files in unit tests.
public protocol BlobStore: AnyObject {
    func load(_ key: String) throws -> Data?
    func save(_ key: String, _ data: Data) throws
}

/// A simple file-backed blob store used by tests and by the one-time JSON migration.
public final class FileBlobStore: BlobStore {
    private let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    private func url(_ key: String) -> URL { directory.appendingPathComponent(key + ".blob") }
    public func load(_ key: String) throws -> Data? {
        let file = url(key)
        return FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
    }
    public func save(_ key: String, _ data: Data) throws {
        try data.write(to: url(key), options: .atomic)
        var protected = url(key); var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? protected.setResourceValues(values)
    }
}
