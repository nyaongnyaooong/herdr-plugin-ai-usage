import CryptoKit
import Foundation

public enum AccountIdentity {
    public static func key(
        provider: ProviderID,
        accountID: String?,
        email: String?,
        token: String
    ) -> String {
        let prefix = provider.rawValue
        if let accountID, !accountID.isEmpty {
            return "\(prefix):id:\(accountID)"
        }
        if let email, !email.isEmpty {
            return "\(prefix):email:\(email.lowercased())"
        }
        return "\(prefix):token:\(fingerprint(token))"
    }

    public static func uniqueDisplayName(_ base: String, existing: [String]) -> String {
        if !existing.contains(base) { return base }
        var index = 2
        while existing.contains("\(base) \(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }

    public static func apiKeyDisplayName(_ key: String) -> String {
        let suffix = String(key.trimmingCharacters(in: .whitespacesAndNewlines).suffix(4))
        return "API 키 · \(suffix)"
    }

    public static func storedDisplayName(
        provider: ProviderID,
        accountLabel: String?,
        planName: String? = nil,
        apiKey: String?,
        hasOAuth: Bool = false
    ) -> String {
        if let accountLabel, !accountLabel.isEmpty { return accountLabel }
        switch provider {
        case .chatgpt:
            return planName.map { "ChatGPT \($0)" } ?? "ChatGPT 계정"
        case .cursor:
            return "Cursor 계정"
        case .claude:
            if hasOAuth { return "Claude 계정" }
            if let apiKey, !apiKey.isEmpty { return apiKeyDisplayName(apiKey) }
            return "Claude 계정"
        }
    }

    public static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
