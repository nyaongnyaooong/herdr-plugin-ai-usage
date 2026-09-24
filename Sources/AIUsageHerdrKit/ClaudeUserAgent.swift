import Foundation

enum ClaudeUserAgent {
    static func value() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home.appendingPathComponent(".local/bin/claude").path
        ]
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            if let version = runVersion(path) {
                return "claude-code/\(version)"
            }
        }
        return "claude-code/2.0.32"
    }

    private static func runVersion(_ path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        let token = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).first.map(String.init)
        return token.flatMap { $0.isEmpty ? nil : $0 }
    }
}
