import Foundation

enum CodexAppServerFallback {
    enum FallbackError: Error {
        case missingBinary
        case timeout
        case invalidResponse
    }

    static func fetchRateLimits() async throws -> Data {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let binaries = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home.appendingPathComponent(".local/bin/codex").path
        ]
        guard let binary = binaries.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw FallbackError.missingBinary
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()

        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"# + "\n"
        let readLimits = #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"# + "\n"
        stdin.fileHandleForWriting.write(Data(initialize.utf8))
        stdin.fileHandleForWriting.write(Data(readLimits.utf8))

        let result: Data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var collected = Data()
                while process.isRunning || stdout.fileHandleForReading.availableData.isEmpty == false {
                    let chunk = stdout.fileHandleForReading.availableData
                    if !chunk.isEmpty {
                        collected.append(chunk)
                        if let payload = extractResult(id: 2, from: collected) {
                            process.terminate()
                            return payload
                        }
                    } else {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
                if let payload = extractResult(id: 2, from: collected) {
                    return payload
                }
                throw FallbackError.invalidResponse
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                process.terminate()
                throw FallbackError.timeout
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        return result
    }

    private static func extractResult(id: Int, from data: Data) -> Data? {
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(separator: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["id"] as? Int == id,
                  let result = json["result"] else { continue }
            return try? JSONSerialization.data(withJSONObject: result)
        }
        return nil
    }
}
