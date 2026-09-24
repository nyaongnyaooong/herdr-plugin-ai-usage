import Foundation

public enum ChatGPTUsageMapper {
    private static let daySeconds: Double = 86_400

    public static func map(_ data: Data) throws -> ProviderSnapshot {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let rate = json["rate_limit"] as? [String: Any]
        let primary = dictionary(rate?["primary_window"]) ?? dictionary(json["primary"])
        let secondary = dictionary(rate?["secondary_window"]) ?? dictionary(json["secondary"])
        let (shortWindow, longWindow) = classify(primary: primary, secondary: secondary)
        let plan = string(json["planType"]) ?? string(json["plan_type"])
        let email = string(json["email"])
        return ProviderSnapshot(
            id: .chatgpt,
            displayName: "ChatGPT",
            planName: plan,
            status: .ok,
            left: meter(label: ProviderID.chatgpt.leftLabel, window: shortWindow),
            right: meter(label: ProviderID.chatgpt.rightLabel, window: longWindow),
            accountLabel: email
        )
    }

    private static func classify(
        primary: [String: Any]?,
        secondary: [String: Any]?
    ) -> ([String: Any]?, [String: Any]?) {
        let windows = [primary, secondary].compactMap { $0 }
        let short = windows.filter(isShortWindow)
        let long = windows.filter(isLongWindow)
        if short.isEmpty && long.isEmpty {
            return (primary, secondary)
        }
        return (short.first, long.first)
    }

    private static func isShortWindow(_ window: [String: Any]) -> Bool {
        guard let seconds = windowSeconds(window) else { return false }
        return seconds < daySeconds
    }

    private static func isLongWindow(_ window: [String: Any]) -> Bool {
        guard let seconds = windowSeconds(window) else { return false }
        return seconds >= daySeconds
    }

    private static func windowSeconds(_ window: [String: Any]) -> Double? {
        number(window["limit_window_seconds"]) ?? number(window["limitWindowSeconds"])
    }

    private static func meter(label: String, window: [String: Any]?) -> Meter {
        let used = number(window?["used_percent"]) ?? number(window?["usedPercent"])
        let reset = unix(window?["reset_at"]) ?? unix(window?["resetsAt"])
        return Meter(label: label, remainingPercent: used.map(RemainingPercent.remaining), resetsAt: reset)
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        return nil
    }

    private static func unix(_ value: Any?) -> Date? {
        guard let n = number(value) else { return nil }
        return Date(timeIntervalSince1970: n)
    }
}
