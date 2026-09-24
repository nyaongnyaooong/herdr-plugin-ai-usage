import Foundation

public enum SnapshotFreshness {
    public static let maxAge: TimeInterval = 4 * 60

    public static func isFresh(_ snapshot: UsageSnapshot, now: Date, maxAge: TimeInterval = maxAge) -> Bool {
        now.timeIntervalSince(snapshot.fetchedAt) < maxAge
    }
}
