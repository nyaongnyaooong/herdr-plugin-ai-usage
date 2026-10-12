import AppKit
import Combine
import Foundation
import AIUsageCore

@MainActor
public final class UsageSession: ObservableObject {
    @Published public private(set) var snapshot: UsageSnapshot?
    @Published public private(set) var accounts: [ManagedAccount] = []
    @Published public private(set) var visibleIDs: Set<ProviderID>
    @Published public private(set) var notice: String?
    @Published public private(set) var menuBarFontID: MenuBarFontID
    @Published public private(set) var capturingProvider: ProviderID?
    @Published public private(set) var applyingAccountID: UUID?
    private let defaults: UserDefaults
    private let gate: RefreshGate
    private let coordinator: RefreshCoordinator
    private let snapshotStore: SnapshotStore
    private let accountStore: AccountStore
    private let credentials: AccountCredentialStore
    private let cursorAdapter: CursorAdapter
    private let chatgptAdapter: ChatGPTAdapter
    private let chatgptSavedAdapter: ChatGPTAdapter
    private let claudeAdapter: ClaudeAdapter

    public var canRefresh: Bool { gate.shouldStartNetwork() }
    public var orderedVisibleIDs: [ProviderID] { ProviderVisibility.ordered(visibleIDs) }

    public init() {
        let defaults = UserDefaults(suiteName: "app.aiusage.AIUsage") ?? .standard
        self.defaults = defaults
        visibleIDs = ProviderVisibility.load(from: defaults)
        menuBarFontID = MenuBarFontPreference.load(from: defaults)
        gate = RefreshGate(defaults: defaults)
        let directory = Self.snapshotDirectory()
        snapshotStore = SnapshotStore(directory: directory)
        accountStore = AccountStore(directory: directory)
        credentials = FileAccountCredentialStore(directory: directory)
        snapshot = try? snapshotStore.load()
        accounts = accountStore.allAccounts()
        let client = URLSessionHTTPClient(session: Self.makeSession())
        let cursor = CursorAdapter(client: client)
        let chatgptLive = ChatGPTAdapter(client: client, fallback: {
            try await CodexAppServerFallback.fetchRateLimits()
        })
        let chatgptSaved = ChatGPTAdapter(client: client)
        let claude = ClaudeAdapter(client: client, userAgent: ClaudeUserAgent.value())
        cursorAdapter = cursor
        chatgptAdapter = chatgptLive
        chatgptSavedAdapter = chatgptSaved
        claudeAdapter = claude
        let store = accountStore
        let creds = credentials
        coordinator = RefreshCoordinator(
            dependencies: RefreshDependencies(
                gate: gate,
                store: snapshotStore,
                cooldown: ProviderCooldown(defaults: defaults),
                now: { Date() },
                fetchCursor: {
                    await UsageSession.fetchUsingAccounts(
                        provider: .cursor,
                        store: store,
                        credentials: creds,
                        saved: { await cursor.fetch(accessToken: $0.oauthToken) },
                        live: {
                            let token = Self.currentCursorSession()?.accessToken
                            return await cursor.fetch(accessToken: token)
                        }
                    )
                },
                fetchChatGPT: {
                    await UsageSession.fetchUsingAccounts(
                        provider: .chatgpt,
                        store: store,
                        credentials: creds,
                        saved: { cred in
                            await chatgptSaved.fetch(
                                auth: ChatGPTAuth(accessToken: cred.oauthToken ?? "", accountID: cred.accountID)
                            )
                        },
                        live: {
                            let auth = try? ChatGPTTokenReader(authFileURL: Self.codexAuth).readAccessToken()
                            return await chatgptLive.fetch(auth: auth)
                        }
                    )
                },
                fetchClaude: {
                    await UsageSession.fetchUsingAccounts(
                        provider: .claude,
                        store: store,
                        credentials: creds,
                        saved: { cred in
                            await claude.fetch(
                                accessToken: cred.oauthToken,
                                apiKey: cred.apiKey,
                                localCost: Self.claudeLocalCost()
                            )
                        },
                        live: {
                            await claude.fetch(
                                accessToken: Self.claudeOAuthToken(),
                                apiKey: Self.claudeAPIKey(),
                                localCost: Self.claudeLocalCost()
                            )
                        }
                    )
                }
            )
        )
    }

