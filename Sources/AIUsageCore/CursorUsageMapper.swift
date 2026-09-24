import Foundation

public enum CursorUsageMapper {
    public static func mapPeriod(_ data: Data) throws -> ProviderSnapshot {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let plan = json["planUsage"] as? [String: Any]
            ?? (json["individualUsage"] as? [String: Any])?["plan"] as? [String: Any]
        let autoUsed = double(plan?["autoPercentUsed"])
        let apiUsed = double(plan?["apiPercentUsed"])
        let end = parseTimestamp(json["billingCycleEnd"])
            ?? parseTimestamp(json["billing_cycle_end"])
            ?? parseTimestamp((json["planInfo"] as? [String: Any])?["billingCycleEnd"])
            ?? nextMonth(from: parseTimestamp(json["billingCycleStart"]))
        return ProviderSnapshot(
            id: .cursor,
            displayName: "Cursor",
            status: .ok,
            left: Meter(label: ProviderID.cursor.leftLabel, remainingPercent: autoUsed.map(RemainingPercent.remaining), resetsAt: end),
            right: Meter(label: ProviderID.cursor.rightLabel, remainingPercent: apiUsed.map(RemainingPercent.remaining), resetsAt: end)
        )
    }

    public static func mapAuthUsage(_ data: Data) throws -> ProviderSnapshot {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let bucket = json["gpt-4"] as? [String: Any]
        let used = double(bucket?["numRequests"])
        let max = double(bucket?["maxRequestUsage"])
        var remaining: Int?
        if let used, let max, max > 0 {
            remaining = RemainingPercent.remaining(used: (used / max) * 100)
        }
        let end = parseTimestamp(json["billingCycleEnd"])
            ?? nextMonth(from: parseTimestamp(json["startOfMonth"]))
        return ProviderSnapshot(
            id: .cursor,
            displayName: "Cursor",
            status: .ok,
            left: Meter(label: ProviderID.cursor.leftLabel, remainingPercent: remaining, resetsAt: end),
            right: Meter(label: ProviderID.cursor.rightLabel, resetsAt: end)
        )
    }

    private static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? String { return Double(n) }
        return nil
    }

    static func parseTimestamp(_ value: Any?) -> Date? {
        if let dict = value as? [String: Any], let seconds = double(dict["seconds"]) {
            let nanos = double(dict["nanos"]) ?? 0
            return Date(timeIntervalSince1970: seconds + nanos / 1_000_000_000)
        }
        if let raw = value as? String {
            if let iso = parseISO(raw) { return iso }
            if let n = Double(raw) { return date(fromEpoch: n) }
            return nil
        }
        if let n = double(value) {
            return date(fromEpoch: n)
        }
        return nil
    }

    private static func date(fromEpoch value: Double) -> Date {
        let seconds = value > 10_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func nextMonth(from start: Date?) -> Date? {
        guard let start else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(byAdding: .month, value: 1, to: start)
    }

    private static func parseISO(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
