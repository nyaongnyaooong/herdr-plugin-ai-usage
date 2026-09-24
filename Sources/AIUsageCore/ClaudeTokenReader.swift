import Foundation

public struct ClaudeTokenReader: Sendable {
    private let credentialsFileURL: URL

    public init(credentialsFileURL: URL) {
        self.credentialsFileURL = credentialsFileURL
    }

    public func readAccessToken() throws -> String? {
        guard FileManager.default.fileExists(atPath: credentialsFileURL.path) else { return nil }
        let raw = try String(contentsOf: credentialsFileURL, encoding: .utf8)
        return extract(from: raw)
    }

    public func clearLocalSession() throws {
        guard FileManager.default.fileExists(atPath: credentialsFileURL.path) else { return }
        let data = try Data(contentsOf: credentialsFileURL)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json.removeValue(forKey: "claudeAiOauth")
        let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let temp = credentialsFileURL.appendingPathExtension("tmp")
        try output.write(to: temp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(credentialsFileURL, withItemAt: temp)
    }

    private func extract(from raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else { return nil }
        return token
    }
}