    public func accounts(for id: ProviderID) -> [ManagedAccount] {
        accounts.filter { $0.provider == id }
    }

    public func refresh(forceNetwork: Bool = false) async {
        snapshot = await coordinator.refresh(forceNetwork: forceNetwork)
        publishAccounts()
        HerdrClient.publish(snapshot: snapshot, visibleIDs: orderedVisibleIDs)
    }

    public func captureCurrentSession(_ id: ProviderID) async {
        capturingProvider = id
        defer { capturingProvider = nil }
        switch id {
        case .cursor:
            let session = Self.currentCursorSession()
            var usage = await cursorAdapter.fetch(accessToken: session?.accessToken)
            if usage.accountLabel == nil {
                usage.accountLabel = session?.accountLabel
            }
            finishCapture(
                id: id,
                accessToken: session?.accessToken,
                accountID: nil,
                apiKey: nil,
                usage: usage,
                missing: "Cursor에서 로그인하세요"
            )
        case .chatgpt:
            let auth = try? ChatGPTTokenReader(authFileURL: Self.codexAuth).readAccessToken()
            let usage = await chatgptAdapter.fetch(auth: auth)
            finishCapture(
                id: id,
                accessToken: auth?.accessToken,
                accountID: auth?.accountID,
                apiKey: nil,
                usage: usage,
                missing: "ChatGPT 또는 Codex에서 로그인하세요"
            )
        case .claude:
            let token = Self.claudeOAuthToken()
            let apiKey = Self.claudeAPIKey()
            let usage = await claudeAdapter.fetch(
                accessToken: token,
                apiKey: apiKey,
                localCost: Self.claudeLocalCost()
            )
            finishCapture(
                id: id,
                accessToken: token,
                accountID: nil,
                apiKey: apiKey,
                usage: usage,
                missing: "Claude Code 로그인 또는 ANTHROPIC_API_KEY를 확인하세요"
            )
        }
    }

    public func applyStoredAccount(_ id: UUID) async {
        guard let account = accountStore.allAccounts().first(where: { $0.id == id }) else { return }
        applyingAccountID = id
        defer { applyingAccountID = nil }
        accountStore.setActive(id)
        if let cred = try? credentials.load(id: id) {
            let usage = await fetchSaved(provider: account.provider, credential: cred)
            accountStore.updateUsage(usage, for: id)
            applyUsage(usage)
        } else if let usage = account.usage {
            applyUsage(usage)
        }
        publishAccounts()
        notice = "저장한 인증을 적용했습니다"
    }

    public func removeAccount(_ id: UUID) {
        let provider = accountStore.allAccounts().first(where: { $0.id == id })?.provider
        try? credentials.delete(id: id)
        accountStore.remove(id)
        publishAccounts()
        if let provider {
            if let usage = accountStore.active(for: provider)?.usage {
                applyUsage(usage)
            } else {
                Task { applyUsage(await fetchLive(provider)) }
            }
        }
        notice = "저장한 인증을 삭제했습니다"
    }

    public func clearAppliedSession(_ provider: ProviderID) async {
        quitVendorApps(for: provider)
        try? await Task.sleep(nanoseconds: 300_000_000)
        do {
            try Self.clearVendorLocalSession(provider)
        } catch {
            notice = "로컬 세션을 지우지 못했습니다. 해당 앱을 종료한 뒤 다시 시도하세요"
            return
        }
        accountStore.clearActive(for: provider)
        publishAccounts()
        applyUsage(await fetchLive(provider))
        notice = Self.clearedSessionNotice(provider: provider, cursorStillRunning: Self.isCursorRunning())
    }

    public func isVisible(_ id: ProviderID) -> Bool {
        visibleIDs.contains(id)
    }

    public func setVisible(_ id: ProviderID, enabled: Bool) {
        var ids = visibleIDs
        if enabled {
            ids.insert(id)
        } else {
            ids.remove(id)
        }
        guard !ids.isEmpty else {
            notice = "프로바이더는 하나 이상 켜 두세요"
            return
        }
        visibleIDs = ids
        ProviderVisibility.save(visibleIDs, to: defaults)
        HerdrClient.publish(snapshot: snapshot, visibleIDs: orderedVisibleIDs)
    }

