import Foundation
import AIUsageHerdrKit

@main
enum AIUsageHerdrMain {
    static func main() {
        let command = CommandLine.arguments.dropFirst().first ?? "dashboard"
        if command == "status" {
            print(StatusLine.current())
            return
        }
        if command == "statusbar" {
            Task { await StatusBar.run() }
            dispatchMain()
        } else if command == "watch" {
            Task { @MainActor in
                let session = UsageSession()
                StatusPaneKeeper.ensure(repairRatio: true, allWorkspaces: true)
                await session.refresh(forceNetwork: true)
                var ticks = 0
                while true {
                    StatusPaneKeeper.ensure(repairRatio: ticks % 10 == 0)
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    ticks += 1
                    if ticks >= 1500 {
                        ticks = 0
                        await session.refresh(forceNetwork: false)
                    }
                }
            }
            dispatchMain()
        }
        let box = CommandBox(command)
        Task { @MainActor in
            await box.run()
            exit(0)
        }
        dispatchMain()
    }
}

private struct CommandBox: Sendable {
    let command: String
    init(_ command: String) { self.command = command }

    @MainActor
    func run() async {
        let session = UsageSession()
        if command == "refresh" {
            await session.refresh(forceNetwork: true)
            for id in session.orderedVisibleIDs {
                print(SidebarText.line(id: id, provider: session.snapshot?.provider(id)))
            }
            return
        }
        await Dashboard.run(session)
    }
}
