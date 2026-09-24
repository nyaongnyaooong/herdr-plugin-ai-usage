import Foundation
import AIUsageCore

public enum HerdrClient {
    public static func publish(snapshot _: UsageSnapshot?, visibleIDs _: [ProviderID]) {
        let herdr = ProcessInfo.processInfo.environment["HERDR_BIN_PATH"] ?? "herdr"
        let list = run(herdr, arguments: ["workspace", "list"])
        let ids = WorkspaceList.ids(from: list)
        guard !ids.isEmpty else { return }
        for id in ids {
            var arguments = [
                "workspace", "report-metadata", id,
                "--source", "ai-usage",
                "--ttl-ms", "360000"
            ]
            for provider in ProviderID.allCases {
                arguments.append("--clear-token")
                arguments.append(SidebarText.tokenName(provider))
            }
            _ = run(herdr, arguments: arguments)
        }
    }

    @discardableResult
    private static func run(_ executable: String, arguments: [String]) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return Data()
        }
        return stdout.fileHandleForReading.readDataToEndOfFile()
    }
}
