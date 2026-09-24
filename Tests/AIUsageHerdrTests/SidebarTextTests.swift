import Foundation
import Testing
@testable import AIUsageHerdrKit
import AIUsageCore

struct SidebarTextTests {
    @Test func meterLineUsesMenuBarLabels() {
        let provider = ProviderSnapshot(
            id: .cursor,
            displayName: "Cursor",
            status: .ok,
            left: Meter(label: "Auto", remainingPercent: 82),
            right: Meter(label: "Other", remainingPercent: 41)
        )
        #expect(SidebarText.line(id: .cursor, provider: provider) == "Cursor Auto 82% · Other 41%")
    }

    @Test func omitsMissingMeter() {
        let provider = ProviderSnapshot(
            id: .chatgpt,
            displayName: "ChatGPT",
            status: .ok,
            left: Meter(label: "5시간", remainingPercent: 90),
            right: Meter(label: "주간")
        )
        #expect(SidebarText.line(id: .chatgpt, provider: provider) == "ChatGPT 5h 90%")
    }

    @Test func apiDetailWhenPercentsMissing() {
        let provider = ProviderSnapshot(
            id: .claude,
            displayName: "Claude",
            status: .ok,
            left: Meter(label: "5시간"),
            right: Meter(label: "주간"),
            api: APIMeter(label: "API", detail: "$1.20")
        )
        #expect(SidebarText.line(id: .claude, provider: provider) == "Claude API $1.20")
    }

    @Test func missingProviderStillNamesIt() {
        #expect(SidebarText.line(id: .claude, provider: nil) == "Claude 5h — · Weekly —")
    }

