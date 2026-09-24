import Foundation

public enum ClaudeCLIUsageReader {
    public static func monthlyMeter(now: Date, projectRoots: [URL], calendar: Calendar = .current) -> APIMeter? {
        let usd = monthlyUSD(now: now, projectRoots: projectRoots, calendar: calendar)
        guard let usd else { return nil }
        return APIMeter(label: "Monthly", detail: ClaudeUsageMapper.formatUSD(usd))
    }

    public static func monthlyUSD(now: Date, projectRoots: [URL], calendar: Calendar = .current) -> Double? {
        let (start, _) = ClaudeUsageMapper.monthBounds(now: now, calendar: calendar)
        var total = 0.0
        var counted = 0
        var seen = Set<String>()
        for root in projectRoots {
            enumerateJSONL(in: root, monthStart: start) { line in
                guard let usd = cost(fromLine: line, monthStart: start, seen: &seen) else { return }
                total += usd
                counted += 1
            }
        }
        guard counted > 0 else { return nil }
        return total
    }

    private static func enumerateJSONL(in root: URL, monthStart: Date, body: (String) -> Void) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]) {
                if values.isRegularFile == false { continue }
                if let modified = values.contentModificationDate, modified < monthStart { continue }
            }
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in contents.split(whereSeparator: \.isNewline) where !line.isEmpty {
                body(String(line))
            }
        }
    }

    private static func cost(fromLine line: String, monthStart: Date, seen: inout Set<String>) -> Double? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "assistant",
              json["isApiErrorMessage"] as? Bool != true,
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return nil
        }
        let model = (message["model"] as? String) ?? (json["model"] as? String) ?? ""
        guard ClaudeModelPricing.rates(for: model) != nil else { return nil }
        guard let timestamp = parseISO(json["timestamp"] as? String), timestamp >= monthStart else { return nil }
        let id = (message["id"] as? String) ?? (json["uuid"] as? String)
        if let id {
            if seen.contains(id) { return nil }
            seen.insert(id)
        }
        return ClaudeModelPricing.usd(model: model, tokens: tokens(from: usage))
    }

    private static func tokens(from usage: [String: Any]) -> ClaudeUsageTokens {
        let cache = usage["cache_creation"] as? [String: Any]
        let write5 = number(cache?["ephemeral_5m_input_tokens"])
        let write1h = number(cache?["ephemeral_1h_input_tokens"])
        let totalWrite = number(usage["cache_creation_input_tokens"])
        return ClaudeUsageTokens(
            input: number(usage["input_tokens"]),
            output: number(usage["output_tokens"]),
            cacheRead: number(usage["cache_read_input_tokens"]),
            cacheWrite5m: write5 > 0 || write1h > 0 ? write5 : totalWrite,
            cacheWrite1h: write1h
        )
    }

    private static func number(_ value: Any?) -> Double {
        if let n = value as? NSNumber { return n.doubleValue }
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? String { return Double(n) ?? 0 }
        return 0
    }

    private static func parseISO(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: raw)
    }
}
