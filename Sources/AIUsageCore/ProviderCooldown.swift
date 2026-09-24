import Foundation

public final class ProviderCooldown: @unchecked Sendable {
    public static let interval: TimeInterval = 300
    private let defaults: UserDefaults
    private let now: () -> Date

    public init(defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    public func isCoolingDown(_ id: ProviderID) -> Bool {
        let stamp = defaults.double(forKey: key(id))
        guard stamp > 0 else { return false }
        return now().timeIntervalSince1970 - stamp < Self.interval
    }

    public func markRateLimited(_ id: ProviderID) {
        defaults.set(now().timeIntervalSince1970, forKey: key(id))
    }

    private func key(_ id: ProviderID) -> String {
        "rateLimitedAt.\(id.rawValue)"
    }
}
