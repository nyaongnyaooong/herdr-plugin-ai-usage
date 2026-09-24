public enum RemainingPercent {
    public static func remaining(used: Double) -> Int {
        let value = 100.0 - used
        if value < 0 { return 0 }
        if value > 100 { return 100 }
        return Int((value).rounded())
    }
}
