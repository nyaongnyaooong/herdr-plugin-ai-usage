import Foundation

public final class AccountStore: @unchecked Sendable {
    public static let fileName = "accounts.json"

    private let fileURL: URL
    private let lock = NSLock()
    private var records: [ManagedAccount]

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let payload = try? decoder.decode(Payload.self, from: data) {
            records = payload.accounts
        } else {
            records = []
        }
    }

    public func accounts(for provider: ProviderID) -> [ManagedAccount] {
        lock.lock()
        defer { lock.unlock() }
        return records.filter { $0.provider == provider }
    }

    public func allAccounts() -> [ManagedAccount] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    public func active(for provider: ProviderID) -> ManagedAccount? {
        accounts(for: provider).first(where: \.isActive)
    }

    @discardableResult
    public func upsert(
        provider: ProviderID,
        identityKey: String,
        displayName: String,
        planName: String?,
        usage: ProviderSnapshot?
    ) -> AccountUpsertResult {
        lock.lock()
        defer { lock.unlock() }
        if let index = records.firstIndex(where: { $0.provider == provider && $0.identityKey == identityKey }) {
            records[index].displayName = displayName
            records[index].planName = planName
            if let usage {
                records[index].usage = usage
            }
            persistLocked()
            return AccountUpsertResult(account: records[index], isNew: false)
        }
        let existingNames = records.filter { $0.provider == provider }.map(\.displayName)
        let isFirst = existingNames.isEmpty
        let account = ManagedAccount(
            id: UUID(),
            provider: provider,
            identityKey: identityKey,
            displayName: AccountIdentity.uniqueDisplayName(displayName, existing: existingNames),
            planName: planName,
            isActive: isFirst,
            usage: usage
        )
        records.append(account)
        persistLocked()
        return AccountUpsertResult(account: account, isNew: true)
    }

    public func updateUsage(_ usage: ProviderSnapshot, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].usage = usage
        persistLocked()
    }

    public func setActive(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let target = records.first(where: { $0.id == id }) else { return }
        for index in records.indices where records[index].provider == target.provider {
            records[index].isActive = records[index].id == id
        }
        persistLocked()
    }

    public func clearActive(for provider: ProviderID) {
        lock.lock()
        defer { lock.unlock() }
        for index in records.indices where records[index].provider == provider {
            records[index].isActive = false
        }
        persistLocked()
    }

    public func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll { $0.id == id }
        persistLocked()
    }

    private func persistLocked() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Payload(accounts: records)) else { return }
        let temp = fileURL.appendingPathExtension("tmp")
        try? data.write(to: temp, options: .atomic)
        _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: temp)
    }

    private struct Payload: Codable {
        var accounts: [ManagedAccount]
    }
}
