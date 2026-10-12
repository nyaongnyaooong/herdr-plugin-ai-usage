import Foundation

public enum StatusPaneKeeper {
    static let titleMarker = "ai-usage-status"
    private static let targetRatio = 0.9

    public static func ensure(repairRatio: Bool = true, allWorkspaces: Bool = false) {
        let herdr = ProcessInfo.processInfo.environment["HERDR_BIN_PATH"] ?? "herdr"
        let workspaceID = allWorkspaces ? nil : focusedWorkspaceID(herdr)
        guard allWorkspaces || workspaceID != nil else { return }
        for tabID in tabIDs(herdr, workspaceID: workspaceID) {
            var panes = paneList(herdr)
            closeStaleShells(on: tabID, panes: panes, herdr: herdr)
            panes = paneList(herdr)
            let onTab = panes.filter { $0.tabID == tabID }
            let content = onTab.filter { !$0.isStatus && !$0.isStaleShell }
            if content.isEmpty {
                if onTab.contains(where: \.isStatus) {
                    _ = run(herdr, ["tab", "close", tabID])
                }
                continue
            }
            if let status = onTab.first(where: \.isStatus) {
                guard repairRatio else { continue }
                let followedBottom = content.contains { $0.offsetFromBottom == 0 }
                if pinRatio(tabID: tabID, paneID: status.id), followedBottom {
                    for pane in content where pane.offsetFromBottom == 0 {
                        scrollToBottom(pane.id)
                    }
                }
                continue
            }
            guard let target = content.first(where: \.focused) ?? content.first else { continue }
            let before = Set(panes.map(\.id))
            _ = run(herdr, [
                "plugin", "pane", "open",
                "--plugin", "ai-usage",
                "--entrypoint", "statusbar-macos",
                "--placement", "split",
                "--direction", "down",
                "--target-pane", target.id,
                "--no-focus"
            ])
            panes = paneList(herdr)
            guard let created = panes.first(where: { $0.tabID == tabID && !before.contains($0.id) }) else { continue }
            openedAt[created.id] = Date()
            _ = pinRatio(tabID: tabID, paneID: created.id)
            if target.offsetFromBottom == 0 {
                scrollToBottom(target.id)
            }
        }
    }

    private static var openedAt: [String: Date] = [:]

    private static func closeStaleShells(on tabID: String, panes: [ListedPane], herdr: String) {
        for pane in panes where pane.tabID == tabID && pane.isStaleShell && !isProtected(pane.id) {
            _ = run(herdr, ["pane", "close", pane.id])
            openedAt[pane.id] = nil
        }
    }

    private static func isProtected(_ paneID: String) -> Bool {
        guard let opened = openedAt[paneID] else { return false }
        return Date().timeIntervalSince(opened) < 3
    }

    private static func scrollToBottom(_ paneID: String) {
        _ = rpc(method: "pane.scroll", params: [
            "pane_id": paneID,
            "offset_from_bottom": 0
        ])
    }

    @discardableResult
    private static func pinRatio(tabID: String, paneID: String) -> Bool {
        guard let layout = exportLayout(tabID: tabID),
              let path = splitPath(in: layout, paneID: paneID) else { return false }
        let ratio = path.statusIsSecond ? targetRatio : 0.1
        if abs(path.ratio - ratio) < 0.02 { return false }
        _ = rpc(method: "layout.set_split_ratio", params: [
            "tab_id": tabID,
            "path": path.path,
            "ratio": ratio
        ])
        return true
    }

    private struct SplitPath {
        var path: [Bool]
        var ratio: Double
        var statusIsSecond: Bool
    }

    private static func splitPath(in node: [String: Any], paneID: String) -> SplitPath? {
        walk(node, path: [], paneID: paneID)
    }

    private static func walk(_ node: [String: Any], path: [Bool], paneID: String) -> SplitPath? {
        let type = (node["type"] as? String)?.lowercased() ?? ""
        if type == "pane" || node["pane_id"] != nil && node["first"] == nil {
            return nil
        }
        let first = node["first"] as? [String: Any]
        let second = node["second"] as? [String: Any]
        if isDirect(second, paneID: paneID) {
            return SplitPath(path: path, ratio: number(node["ratio"]), statusIsSecond: true)
        }
        if isDirect(first, paneID: paneID) {
            return SplitPath(path: path, ratio: number(node["ratio"]), statusIsSecond: false)
        }
        if let first, let found = walk(first, path: path + [false], paneID: paneID) { return found }
        if let second, let found = walk(second, path: path + [true], paneID: paneID) { return found }
        return nil
    }

