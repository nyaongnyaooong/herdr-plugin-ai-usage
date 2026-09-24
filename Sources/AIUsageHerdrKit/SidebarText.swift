import Foundation
import AIUsageCore

public enum SidebarText {
    public static func line(id: ProviderID, provider: ProviderSnapshot?) -> String {
        if provider?.left.remainingPercent == nil,
           provider?.right.remainingPercent == nil,
           let api = provider?.api {
            return "\(id.displayName) \(api.label) \(api.detail)"
        }
        let meters = MenuBarFormatting.compactVisible(
            leftLabel: id.menuBarLeftLabel,
            left: provider?.left.remainingPercent,
            rightLabel: id.menuBarRightLabel,
            right: provider?.right.remainingPercent
        )
        return "\(id.displayName) \(meters)"
    }

    public static func sidebar(id: ProviderID, provider: ProviderSnapshot?) -> String? {
        guard let provider, StatusBar.isConnected(provider) else { return nil }
        if provider.left.remainingPercent == nil,
           provider.right.remainingPercent == nil,
           let api = provider.api {
            return api.detail
        }
        switch (provider.left.remainingPercent, provider.right.remainingPercent) {
        case let (left?, right?):
            return "\(left)%·\(right)%"
        case let (left?, nil):
            return "\(left)%"
        case let (nil, right?):
            return "\(right)%"
        default:
            return nil
        }
    }

    public static func tokenName(_ id: ProviderID) -> String {
        "ai_\(id.rawValue)"
    }
}

public enum StatusLine {
    public static func format(snapshot: UsageSnapshot?, visibleIDs: [ProviderID]) -> String {
        let ids = visibleIDs.isEmpty ? Array(ProviderID.allCases) : visibleIDs
        return ids.map { SidebarText.line(id: $0, provider: snapshot?.provider($0)) }.joined(separator: "  ")
    }

    public static func current() -> String {
        let defaults = UserDefaults(suiteName: "app.aiusage.AIUsage") ?? .standard
        let visible = ProviderVisibility.ordered(ProviderVisibility.load(from: defaults))
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsage", isDirectory: true)
        let snapshot = try? SnapshotStore(directory: directory).load()
        return format(snapshot: snapshot, visibleIDs: visible)
    }
}

public enum WorkspaceList {
    public static func ids(from data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let workspaces = result["workspaces"] as? [[String: Any]] else {
            return []
        }
        return workspaces.compactMap { $0["workspace_id"] as? String }
    }
}