    public func setMenuBarFont(_ id: MenuBarFontID) {
        menuBarFontID = id
        MenuBarFontPreference.save(id, to: defaults)
    }

    public func toggleVisible(_ id: ProviderID) {
        setVisible(id, enabled: !visibleIDs.contains(id))
    }

    private func finishCapture(
        id: ProviderID,
        accessToken: String?,
        accountID: String?,
        apiKey: String?,
        usage: ProviderSnapshot,
        missing: String
    ) {
        let credential = AccountCredential(accessToken: accessToken ?? "", accountID: accountID, apiKey: apiKey)
        guard let secret = credential.secretForIdentity else {
            notice = missing
            return
        }
        guard usage.status == .ok else {
            notice = usage.statusMessage ?? missing
            return
        }
        let display = AccountIdentity.storedDisplayName(
            provider: id,
            accountLabel: usage.accountLabel,
            planName: usage.planName,
            apiKey: apiKey,
            hasOAuth: credential.oauthToken != nil
        )
        let result = accountStore.upsert(
            provider: id,
            identityKey: AccountIdentity.key(
                provider: id,
                accountID: accountID,
                email: usage.accountLabel,
                token: secret
            ),
            displayName: display,
            planName: usage.planName,
            usage: usage
        )
        do {
            try credentials.save(credential, for: result.account.id)
        } catch {
            notice = "인증을 저장하지 못했습니다"
            return
        }
        publishAccounts()
        if result.account.isActive {
            applyUsage(usage)
        }
        notice = result.isNew ? "현재 세션을 계정으로 저장했습니다" : "이미 저장한 계정의 인증을 갱신했습니다"
    }

    private func fetchSaved(provider: ProviderID, credential: AccountCredential) async -> ProviderSnapshot {
        switch provider {
        case .cursor:
            return await cursorAdapter.fetch(accessToken: credential.oauthToken)
        case .chatgpt:
            return await chatgptSavedAdapter.fetch(
                auth: ChatGPTAuth(accessToken: credential.oauthToken ?? "", accountID: credential.accountID)
            )
        case .claude:
            return await claudeAdapter.fetch(accessToken: credential.oauthToken, apiKey: credential.apiKey)
        }
    }

    private func fetchLive(_ provider: ProviderID) async -> ProviderSnapshot {
        switch provider {
        case .cursor:
            let token = Self.currentCursorSession()?.accessToken
            return await cursorAdapter.fetch(accessToken: token)
        case .chatgpt:
            let auth = try? ChatGPTTokenReader(authFileURL: Self.codexAuth).readAccessToken()
            return await chatgptAdapter.fetch(auth: auth)
        case .claude:
            return await claudeAdapter.fetch(
                accessToken: Self.claudeOAuthToken(),
                apiKey: Self.claudeAPIKey(),
                localCost: Self.claudeLocalCost()
            )
        }
    }

    private func applyUsage(_ usage: ProviderSnapshot) {
        guard var snap = snapshot else {
            snapshot = UsageSnapshot(fetchedAt: Date(), lastNetworkStartedAt: Date(), providers: [usage])
            try? snapshotStore.save(snapshot!)
            return
        }
        if let index = snap.providers.firstIndex(where: { $0.id == usage.id }) {
            snap.providers[index] = usage
        } else {
            snap.providers.append(usage)
        }
        snapshot = snap
        try? snapshotStore.save(snap)
    }

    private func publishAccounts() {
        accounts = accountStore.allAccounts()
    }

    private func quitVendorApps(for provider: ProviderID) {
        let bundleIDs: [String]
        switch provider {
        case .chatgpt:
            bundleIDs = ["com.openai.codex", "com.openai.chat"]
        case .claude:
            bundleIDs = ["com.anthropic.claudefordesktop"]
        case .cursor:
            bundleIDs = []
        }
        let apps = bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, apps.contains(where: { !$0.isTerminated }) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for app in apps where !app.isTerminated {
            app.forceTerminate()
        }
    }

