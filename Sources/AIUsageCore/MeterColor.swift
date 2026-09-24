public enum MeterColorLevel: Equatable {
    case normal
    case warning
    case critical
}

public enum MeterColor {
    public static func level(remainingPercent: Int?) -> MeterColorLevel {
        guard let remainingPercent else { return .normal }
        if remainingPercent <= 10 { return .critical }
        if remainingPercent <= 20 { return .warning }
        return .normal
    }
}
