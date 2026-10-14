import Foundation
import AIUsageCore

@MainActor
public enum Dashboard {
    public static func run(_ session: UsageSession) async {
        let input = DashboardInput()
        defer { input.restore() }
        await session.refresh(forceNetwork: true)
        HerdrClient.publish(snapshot: session.snapshot, visibleIDs: session.orderedVisibleIDs)
        var pending = ""
        var selected = 0
        while true {
            selected = min(selected, max(0, session.accounts.count - 1))
            render(session, selected: selected, pending: pending)
            let line: String
            if input.isInteractive {
                guard let key = input.readKey() else { return }
                switch key {
                case .quit: return
                case .up:
                    selected = max(0, selected - 1)
                    pending = ""
                    continue
                case .down:
                    selected = min(max(0, session.accounts.count - 1), selected + 1)
                    pending = ""
                    continue
                case .escape:
                    pending = ""
                    continue
                case .backspace:
                    if !pending.isEmpty { pending.removeLast() }
                    continue
                case .ignored: continue
                case .enter:
                    line = pending.isEmpty ? String(selected + 1) : pending
                    pending = ""
                case .character(let character):
                    if character == "q" { return }
                    if character == "v" || character == "x" {
                        pending = character
                        continue
                    }
                    if character.allSatisfy({ $0.isNumber }) {
                        if pending == "v" { pending = "" }
                        pending += character
                        continue
                    }
                    if pending == "v", ["c", "g", "l"].contains(character) {
                        line = pending + character
                    } else {
                        line = character
                    }
                    pending = ""
                }
            } else {
                guard let value = readLine() else { return }
                line = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    private static func render(_ session: UsageSession, selected: Int, pending: String) {
        let stamp = session.snapshot?.fetchedAt.formatted(date: .omitted, time: .standard) ?? "—"
        print("\u{001B}[2J\u{001B}[H", terminator: "")
        print("AI Usage    \(stamp)")
        print("r 새로고침 · c/g/l 세션 저장 · ↑↓ 선택 · Enter 적용 · 번호+Enter 적용 · x번호+Enter 삭제 · vc/vg/vl 표시 · q 닫기")
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
                    let cursor = number == selected + 1 ? "▸" : " "
                    print("\(cursor) \(mark)\(number) \(account.displayName)\(plan)")
                }
            }
            print("")
        }
        if let notice = session.notice {
            print(notice)
            print("")
        }
        print("> " + pending, terminator: "")
        fflush(stdout)
    }
}
