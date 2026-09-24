import Foundation

public final class RefreshGate: @unchecked Sendable {
    public static let minimumInterval: TimeInterval = 60
    public static let lastStartedKey = "lastNetworkStartedAt"

    private let defaults: UserDefaults
    private let now: () -> Date

    public init(defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    public var lastNetworkStartedAt: Date? {
        let interval = defaults.double(forKey: Self.lastStartedKey)
        guard interval > 0 else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    public func shouldStartNetwork() -> Bool {
        guard let last = lastNetworkStartedAt else { return true }
        return now().timeIntervalSince(last) >= Self.minimumInterval
    }

    public func markNetworkStarted() {
        defaults.set(now().timeIntervalSince1970, forKey: Self.lastStartedKey)
    }
}
