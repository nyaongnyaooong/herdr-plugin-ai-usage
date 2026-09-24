import Foundation

public struct ProviderVisibility {
    public static let defaultsKey = "visibleProviderIDs"

    public static func load(from defaults: UserDefaults) -> Set<ProviderID> {
        guard let raw = defaults.array(forKey: defaultsKey) as? [String] else {
            return Set(ProviderID.allCases)
        }
        let parsed = Set(raw.compactMap(ProviderID.init(rawValue:)))
        return parsed
    }

    public static func save(_ ids: Set<ProviderID>, to defaults: UserDefaults) {
        defaults.set(ProviderID.allCases.filter { ids.contains($0) }.map(\.rawValue), forKey: defaultsKey)
    }

    public static func ordered(_ ids: Set<ProviderID>) -> [ProviderID] {
        ProviderID.allCases.filter { ids.contains($0) }
    }
}
