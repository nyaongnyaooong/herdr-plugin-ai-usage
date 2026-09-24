import Foundation

public enum ClaudeAPIKeyReader {
    public static func read(environment: [String: String], home: URL) -> String? {
        if let value = cleaned(environment["ANTHROPIC_API_KEY"]) {
            return value
        }
        return cleaned(ShellEnvKeyParser.parseHomeFiles(home: home, key: "ANTHROPIC_API_KEY"))
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
