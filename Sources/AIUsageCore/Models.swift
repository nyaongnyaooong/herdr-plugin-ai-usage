import Foundation

public enum ProviderID: String, Codable, CaseIterable, Equatable {
    case cursor
    case chatgpt
    case claude

    public var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        }
    }

    public var leftLabel: String { self == .cursor ? "Auto" : "5시간" }
    public var rightLabel: String { self == .cursor ? "Other" : "주간" }

    public var menuBarLeftLabel: String { self == .cursor ? "Auto" : "5h" }
    public var menuBarRightLabel: String { self == .cursor ? "Other" : "Weekly" }
}

public enum ProviderStatus: String, Codable, Equatable {
    case ok
    case missingAuth
    case rateLimited
    case unavailable
}

public struct Meter: Codable, Equatable {
    public var label: String
    public var remainingPercent: Int?
    public var resetsAt: Date?

    public init(label: String, remainingPercent: Int? = nil, resetsAt: Date? = nil) {
        self.label = label
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }
}

public struct APIMeter: Codable, Equatable {
    public var label: String
    public var detail: String

    public init(label: String, detail: String) {
        self.label = label
        self.detail = detail
    }
}

public struct ProviderSnapshot: Codable, Equatable {
    public var id: ProviderID
    public var displayName: String
    public var planName: String?
    public var status: ProviderStatus
    public var statusMessage: String?
    public var left: Meter
    public var right: Meter
    public var api: APIMeter?
    public var accountLabel: String?

    public init(
        id: ProviderID,
        displayName: String,
        planName: String? = nil,
        status: ProviderStatus,
        statusMessage: String? = nil,
        left: Meter,
        right: Meter,
        api: APIMeter? = nil,
        accountLabel: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.planName = planName
        self.status = status
        self.statusMessage = statusMessage
        self.left = left
        self.right = right
        self.api = api
        self.accountLabel = accountLabel
    }

    public static func empty(id: ProviderID, displayName: String, leftLabel: String, rightLabel: String) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id,
            displayName: displayName,
            status: .missingAuth,
            left: Meter(label: leftLabel),
            right: Meter(label: rightLabel)
        )
    }
}

public struct UsageSnapshot: Codable, Equatable {
    public var fetchedAt: Date
    public var lastNetworkStartedAt: Date
    public var providers: [ProviderSnapshot]

    public init(fetchedAt: Date, lastNetworkStartedAt: Date, providers: [ProviderSnapshot]) {
        self.fetchedAt = fetchedAt
        self.lastNetworkStartedAt = lastNetworkStartedAt
        self.providers = providers
    }

    public func provider(_ id: ProviderID) -> ProviderSnapshot? {
        providers.first { $0.id == id }
    }
}
