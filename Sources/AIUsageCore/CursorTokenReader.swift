import Foundation
import SQLite3

public struct CursorSession: Equatable, Sendable {
    public var accessToken: String
    public var email: String?
    public var displayName: String?

    public var accountLabel: String? {
        Self.nonEmpty(email) ?? Self.nonEmpty(displayName)
    }

    public init(accessToken: String, email: String? = nil, displayName: String? = nil) {
        self.accessToken = accessToken
        self.email = email
        self.displayName = displayName
    }

    fileprivate static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum CursorSessionError: Error {
    case databaseBusy
}

public struct CursorTokenReader: Sendable {
    private let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func readAccessToken() throws -> String? {
        try readSession()?.accessToken
    }

    public func readSession() throws -> CursorSession? {
        if let session = try open(immutable: false) { return session }
        return try open(immutable: true)
    }

    public func clearLocalSession() throws {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw CursorSessionError.databaseBusy
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        let sql = """
        DELETE FROM ItemTable WHERE key IN (
            'cursorAuth/accessToken',
            'cursorAuth/refreshToken'
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CursorSessionError.databaseBusy
        }
    }

    private func open(immutable: Bool) throws -> CursorSession? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        var db: OpaquePointer?
        let path = immutable ? "file:\(databaseURL.path)?immutable=1" : databaseURL.path
        let flags = SQLITE_OPEN_READONLY | (immutable ? SQLITE_OPEN_URI : 0)
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = """
        SELECT key, value FROM ItemTable WHERE key IN (
            'cursorAuth/accessToken',
            'cursorAuth/cachedEmail',
            'cursorAuth/cachedScopedProfile',
            'cursor.customize.userDisplayNameCache'
        );
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var token: String?
        var email: String?
        var profileName: String?
        var cachedName: String?
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyPointer = sqlite3_column_text(stmt, 0),
                  let valuePointer = sqlite3_column_text(stmt, 1) else { continue }
            let key = String(cString: keyPointer)
            let value = cleaned(String(cString: valuePointer))
            switch key {
            case "cursorAuth/accessToken":
                token = value
            case "cursorAuth/cachedEmail":
                email = value
            case "cursorAuth/cachedScopedProfile":
                profileName = displayName(fromProfile: value)
            case "cursor.customize.userDisplayNameCache":
                cachedName = value
            default:
                break
            }
        }
        guard let token, !token.isEmpty else { return nil }
        return CursorSession(
            accessToken: token,
            email: email,
            displayName: profileName ?? cachedName
        )
    }

    private func cleaned(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return CursorSession.nonEmpty(value)
    }

    private func displayName(fromProfile raw: String?) -> String? {
        guard let raw, let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["displayName"] as? String else {
            return nil
        }
        return CursorSession.nonEmpty(name)
    }
}
