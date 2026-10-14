import Foundation

/// Keep direct invocations of the legacy Swift binary on the shared dashboard.
@MainActor
public enum Dashboard {
    public static func run(_ session: UsageSession) async {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let root = executable.deletingLastPathComponent().deletingLastPathComponent()
        let runner = root.appendingPathComponent("scripts/ai-usage.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [ProcessInfo.processInfo.environment["HERDR_PYTHON_BIN"] ?? "python3", runner.path, "dashboard"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            fputs("Unable to start AI Usage dashboard: \(error)\n", stderr)
        }
    }
}
