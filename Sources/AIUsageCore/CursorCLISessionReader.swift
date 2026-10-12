import Foundation

public struct CursorCLISessionReader: Sendable {
    public static let accessTokenService = "cursor-access-token"
    public static let keychainAccount = "cursor-user"

    public var authFileURLs: [URL]
    public var cliConfigURL: URL?
    public var keychainPassword: (@Sendable (String, String) -> String?)?

    public init(
        authFileURLs: [URL],
        cliConfigURL: URL?,
        keychainPassword: (@Sendable (String, String) -> String?)?
    ) {
        self.authFileURLs = authFileURLs
        self.cliConfigURL = cliConfigURL
        self.keychainPassword = keychainPassword
    }

    public static func live(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CursorCLISessionReader {
        let cursorConfig = cursorConfigDirectory(environment: environment)
        let xdgConfig = xdgConfigDirectory(home: home, environment: environment)
        var authFileURLs: [URL] = []
        if let cursorConfig {
            authFileURLs.append(cursorConfig.appendingPathComponent("auth.json"))
        }
        authFileURLs.append(home.appendingPathComponent(".cursor/auth.json"))
        authFileURLs.append(xdgConfig.appendingPathComponent("cursor/auth.json"))
        let cliConfigURL = (cursorConfig ?? home.appendingPathComponent(".cursor", isDirectory: true))
            .appendingPathComponent("cli-config.json")
        var keychainPassword: (@Sendable (String, String) -> String?)?
        #if os(macOS)
        keychainPassword = { service, account in
            CursorKeychain.password(service: service, account: account)
        }
        #endif
        return CursorCLISessionReader(
            authFileURLs: authFileURLs,
            cliConfigURL: cliConfigURL,
            keychainPassword: keychainPassword
        )
    }

    public func readSession() -> CursorSession? {
        if let session = readAuthFile() {
            return session
        }
        guard let keychainPassword else { return nil }
        let raw = keychainPassword(Self.accessTokenService, Self.keychainAccount) ?? ""
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty { return nil }
        let profile = readCLIProfile()
        return CursorSession(accessToken: token, email: profile.email, displayName: profile.displayName)
    }

    private func readAuthFile() -> CursorSession? {
        for url in authFileURLs {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let token = Self.string(json["accessToken"]) ?? Self.string(json["access_token"]) {
                let profile = readCLIProfile()
                let email = Self.string(json["email"]) ?? Self.string(json["userEmail"]) ?? profile.email
                let displayName = Self.string(json["displayName"]) ?? profile.displayName
                return CursorSession(accessToken: token, email: email, displayName: displayName)
            }
        }
        return nil
    }

    private func readCLIProfile() -> (email: String?, displayName: String?) {
        guard let cliConfigURL,
              let data = try? Data(contentsOf: cliConfigURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authInfo = json["authInfo"] as? [String: Any] else {
            return (nil, nil)
        }
        return (Self.string(authInfo["email"]), Self.string(authInfo["displayName"]))
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return trimmed
    }

    private static func cursorConfigDirectory(environment: [String: String]) -> URL? {
        if let configured = environment["CURSOR_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return nil
    }

    private static func xdgConfigDirectory(home: URL, environment: [String: String]) -> URL {
        if let configured = environment["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return home.appendingPathComponent(".config", isDirectory: true)
    }
}

enum CursorKeychain {
    static func password(service: String, account: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty { return nil }
        return token
    }
}
