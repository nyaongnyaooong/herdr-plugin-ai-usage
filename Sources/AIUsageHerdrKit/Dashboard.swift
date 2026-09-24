import Foundation
import AIUsageCore

@MainActor
public enum Dashboard {
    public static func run(_ session: UsageSession) async {
        await session.refresh(forceNetwork: true)
        HerdrClient.publish(snapshot: session.snapshot, visibleIDs: session.orderedVisibleIDs)
        while true {
            render(session)
            guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return
            }
            if line == "q" || line == "quit" {
                return
            }
            await handle(line, session: session)
            HerdrClient.publish(snapshot: session.snapshot, visibleIDs: session.orderedVisibleIDs)
        }
    }

    private static func handle(_ line: String, session: UsageSession) async {
        switch line {
        case "r", "refresh":
            await session.refresh(forceNetwork: true)
        case "c":
            await session.captureCurrentSession(.cursor)
        case "g":
            await session.captureCurrentSession(.chatgpt)
        case "l":
            await session.captureCurrentSession(.claude)
        case "vc":
            session.toggleVisible(.cursor)
        case "vg":
            session.toggleVisible(.chatgpt)
        case "vl":
            session.toggleVisible(.claude)
        default:
            if line.hasPrefix("x"), let index = Int(line.dropFirst()) {
                delete(index: index, session: session)
            } else if let index = Int(line) {
                await apply(index: index, session: session)
            }
        }
    }

    private static func apply(index: Int, session: UsageSession) async {
        let accounts = session.accounts
        guard index >= 1, index <= accounts.count else { return }
        await session.applyStoredAccount(accounts[index - 1].id)
    }

    private static func delete(index: Int, session: UsageSession) {
        let accounts = session.accounts
        guard index >= 1, index <= accounts.count else { return }
        session.removeAccount(accounts[index - 1].id)
    }

    private static func render(_ session: UsageSession) {
        let stamp = session.snapshot?.fetchedAt.formatted(date: .omitted, time: .standard) ?? "—"
        print("\u{001B}[2J\u{001B}[H", terminator: "")
        print("AI Usage    \(stamp)")
        print("r 새로고침 · c/g/l 세션 저장 · 번호 적용 · x번호 삭제 · vc/vg/vl 표시 · q 닫기")
        print("")
        for id in ProviderID.allCases {
            let provider = session.snapshot?.provider(id) ?? ProviderSnapshot.empty(
                id: id,
                displayName: id.displayName,
                leftLabel: id.leftLabel,
                rightLabel: id.rightLabel
            )
            let shown = session.visibleIDs.contains(id) ? "" : "  (숨김)"
            print(SidebarText.line(id: id, provider: provider) + shown)
            var detail: [String] = []
            if let plan = provider.planName, !plan.isEmpty { detail.append(plan) }
            if let account = provider.accountLabel, !account.isEmpty { detail.append(account) }
            if !detail.isEmpty {
                print("  " + detail.joined(separator: " · "))
            }
            if let message = provider.statusMessage, provider.status != .ok {
                print("  " + message)
            }
            let saved = session.accounts(for: id)
            if !saved.isEmpty {
                print("  저장한 계정")
                for account in saved {
                    let number = (session.accounts.firstIndex { $0.id == account.id } ?? 0) + 1
                    let mark = account.isActive ? "*" : " "
                    let plan = account.planName.map { " · \($0)" } ?? ""
                    print("  \(mark)\(number) \(account.displayName)\(plan)")
                }
            }
            print("")
        }
        if let notice = session.notice {
            print(notice)
            print("")
        }
        print("> ", terminator: "")
        fflush(stdout)
    }
}
