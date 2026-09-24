import Foundation

func tagged(_ snapshot: ProviderSnapshot, status: ProviderStatus, message: String?) -> ProviderSnapshot {
    var copy = snapshot
    copy.status = status
    copy.statusMessage = message
    return copy
}

func failureSnapshot(status: Int, unauthorized: String, base: ProviderSnapshot) -> ProviderSnapshot? {
    if status == 401 { return tagged(base, status: .missingAuth, message: unauthorized) }
    if status == 429 { return tagged(base, status: .rateLimited, message: nil) }
    if status >= 400 { return tagged(base, status: .unavailable, message: nil) }
    return nil
}
