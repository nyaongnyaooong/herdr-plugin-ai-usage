import Foundation

public enum ShellEnvKeyParser {
    public static func parse(contents: String, key: String) -> String? {
        let pattern = "^(?:export[[:space:]]+)?" + NSRegularExpression.escapedPattern(for: key) + "=(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let ns = contents as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: contents, range: full) else { return nil }
        var value = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    public static func parseFile(at url: URL, key: String) -> String? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(contents: contents, key: key)
    }

    public static func parseHomeFiles(home: URL, key: String, names: [String] = [".zshenv", ".zprofile", ".zshrc"]) -> String? {
        for name in names {
            if let value = parseFile(at: home.appendingPathComponent(name), key: key) {
                return value
            }
        }
        return nil
    }
}