    @Test func statusLineJoinsVisibleProviders() {
        let snapshot = UsageSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 0),
            lastNetworkStartedAt: Date(timeIntervalSince1970: 0),
            providers: [
                ProviderSnapshot(
                    id: .cursor,
                    displayName: "Cursor",
                    status: .ok,
                    left: Meter(label: "Auto", remainingPercent: 77),
                    right: Meter(label: "Other", remainingPercent: 100)
                ),
                ProviderSnapshot(
                    id: .chatgpt,
                    displayName: "ChatGPT",
                    status: .ok,
                    left: Meter(label: "5시간"),
                    right: Meter(label: "주간", remainingPercent: 83)
                )
            ]
        )
        let line = StatusLine.format(snapshot: snapshot, visibleIDs: [.cursor, .chatgpt])
        #expect(line == "Cursor Auto 77% · Other 100%  ChatGPT Weekly 83%")
    }

    @Test func statusBarFillsTenCells() {
        #expect(StatusBar.bar(75) == "████████░░")
        #expect(StatusBar.bar(100) == "██████████")
        #expect(StatusBar.bar(nil) == "··········")
    }

    @Test func statusBarNamesProviders() {
        let snapshot = UsageSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 0),
            lastNetworkStartedAt: Date(timeIntervalSince1970: 0),
            providers: [
                ProviderSnapshot(
                    id: .cursor,
                    displayName: "Cursor",
                    status: .ok,
                    left: Meter(label: "Auto", remainingPercent: 75),
                    right: Meter(label: "Other", remainingPercent: 100)
                )
            ]
        )
        let frame = StatusBar.render(snapshot: snapshot, visibleIDs: [.cursor])
        #expect(frame.contains("Cursor"))
        #expect(frame.contains("75%"))
        #expect(frame.contains("████████░░"))
    }

    @Test func statusBarOmitsDisconnectedProviders() {
        let snapshot = UsageSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 0),
            lastNetworkStartedAt: Date(timeIntervalSince1970: 0),
            providers: [
                ProviderSnapshot(
                    id: .cursor,
                    displayName: "Cursor",
                    status: .ok,
                    left: Meter(label: "Auto", remainingPercent: 73),
                    right: Meter(label: "Other", remainingPercent: 100)
                ),
                ProviderSnapshot.empty(id: .chatgpt, displayName: "ChatGPT", leftLabel: "5시간", rightLabel: "주간")
            ]
        )
        let frame = StatusBar.render(snapshot: snapshot, visibleIDs: [.cursor, .chatgpt, .claude])
        #expect(frame.contains("Cursor"))
        #expect(!frame.contains("ChatGPT"))
        #expect(!frame.contains("Claude"))
    }

    @Test func statusBarHidesWeeklyOnlyFiveHourMeter() {
        let snapshot = UsageSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 0),
            lastNetworkStartedAt: Date(timeIntervalSince1970: 0),
            providers: [
                ProviderSnapshot(
                    id: .chatgpt,
                    displayName: "ChatGPT",
                    planName: "pro",
                    status: .ok,
                    left: Meter(label: "5시간"),
                    right: Meter(label: "주간", remainingPercent: 70, resetsAt: Date(timeIntervalSince1970: 1_758_900_779))
                )
            ]
        )
        let frame = StatusBar.render(snapshot: snapshot, visibleIDs: [.chatgpt])
        #expect(frame.contains("Weekly"))
        #expect(frame.contains("70%"))
        #expect(frame.contains("███████░░░"))
        #expect(frame.contains(StatusBar.resetText(Date(timeIntervalSince1970: 1_758_900_779))))
        #expect(!frame.contains("5h"))
        #expect(!frame.contains("··········"))
    }

    @Test func resetTextUsesLocalDateAndTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 60 * 60)!
        let date = Date(timeIntervalSince1970: 1_758_900_779)
        #expect(StatusBar.resetText(date, calendar: calendar) == "reset 09/27 00:32")
    }

    @Test func statusBarShowsClaudeAPICost() {
        let snapshot = UsageSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 0),
            lastNetworkStartedAt: Date(timeIntervalSince1970: 0),
            providers: [
                ProviderSnapshot(
                    id: .claude,
                    displayName: "Claude",
                    planName: "API",
                    status: .ok,
                    left: Meter(label: "5시간"),
                    right: Meter(label: "주간"),
                    api: APIMeter(label: "이번 달", detail: "$12.00")
                )
            ]
        )
        let frame = StatusBar.render(snapshot: snapshot, visibleIDs: [.claude])
        let monthEnd = ClaudeUsageMapper.monthBounds(now: Date()).1
        #expect(frame.contains("Monthly"))
        #expect(frame.contains("$12.00"))
        #expect(frame.contains(StatusBar.resetText(monthEnd)))
        #expect(!frame.contains("5h"))
        #expect(!frame.contains("Weekly"))
    }

    @Test func statusBarAlignsValueColumns() {
        let snapshot = UsageSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 0),
            lastNetworkStartedAt: Date(timeIntervalSince1970: 0),
            providers: [
                ProviderSnapshot(
                    id: .cursor,
                    displayName: "Cursor",
                    status: .ok,
                    left: Meter(label: "Auto", remainingPercent: 71),
                    right: Meter(label: "Other", remainingPercent: 100)
                ),
                ProviderSnapshot(
                    id: .chatgpt,
                    displayName: "ChatGPT",
                    status: .ok,
                    left: Meter(label: "5시간"),
                    right: Meter(label: "주간", remainingPercent: 63)
                ),
                ProviderSnapshot(
                    id: .claude,
                    displayName: "Claude",
                    planName: "API",
                    status: .ok,
                    left: Meter(label: "5시간"),
                    right: Meter(label: "주간"),
                    api: APIMeter(label: "이번 달", detail: "$804.04")
                )
            ]
        )
        func plain(_ text: String) -> String {
            var result = ""
            var skipping = false
            for char in text {
                if char == "\u{1b}" {
                    skipping = true
                    continue
                }
                if skipping {
                    if char == "m" { skipping = false }
                    continue
                }
                result.append(char)
            }
            return result
        }
        let lines = plain(StatusBar.render(snapshot: snapshot, visibleIDs: [.cursor, .chatgpt, .claude]))
            .split(separator: "\n")
            .map(String.init)
        let columns = lines.compactMap { line -> Int? in
            let marker = ["71%", "63%", "$804.04"].first { line.contains($0) }
            guard let marker, let range = line.range(of: marker) else { return nil }
            return line.distance(from: line.startIndex, to: range.lowerBound)
        }
        #expect(columns.count == 3)
        #expect(Set(columns).count == 1)
        let bars = lines.prefix(2).compactMap { line -> Int? in
            guard let range = line.range(of: "█") else { return nil }
            return line.distance(from: line.startIndex, to: range.lowerBound)
        }
        #expect(bars.count == 2)
        #expect(Set(bars).count == 1)
    }

    @Test func sidebarFitsNarrowSpacesRow() {
        let cursor = ProviderSnapshot(
            id: .cursor,
            displayName: "Cursor",
            status: .ok,
            left: Meter(label: "Auto", remainingPercent: 72),
            right: Meter(label: "Other", remainingPercent: 100)
        )
        let chatgpt = ProviderSnapshot(
            id: .chatgpt,
            displayName: "ChatGPT",
            planName: "pro",
            status: .ok,
            left: Meter(label: "5시간"),
            right: Meter(label: "주간", remainingPercent: 66)
        )
        let claude = ProviderSnapshot(
            id: .claude,
            displayName: "Claude",
            planName: "API",
            status: .ok,
            left: Meter(label: "5시간"),
            right: Meter(label: "주간"),
            api: APIMeter(label: "이번 달", detail: "$804.04")
        )
        #expect(SidebarText.sidebar(id: .cursor, provider: cursor) == "72%·100%")
        #expect(SidebarText.sidebar(id: .chatgpt, provider: chatgpt) == "66%")
        #expect(SidebarText.sidebar(id: .claude, provider: claude) == "$804.04")
        #expect(SidebarText.sidebar(id: .claude, provider: ProviderSnapshot.empty(
            id: .claude,
            displayName: "Claude",
            leftLabel: "5시간",
            rightLabel: "주간"
        )) == nil)
    }
}

struct WorkspaceListTests {
    @Test func readsWorkspaceIDs() throws {
        let raw = #"{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[{"workspace_id":"w2"},{"label":"skip"},{"workspace_id":"w5"}]}}"#
        let ids = WorkspaceList.ids(from: Data(raw.utf8))
        #expect(ids == ["w2", "w5"])
    }
}
