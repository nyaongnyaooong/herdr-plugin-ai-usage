public enum MenuBarFormatting {
    public static func compact(
        leftLabel: String,
        left: Int?,
        rightLabel: String,
        right: Int?
    ) -> String {
        "\(leftLabel) \(percent(left)) · \(rightLabel) \(percent(right))"
    }

    public static func compactVisible(
        leftLabel: String,
        left: Int?,
        rightLabel: String,
        right: Int?
    ) -> String {
        var parts: [String] = []
        if left != nil {
            parts.append("\(leftLabel) \(percent(left))")
        }
        if right != nil {
            parts.append("\(rightLabel) \(percent(right))")
        }
        if parts.isEmpty {
            return compact(leftLabel: leftLabel, left: left, rightLabel: rightLabel, right: right)
        }
        return parts.joined(separator: " · ")
    }

    public static func tooltip(
        leftLabel: String,
        rightLabel: String,
        left: Int?,
        right: Int?
    ) -> String {
        compactVisible(leftLabel: leftLabel, left: left, rightLabel: rightLabel, right: right)
    }

    public static func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "—"
    }
}
