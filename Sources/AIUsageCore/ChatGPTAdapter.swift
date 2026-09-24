import Foundation

public struct ChatGPTAdapter: Sendable {
    private let client: HTTPClient
    private let fallback: (@Sendable () async throws -> Data)?

    public init(client: HTTPClient, fallback: (@Sendable () async throws -> Data)? = nil) {
        self.client = client
        self.fallback = fallback
    }

    public func fetch(auth: ChatGPTAuth?) async -> ProviderSnapshot {
        let empty = ProviderSnapshot.empty(id: .chatgpt, displayName: ProviderID.chatgpt.displayName, leftLabel: ProviderID.chatgpt.leftLabel, rightLabel: ProviderID.chatgpt.rightLabel)
        guard let auth else {
            return tagged(empty, status: .missingAuth, message: "ChatGPT 또는 Codex에서 로그인")
        }
        do {
            var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
            if let accountID = auth.accountID {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
            }
            let response = try await client.send(request)
            if response.statusCode == 200 {
                return try ChatGPTUsageMapper.map(response.data)
            }
            if let failed = failureSnapshot(
                status: response.statusCode,
                unauthorized: "ChatGPT 또는 Codex에서 로그인",
                base: empty
            ), response.statusCode == 401 || response.statusCode == 429 {
                return failed
            }
            if let fallback {
                let data = try await fallback()
                return try ChatGPTUsageMapper.map(data)
            }
            return failureSnapshot(status: response.statusCode, unauthorized: "ChatGPT 또는 Codex에서 로그인", base: empty) ?? empty
        } catch {
            if let fallback, let mapped = try? await ChatGPTUsageMapper.map(fallback()) {
                return mapped
            }
            return tagged(empty, status: .unavailable, message: nil)
        }
    }
}
