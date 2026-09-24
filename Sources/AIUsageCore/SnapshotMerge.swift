import Foundation

public enum SnapshotMerge {
    public static func provider(previous: ProviderSnapshot?, incoming: ProviderSnapshot) -> ProviderSnapshot {
        guard let previous, hasMeters(previous) else { return incoming }
        switch incoming.status {
        case .ok:
            return incoming
        case .missingAuth, .rateLimited, .unavailable:
            var merged = incoming
            merged.left.remainingPercent = previous.left.remainingPercent
            merged.right.remainingPercent = previous.right.remainingPercent
            merged.left.resetsAt = previous.left.resetsAt
            merged.right.resetsAt = previous.right.resetsAt
            merged.api = incoming.api ?? previous.api
            merged.planName = incoming.planName ?? previous.planName
            return merged
        }
    }

    private static func hasMeters(_ snapshot: ProviderSnapshot) -> Bool {
        snapshot.left.remainingPercent != nil || snapshot.right.remainingPercent != nil
    }
}
