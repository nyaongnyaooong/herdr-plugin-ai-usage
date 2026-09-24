import Foundation

public struct RefreshDependencies: Sendable {
    public var gate: RefreshGate
    public var store: SnapshotStore
    public var cooldown: ProviderCooldown
    public var now: @Sendable () -> Date
    public var fetchCursor: @Sendable () async -> ProviderSnapshot
    public var fetchChatGPT: @Sendable () async -> ProviderSnapshot
    public var fetchClaude: @Sendable () async -> ProviderSnapshot

    public init(
        gate: RefreshGate,
        store: SnapshotStore,
        cooldown: ProviderCooldown,
        now: @escaping @Sendable () -> Date,
        fetchCursor: @escaping @Sendable () async -> ProviderSnapshot,
        fetchChatGPT: @escaping @Sendable () async -> ProviderSnapshot,
        fetchClaude: @escaping @Sendable () async -> ProviderSnapshot
    ) {
        self.gate = gate
        self.store = store
        self.cooldown = cooldown
        self.now = now
        self.fetchCursor = fetchCursor
        self.fetchChatGPT = fetchChatGPT
        self.fetchClaude = fetchClaude
    }
}

public final class RefreshCoordinator: @unchecked Sendable {
    private let dependencies: RefreshDependencies

    public init(dependencies: RefreshDependencies) {
        self.dependencies = dependencies
    }

    public func refresh(forceNetwork: Bool = false) async -> UsageSnapshot {
        let cached = try? dependencies.store.load()
        if !forceNetwork, let cached, SnapshotFreshness.isFresh(cached, now: dependencies.now()) {
            return cached
        }
        if !dependencies.gate.shouldStartNetwork(), let cached {
            return cached
        }
        dependencies.gate.markNetworkStarted()
        let previous = cached
        async let cursor = fetch(.cursor, previous: previous, work: dependencies.fetchCursor)
        async let chatgpt = fetch(.chatgpt, previous: previous, work: dependencies.fetchChatGPT)
        async let claude = fetch(.claude, previous: previous, work: dependencies.fetchClaude)
        let providers = await [cursor, chatgpt, claude]
        let snapshot = UsageSnapshot(
            fetchedAt: dependencies.now(),
            lastNetworkStartedAt: dependencies.now(),
            providers: providers
        )
        try? dependencies.store.save(snapshot)
        return snapshot
    }

    private func fetch(
        _ id: ProviderID,
        previous: UsageSnapshot?,
        work: @escaping @Sendable () async -> ProviderSnapshot
    ) async -> ProviderSnapshot {
        let prior = previous?.provider(id)
        if dependencies.cooldown.isCoolingDown(id), let prior {
            return prior
        }
        let incoming = await work()
        if incoming.status == .rateLimited {
            dependencies.cooldown.markRateLimited(id)
        }
        return SnapshotMerge.provider(previous: prior, incoming: incoming)
    }
}
