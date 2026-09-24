import Foundation

public struct SnapshotStore: Sendable {
    public static let appGroupID = "group.app.aiusage.AIUsage"
    public static let fileName = "usage-snapshot.json"

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func appGroupDirectory() -> URL? {
        // Team ID 없는 group.* 는 Sequoia에서 매 실행마다 "다른 앱의 데이터" 확인이 뜬다.
        nil
    }

    public func load() throws -> UsageSnapshot? {
        let url = directory.appendingPathComponent(Self.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UsageSnapshot.self, from: data)
    }

    public func save(_ snapshot: UsageSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let finalURL = directory.appendingPathComponent(Self.fileName)
        let tempURL = directory.appendingPathComponent("usage-snapshot.json.tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tempURL)
    }
}
