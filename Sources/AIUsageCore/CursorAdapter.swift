import Foundation

public struct CursorAdapter: Sendable {
    private let client: HTTPClient

    public init(client: HTTPClient) {
        self.client = client
    }

    public func fetch(accessToken: String?) async -> ProviderSnapshot {
        let empty = ProviderSnapshot.empty(id: .cursor, displayName: ProviderID.cursor.displayName, leftLabel: ProviderID.cursor.leftLabel, rightLabel: ProviderID.cursor.rightLabel)
        guard let accessToken else {
            return tagged(empty, status: .missingAuth, message: "Cursor에서 로그인")
        }
        do {
            var periodReq = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
            periodReq.httpMethod = "POST"
            periodReq.httpBody = Data("{}".utf8)
            periodReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            periodReq.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            periodReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let period = try await client.send(periodReq)
            if let failed = failureSnapshot(status: period.statusCode, unauthorized: "Cursor에서 로그인", base: empty) {
                return failed
            }
            let mapped = try CursorUsageMapper.mapPeriod(period.data)
            if mapped.left.remainingPercent != nil || mapped.right.remainingPercent != nil {
                return mapped
            }
            var authReq = URLRequest(url: URL(string: "https://api2.cursor.sh/auth/usage")!)
            authReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let auth = try await client.send(authReq)
            if let failed = failureSnapshot(status: auth.statusCode, unauthorized: "Cursor에서 로그인", base: empty) {
                return failed
            }
            return try CursorUsageMapper.mapAuthUsage(auth.data)
        } catch {
            return tagged(empty, status: .unavailable, message: nil)
        }
    }
}
