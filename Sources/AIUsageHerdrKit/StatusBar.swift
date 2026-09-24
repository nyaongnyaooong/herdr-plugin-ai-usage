import Foundation
import AIUsageCore

public enum StatusBar {
    public static func bar(_ percent: Int?) -> String {
        let width = 10
        guard let percent else { return String(repeating: "·", count: width) }
        let clamped = min(max(percent, 0), 100)
        let filled = Int((Double(clamped) / 100 * Double(width)).rounded())
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }

    public static func isConnected(_ provider: ProviderSnapshot?) -> Bool {
        guard let provider, provider.status != .missingAuth else { return false }
        let hasUsage = provider.left.remainingPercent != nil
            || provider.right.remainingPercent != nil
            || provider.api != nil
        if provider.status == .unavailable { return hasUsage }
        return true
    }

    public static func resetText(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MM/dd HH:mm"
        return "reset \(formatter.string(from: date))"
    }

    public static func render(snapshot: UsageSnapshot?, visibleIDs: [ProviderID]) -> String {
        let ids = visibleIDs.isEmpty ? Array(ProviderID.allCases) : visibleIDs
        return ids.compactMap { row(id: $0, provider: snapshot?.provider($0)) }.joined(separator: "\n")
    }

    public static func run() async {
        fputs("\u{1b}]0;ai-usage-status\u{07}\u{1b}[?25l", stdout)
        fflush(stdout)
        while true {
            let frame = render(snapshot: loadSnapshot(), visibleIDs: loadVisibleIDs())
            fputs("\u{1b}[H\u{1b}[J\(frame)", stdout)
            fflush(stdout)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private static let nameWidth = 8
    private static let labelWidth = 8
    private static let valueWidth = 10

    private static func row(id: ProviderID, provider: ProviderSnapshot?) -> String? {
        guard let provider, isConnected(provider) else { return nil }
        var fields: [String] = []
        if let percent = provider.left.remainingPercent {
            fields.append(meter(label: id.menuBarLeftLabel, value: "\(percent)%", percent: percent, resetsAt: provider.left.resetsAt))
        }
        if let percent = provider.right.remainingPercent {
            fields.append(meter(label: id.menuBarRightLabel, value: "\(percent)%", percent: percent, resetsAt: provider.right.resetsAt))
        }
        if fields.isEmpty, let api = provider.api {
            let reset = ClaudeUsageMapper.monthBounds(now: Date()).1
            fields.append(meter(label: "Monthly", value: api.detail, percent: nil, resetsAt: reset, level: .normal))
        }
        guard !fields.isEmpty else { return nil }
        return " \(name(id, pad(id.displayName, nameWidth)))  " + fields.joined(separator: "   ")
    }

    private static func meter(label meterLabel: String, value: String, percent: Int?, resetsAt: Date?, level explicit: MeterColorLevel? = nil) -> String {
        let level = explicit ?? MeterColor.level(remainingPercent: percent)
        let graph = percent.map { paint(bar($0), level: level) } ?? String(repeating: " ", count: 10)
        var text = "\(label(pad(meterLabel, labelWidth)))  \(paint(pad(value, valueWidth), level: level)) \(graph)"
        if let resetsAt {
            text += " \(accent(resetText(resetsAt)))"
        }
        return text
    }

    private static func name(_ id: ProviderID, _ text: String) -> String {
        switch id {
        case .cursor: return fg(text, 196, 167, 231, bold: true)
        case .chatgpt: return fg(text, 156, 207, 216, bold: true)
        case .claude: return fg(text, 235, 188, 186, bold: true)
        }
    }

    private static func label(_ text: String) -> String {
        fg(text, 224, 222, 244)
    }

    private static func accent(_ text: String) -> String {
        fg(text, 246, 193, 119)
    }

    private static func paint(_ text: String, level: MeterColorLevel) -> String {
        switch level {
        case .critical: return fg(text, 235, 111, 146, bold: true)
        case .warning: return fg(text, 246, 193, 119, bold: true)
        case .normal: return fg(text, 156, 207, 142, bold: true)
        }
    }

    private static func fg(_ text: String, _ red: Int, _ green: Int, _ blue: Int, bold: Bool = false) -> String {
        let weight = bold ? "1;" : ""
        return "\u{1b}[\(weight)38;2;\(red);\(green);\(blue)m\(text)\u{1b}[0m"
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        if text.count >= width { return text }
        return text + String(repeating: " ", count: width - text.count)
    }

    private static func loadSnapshot() -> UsageSnapshot? {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsage", isDirectory: true)
        return try? SnapshotStore(directory: directory).load()
    }

    private static func loadVisibleIDs() -> [ProviderID] {
        let defaults = UserDefaults(suiteName: "app.aiusage.AIUsage") ?? .standard
        return ProviderVisibility.ordered(ProviderVisibility.load(from: defaults))
    }
}
