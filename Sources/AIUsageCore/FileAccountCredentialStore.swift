import Foundation

public final class FileAccountCredentialStore: AccountCredentialStore, @unchecked Sendable {
    public static let fileName = "credentials.json"

    private let fileURL: URL
    private let lock = NSLock()

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName)
    }

    public func save(_ credential: AccountCredential, for id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        var items = loadLocked()
        items[id.uuidString] = credential
        try persistLocked(items)
    }

    public func load(id: UUID) throws -> AccountCredential? {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()[id.uuidString]
    }

    public func delete(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        var items = loadLocked()
        items.removeValue(forKey: id.uuidString)
        try persistLocked(items)
    }

    private func loadLocked() -> [String: AccountCredential] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return [:]
        }
        return payload.credentials
    }

    private func persistLocked(_ items: [String: AccountCredential]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Payload(credentials: items))
        let temp = fileURL.appendingPathExtension("tmp")
        try data.write(to: temp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temp)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private struct Payload: Codable {
        var credentials: [String: AccountCredential]
    }
}
