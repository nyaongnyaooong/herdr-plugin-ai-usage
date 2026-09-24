import Foundation
import SQLite3

public enum ChromiumCookieStore {
    public static func clearHosts(inCookiesFile url: URL, matching needles: [String]) throws {
        guard FileManager.default.fileExists(atPath: url.path), !needles.isEmpty else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        let clauses = Array(repeating: "host_key LIKE ?", count: needles.count).joined(separator: " OR ")
        let sql = "DELETE FROM cookies WHERE \(clauses);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, needle) in needles.enumerated() {
            let pattern = "%\(needle)%"
            sqlite3_bind_text(stmt, Int32(index + 1), pattern, -1, transient)
        }
        _ = sqlite3_step(stmt)
    }

    public static func clearHosts(under root: URL, matching needles: [String]) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let skip: Set<String> = [
            "Cache",
            "GPUCache",
            "Code Cache",
            "CachedData",
            "DawnGraphiteCache",
            "DawnWebGPUCache",
            "GrShaderCache",
            "component_crx_cache"
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skip.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            if name == "Cookies" {
                try clearHosts(inCookiesFile: url, matching: needles)
                let parent = url.deletingLastPathComponent()
                try? FileManager.default.removeItem(at: parent.appendingPathComponent("Local Storage"))
                try? FileManager.default.removeItem(at: parent.appendingPathComponent("Session Storage"))
            }
        }
    }
}

public enum VendorLocalSession {
    public static func clearChatGPT(authFileURL: URL, chromiumRoot: URL, httpCookieFile: URL?) throws {
        try ChatGPTTokenReader(authFileURL: authFileURL).clearLocalSession()
        try ChromiumCookieStore.clearHosts(under: chromiumRoot, matching: ["chatgpt.com", "openai.com"])
        removeIfExists(httpCookieFile)
    }

    public static func clearClaude(credentialsFileURL: URL, chromiumRoot: URL, httpCookieFile: URL?) throws {
        try ClaudeTokenReader(credentialsFileURL: credentialsFileURL).clearLocalSession()
        try ChromiumCookieStore.clearHosts(under: chromiumRoot, matching: ["claude.ai", "anthropic.com"])
        removeIfExists(httpCookieFile)
    }

    public static func clearCursor(databaseURL: URL) throws {
        try CursorTokenReader(databaseURL: databaseURL).clearLocalSession()
    }

    private static func removeIfExists(_ url: URL?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
