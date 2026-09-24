import Foundation

public enum ClaudeUsageMapper {
    public static func map(_ data: Data) throws -> ProviderSnapshot {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return ProviderSnapshot(
            id: .claude,
            displayName: "Claude",
            status: .ok,
            left: meter(label: ProviderID.claude.leftLabel, window: json["five_hour"] as? [String: Any]),
            right: meter(label: ProviderID.claude.rightLabel, window: json["seven_day"] as? [String: Any])
        )
    }

    public static func monthlyCost(_ data: Data) -> APIMeter? {
        guard let usd = monthlyUSD(data) else { return nil }
        return APIMeter(label: "Monthly", detail: formatUSD(usd))
    }

    public static func monthlyUSD(_ data: Data) -> Double? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = json["data"] as? [[String: Any]] else {
            return nil
        }
        var cents = 0.0
        var sawAmount = false
        for bucket in buckets {
            let results = bucket["results"] as? [[String: Any]] ?? []
            for item in results {
                if let amount = number(item["amount"]) {
                    cents += amount
                    sawAmount = true
                }
            }
        }
        guard sawAmount || json["data"] != nil else { return nil }
        return cents / 100.0
    }

    public static func formatUSD(_ dollars: Double) -> String {
        String(format: "$%.2f", dollars)
    }

    public static func monthBounds(now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> (Date, Date) {
        var calendar = calendar
        calendar.timeZone = TimeZone.current
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? now
        return (start, end)
    }

    private static func meter(label: String, window: [String: Any]?) -> Meter {
        let used = number(window?["utilization"])
        let resets = parseISO(window?["resets_at"] as? String)
        return Meter(label: label, remainingPercent: used.map(RemainingPercent.remaining), resetsAt: resets)
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? String { return Double(n) }
        return nil
    }

    private static func parseISO(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
