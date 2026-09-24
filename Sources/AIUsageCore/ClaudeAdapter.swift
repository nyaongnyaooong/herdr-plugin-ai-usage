import Foundation

public struct ClaudeAdapter: Sendable {
    private let client: HTTPClient
    private let userAgent: String
    private let now: @Sendable () -> Date

    public init(client: HTTPClient, userAgent: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.userAgent = userAgent
        self.now = now
    }

    public func fetch(accessToken: String?, apiKey: String? = nil, localCost: APIMeter? = nil) async -> ProviderSnapshot {
        let empty = ProviderSnapshot.empty(
            id: .claude,
            displayName: ProviderID.claude.displayName,
            leftLabel: ProviderID.claude.leftLabel,
            rightLabel: ProviderID.claude.rightLabel
        )
        var oauth: ProviderSnapshot?
        if let accessToken {
            oauth = await fetchOAuth(accessToken: accessToken, empty: empty)
        }
        var cost: APIMeter?
        var costDenied = false
        if let apiKey {
            switch await fetchCost(apiKey: apiKey) {
            case .meter(let meter):
                cost = meter
            case .denied:
                costDenied = true
            case .unavailable:
                break
            }
        }
        let apiCost = cost ?? localCost
        let localMessage = (cost == nil && localCost != nil) ? "Claude CLI 로컬 추정" : nil

        if var oauth, oauth.status == .ok {
            oauth.api = apiCost ?? oauth.api
            if oauth.statusMessage == nil {
                oauth.statusMessage = localMessage
            }
            return oauth
        }
        if let apiCost {
            return apiSnapshot(cost: apiCost, message: localMessage)
        }
        if let oauth {
            return oauth
        }
        if apiKey != nil {
            let message = costDenied
                ? "API 키 사용액은 Admin API 키(sk-ant-admin)가 있어야 조회됩니다"
                : "API 키는 찾았지만 이번 달 사용액을 아직 못 읽었습니다"
            return tagged(empty, status: .ok, message: message)
        }
        return tagged(empty, status: .missingAuth, message: "Claude Code에서 로그인 또는 ANTHROPIC_API_KEY")
    }

    private func apiSnapshot(cost: APIMeter, message: String?) -> ProviderSnapshot {
        ProviderSnapshot(
            id: .claude,
            displayName: "Claude",
            planName: "API",
            status: .ok,
            statusMessage: message,
            left: Meter(label: ProviderID.claude.leftLabel),
            right: Meter(label: ProviderID.claude.rightLabel),
            api: cost
        )
    }

    private func fetchOAuth(accessToken: String, empty: ProviderSnapshot) async -> ProviderSnapshot {
        do {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let response = try await client.send(request)
            if let failed = failureSnapshot(
                status: response.statusCode,
                unauthorized: "Claude Code를 한 번 실행해 로그인 상태를 갱신하세요",
                base: empty
            ) {
                return failed
            }
            return try ClaudeUsageMapper.map(response.data)
        } catch {
            return tagged(empty, status: .unavailable, message: nil)
        }
    }

    private enum CostResult {
        case meter(APIMeter)
        case denied
        case unavailable
    }

    private func fetchCost(apiKey: String) async -> CostResult {
        let (start, end) = ClaudeUsageMapper.monthBounds(now: now())
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: iso.string(from: start)),
            URLQueryItem(name: "ending_at", value: iso.string(from: end)),
            URLQueryItem(name: "limit", value: "31")
        ]
        guard let url = components.url else { return .unavailable }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            let response = try await client.send(request)
            if response.statusCode == 401 || response.statusCode == 403 {
                return .denied
            }
            if response.statusCode >= 400 {
                return .unavailable
            }
            if let meter = ClaudeUsageMapper.monthlyCost(response.data) {
                return .meter(meter)
            }
            return .meter(APIMeter(label: "Monthly", detail: "$0.00"))
        } catch {
            return .unavailable
        }
    }
}
