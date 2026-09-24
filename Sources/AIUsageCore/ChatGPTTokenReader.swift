import Foundation

public struct ChatGPTAuth: Equatable, Sendable {
    public var accessToken: String
    public var accountID: String?

    public init(accessToken: String, accountID: String? = nil) {
        self.accessToken = accessToken
        self.accountID = accountID
    }
}

public struct ChatGPTTokenReader: Sendable {
    private let authFileURL: URL

    public init(authFileURL: URL) {
        self.authFileURL = authFileURL
    }

    public func readAccessToken() throws -> ChatGPTAuth? {
        guard FileManager.default.fileExists(atPath: authFileURL.path) else { return nil }
        let data = try Data(contentsOf: authFileURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tokens = json["tokens"] as? [String: Any]
        let token = (tokens?["access_token"] as? String) ?? (json["access_token"] as? String)
        guard let token, !token.isEmpty else { return nil }
        let account = tokens?["account_id"] as? String
        return ChatGPTAuth(accessToken: token, accountID: account)
    }

    public func clearLocalSession() throws {
        guard FileManager.default.fileExists(atPath: authFileURL.path) else { return }
        let data = try Data(contentsOf: authFileURL)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if var tokens = json["tokens"] as? [String: Any] {
            tokens.removeValue(forKey: "access_token")
            tokens.removeValue(forKey: "refresh_token")
            tokens.removeValue(forKey: "id_token")
            tokens.removeValue(forKey: "account_id")
            json["tokens"] = tokens.isEmpty ? nil : tokens
        }
        json.removeValue(forKey: "access_token")
        json.removeValue(forKey: "refresh_token")
        json.removeValue(forKey: "id_token")
        let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let temp = authFileURL.appendingPathExtension("tmp")
        try output.write(to: temp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(authFileURL, withItemAt: temp)
    }
}