    private static func number(_ value: Any?) -> Double {
        if let number = value as? Double { return number }
        if let number = value as? NSNumber { return number.doubleValue }
        return 0
    }

    private static func isDirect(_ node: [String: Any]?, paneID: String) -> Bool {
        guard let node else { return false }
        if let id = node["pane_id"] as? String, id == paneID { return true }
        if let pane = node["pane"] as? [String: Any], pane["pane_id"] as? String == paneID { return true }
        return false
    }

    private static func exportLayout(tabID: String) -> [String: Any]? {
        guard let data = rpc(method: "layout.export", params: ["tab_id": tabID]),
              let root = jsonObject(data),
              let result = root["result"] as? [String: Any] else { return nil }
        if let layout = result["layout"] as? [String: Any] {
            if let tree = layout["root"] as? [String: Any] { return tree }
            return layout
        }
        return result["root"] as? [String: Any]
    }

    private struct ListedPane {
        var id: String
        var tabID: String
        var title: String
        var label: String
        var focused: Bool
        var offsetFromBottom: Int

        var isStatus: Bool {
            title.contains(titleMarker)
        }

        var isStaleShell: Bool {
            label == "AI Usage" && !isStatus
        }
    }

    private static func focusedWorkspaceID(_ herdr: String) -> String? {
        guard let root = jsonObject(run(herdr, ["workspace", "list"])),
              let result = root["result"] as? [String: Any],
              let workspaces = result["workspaces"] as? [[String: Any]] else { return nil }
        let workspace = workspaces.first { $0["focused"] as? Bool == true } ?? workspaces.first
        return workspace?["workspace_id"] as? String
    }

    private static func tabIDs(_ herdr: String, workspaceID: String?) -> [String] {
        guard let root = jsonObject(run(herdr, ["tab", "list"])),
              let result = root["result"] as? [String: Any],
              let tabs = result["tabs"] as? [[String: Any]] else { return [] }
        return tabs.compactMap { tab in
            guard workspaceID == nil || tab["workspace_id"] as? String == workspaceID else { return nil }
            return tab["tab_id"] as? String
        }
    }

    private static func paneList(_ herdr: String) -> [ListedPane] {
        guard let root = jsonObject(run(herdr, ["pane", "list"])),
              let result = root["result"] as? [String: Any],
              let panes = result["panes"] as? [[String: Any]] else { return [] }
        return panes.compactMap { pane in
            guard let id = pane["pane_id"] as? String, let tabID = pane["tab_id"] as? String else { return nil }
            let title = (pane["terminal_title"] as? String) ?? (pane["terminal_title_stripped"] as? String) ?? ""
            let label = pane["label"] as? String ?? ""
            let scroll = pane["scroll"] as? [String: Any]
            let offset = (scroll?["offset_from_bottom"] as? NSNumber)?.intValue ?? 0
            return ListedPane(
                id: id,
                tabID: tabID,
                title: title,
                label: label,
                focused: pane["focused"] as? Bool ?? false,
                offsetFromBottom: offset
            )
        }
    }

    private static func rpc(method: String, params: [String: Any]) -> Data? {
        guard let body = try? JSONSerialization.data(withJSONObject: params),
              let json = String(data: body, encoding: .utf8) else { return nil }
        let root = ProcessInfo.processInfo.environment["HERDR_PLUGIN_ROOT"]
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().path
        let script = URL(fileURLWithPath: root).appendingPathComponent("scripts/herdr-rpc.py").path
        return run("/usr/bin/python3", [script, method, json])
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable == "/usr/bin/python3" ? executable : "/usr/bin/env")
        if executable == "/usr/bin/python3" {
            process.arguments = arguments
        } else {
            process.arguments = [executable] + arguments
        }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return Data()
        }
        return stdout.fileHandleForReading.readDataToEndOfFile()
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "{"),
              let body = text[start...].data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}