    nonisolated private static func clearVendorLocalSession(_ provider: ProviderID) throws {
        let httpRoot = home.appendingPathComponent("Library/HTTPStorages")
        switch provider {
        case .chatgpt:
            try VendorLocalSession.clearChatGPT(
                authFileURL: codexAuth,
                chromiumRoot: home.appendingPathComponent("Library/Application Support/Codex"),
                httpCookieFile: httpRoot.appendingPathComponent("com.openai.codex.binarycookies")
            )
        case .claude:
            try VendorLocalSession.clearClaude(
                credentialsFileURL: claudeCredentials,
                chromiumRoot: home.appendingPathComponent("Library/Application Support/Claude"),
                httpCookieFile: httpRoot.appendingPathComponent("com.anthropic.claudefordesktop.binarycookies")
            )
        case .cursor:
            try VendorLocalSession.clearCursor(databaseURL: cursorDB)
        }
    }

    nonisolated private static func isCursorRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.todesktop.230313mzl4w4u92").isEmpty
    }

    nonisolated private static func clearedSessionNotice(provider: ProviderID, cursorStillRunning: Bool) -> String {
        switch provider {
        case .chatgpt:
            return "ChatGPT 로컬 세션을 지웠습니다. 앱을 다시 열면 로그인 화면이 나옵니다. 저장한 인증은 그대로입니다."
        case .claude:
            return "Claude 로컬 세션을 지웠습니다. 앱을 다시 열면 로그인 화면이 나옵니다. 셸 API 키와 저장한 인증은 그대로입니다."
        case .cursor:
            if cursorStillRunning {
                return "Cursor 로컬 토큰을 지웠습니다. Cursor를 완전히 종료한 뒤 다시 열면 로그인 화면이 나옵니다. 저장한 인증은 그대로입니다."
            }
            return "Cursor 로컬 세션을 지웠습니다. 앱을 다시 열면 로그인 화면이 나옵니다. 저장한 인증은 그대로입니다."
        }
    }

    nonisolated private static func fetchUsingAccounts(
        provider: ProviderID,
        store: AccountStore,
        credentials: AccountCredentialStore,
        saved: (AccountCredential) async -> ProviderSnapshot,
        live: () async -> ProviderSnapshot
    ) async -> ProviderSnapshot {
        let records = store.accounts(for: provider)
        if records.isEmpty {
            return await live()
        }
        for account in records {
            guard let cred = try? credentials.load(id: account.id) else { continue }
            let usage = await saved(cred)
            store.updateUsage(usage, for: account.id)
        }
        if let usage = store.active(for: provider)?.usage {
            return usage
        }
        return await live()
    }

    nonisolated private static func claudeOAuthToken() -> String? {
        try? ClaudeTokenReader(credentialsFileURL: claudeCredentials).readAccessToken()
    }

    nonisolated private static func claudeAPIKey() -> String? {
        ClaudeAPIKeyReader.read(environment: ProcessInfo.processInfo.environment, home: home)
    }

    nonisolated private static func claudeLocalCost() -> APIMeter? {
        ClaudeCLIUsageReader.monthlyMeter(
            now: Date(),
            projectRoots: [
                home.appendingPathComponent(".claude/projects"),
                home.appendingPathComponent(".config/claude/projects")
            ]
        )
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }

    private static func snapshotDirectory() -> URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    nonisolated private static var cursorDB: URL {
        home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    nonisolated private static func currentCursorSession() -> CursorSession? {
        if let session = try? CursorTokenReader(databaseURL: cursorDB).readSession() {
            return session
        }
        return cursorCLISession()
    }

    nonisolated private static func cursorCLISession() -> CursorSession? {
        let paths = [
            home.appendingPathComponent(".config/cursor/auth.json"),
            home.appendingPathComponent(".cursor/auth.json"),
        ]
        for url in paths {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let rawToken = (json["accessToken"] as? String) ?? (json["access_token"] as? String)
            let token = rawToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if token.isEmpty { continue }
            let email = (json["email"] as? String) ?? (json["userEmail"] as? String)
            return CursorSession(accessToken: token, email: email)
        }
        return nil
    }

    nonisolated private static var claudeCredentials: URL {
        home.appendingPathComponent(".claude/.credentials.json")
    }

    nonisolated private static var codexAuth: URL {
        home.appendingPathComponent(".codex/auth.json")
    }
}
