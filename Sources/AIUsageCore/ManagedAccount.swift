import Foundation

public struct ManagedAccount: Codable, Equatable, Identifiable {
    public var id: UUID
    public var provider: ProviderID
    public var identityKey: String
    public var displayName: String
    public var planName: String?
    public var isActive: Bool
    public var usage: ProviderSnapshot?

    public init(
        id: UUID,
        provider: ProviderID,
        identityKey: String,
        displayName: String,
        planName: String? = nil,
        isActive: Bool,
        usage: ProviderSnapshot? = nil
    ) {
        self.id = id
        self.provider = provider
        self.identityKey = identityKey
        self.displayName = displayName
        self.planName = planName
        self.isActive = isActive
        self.usage = usage
    }
}

public struct AccountUpsertResult: Equatable {
    public var account: ManagedAccount
    public var isNew: Bool
}

public enum AccountSelection {
    public static func menuBarSnapshot(accounts: [ManagedAccount], live: ProviderSnapshot) -> ProviderSnapshot {
        if let active = accounts.first(where: \.isActive), let usage = active.usage {
            return usage
        }
        return live
    }
}

public struct AccountCredential: Codable, Equatable, Sendable {
    public var accessToken: String
    public var accountID: String?
    public var apiKey: String?

    public var oauthToken: String? {
        accessToken.isEmpty ? nil : accessToken
    }

    public var secretForIdentity: String? {
        oauthToken ?? nonempty(apiKey)
    }

    public init(accessToken: String, accountID: String? = nil, apiKey: String? = nil) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.apiKey = nonempty(apiKey)
    }
}

private func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

public protocol AccountCredentialStore: Sendable {
    func save(_ credential: AccountCredential, for id: UUID) throws
    func load(id: UUID) throws -> AccountCredential?
    func delete(id: UUID) throws
}

public final class MemoryCredentialStore: AccountCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: AccountCredential] = [:]

    public init() {}

    public func save(_ credential: AccountCredential, for id: UUID) throws {
        lock.lock()
        items[id] = credential
        lock.unlock()
    }

    public func load(id: UUID) throws -> AccountCredential? {
        lock.lock()
        defer { lock.unlock() }
        return items[id]
    }

    public func delete(id: UUID) throws {
        lock.lock()
        items[id] = nil
        lock.unlock()
    }
}
