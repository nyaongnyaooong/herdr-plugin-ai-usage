import Foundation

public struct ClaudeUsageTokens: Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double

    public init(
        input: Double = 0,
        output: Double = 0,
        cacheRead: Double = 0,
        cacheWrite5m: Double = 0,
        cacheWrite1h: Double = 0
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }
}

public enum ClaudeModelPricing {
    private static let million = 1_000_000.0

    public static func usd(model: String, tokens: ClaudeUsageTokens) -> Double {
        guard let rates = rates(for: model) else { return 0 }
        return tokens.input / million * rates.input
            + tokens.output / million * rates.output
            + tokens.cacheRead / million * rates.cacheRead
            + tokens.cacheWrite5m / million * rates.cacheWrite5m
            + tokens.cacheWrite1h / million * rates.cacheWrite1h
    }

    public static func rates(for model: String) -> (input: Double, output: Double, cacheRead: Double, cacheWrite5m: Double, cacheWrite1h: Double)? {
        let lower = model.lowercased()
        if lower.contains("synthetic") { return nil }
        if lower.contains("opus") {
            return (5, 25, 0.50, 6.25, 10)
        }
        if lower.contains("sonnet") {
            return (2, 10, 0.20, 2.50, 4)
        }
        if lower.contains("haiku") {
            return (1, 5, 0.10, 1.25, 2)
        }
        return (2, 10, 0.20, 2.50, 4)
    }
}
