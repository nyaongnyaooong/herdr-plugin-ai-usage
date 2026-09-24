import AppKit
import SwiftUI
import AIUsageCore

struct PopoverView: View {
    @ObservedObject var session: UsageSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(ProviderID.allCases, id: \.self) { id in
                    card(session.snapshot?.provider(id) ?? ProviderSnapshot.empty(
                        id: id,
                        displayName: id.displayName,
                        leftLabel: id.leftLabel,
                        rightLabel: id.rightLabel
                    ))
                }
                if let notice = session.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("로그인 시 실행", isOn: launchAtLoginBinding)
                HStack {
                    Text("상태 표시줄 글꼴")
                    Spacer()
                    Picker("상태 표시줄 글꼴", selection: fontBinding) {
                        ForEach(MenuBarFontID.installed) { id in
                            Text(id.displayName)
                                .font(Font(id.nsFont(size: 13)))
                                .tag(id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                HStack {
                    Text(lastUpdated)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(session.canRefresh ? "새로고침" : "방금 갱신됨") {
                        Task { await session.refresh(forceNetwork: true) }
                    }
                    .disabled(!session.canRefresh)
                }
            }
            .padding(16)
        }
        .frame(width: 400)
        .frame(maxHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.controlActiveState, .key)
        .transaction { $0.animation = nil }
    }

    private var fontBinding: Binding<MenuBarFontID> {
        Binding(
            get: { session.menuBarFontID },
            set: { session.setMenuBarFont($0) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { LaunchAtLogin.isEnabled },
            set: { try? LaunchAtLogin.setEnabled($0) }
        )
    }

    private func visibleBinding(_ id: ProviderID) -> Binding<Bool> {
        Binding(
            get: { session.isVisible(id) },
            set: { session.setVisible(id, enabled: $0) }
        )
    }

    private var lastUpdated: String {
        guard let date = session.snapshot?.fetchedAt else { return "마지막 갱신 —" }
        return "마지막 갱신 \(Self.stamp.string(from: date))"
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy.MM.dd HH:mm"
        return formatter
    }()

    private func card(_ provider: ProviderSnapshot) -> some View {
        let saved = session.accounts(for: provider.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProviderIconView(id: provider.id)
                Text(provider.displayName).font(.headline)
                if saved.isEmpty, let plan = provider.planName {
                    Text(plan).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("상태 표시줄", isOn: visibleBinding(provider.id))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            if saved.isEmpty || !saved.contains(where: \.isActive) {
                if !saved.isEmpty {
                    Text("현재 세션 · 상태 표시줄")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                usageBlock(provider)
            }
            ForEach(saved) { account in
                accountRow(account)
            }
            Button(session.capturingProvider == provider.id ? "저장 중…" : "현재 세션 저장") {
                Task { await session.captureCurrentSession(provider.id) }
            }
            .controlSize(.small)
            .disabled(session.capturingProvider != nil)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func accountRow(_ account: ManagedAccount) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: account.isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(account.isActive ? Color.accentColor : Color.secondary)
                Text(account.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let plan = account.planName {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let usage = account.usage {
                usageBlock(usage)
            } else {
                Text("사용량을 아직 못 읽었습니다")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if account.isActive {
                    Button("세션 삭제") {
                        Task { await session.clearAppliedSession(account.provider) }
                    }
                    .controlSize(.small)
                } else {
                    Button(session.applyingAccountID == account.id ? "적용 중…" : "인증 적용") {
                        Task { await session.applyStoredAccount(account.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(session.applyingAccountID != nil)
                }
                Button("저장 삭제", role: .destructive) { session.removeAccount(account.id) }
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(6)
        .background(
            account.isActive ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    @ViewBuilder
    private func usageBlock(_ provider: ProviderSnapshot) -> some View {
        if provider.left.remainingPercent != nil {
            meterRow(provider.left)
        }
        if provider.right.remainingPercent != nil {
            meterRow(provider.right)
        }
        if let api = provider.api {
            HStack {
                Text(api.label)
                Spacer()
                Text(api.detail).fontWeight(.semibold)
            }
            .font(.caption)
        }
        if let message = provider.statusMessage {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func meterRow(_ meter: Meter) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(meter.label)
                Spacer()
                Text(meter.remainingPercent.map { "\($0)%" } ?? "—")
                if let resetsAt = meter.resetsAt {
                    Text(Self.stamp.string(from: resetsAt)).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            MeterBar(fraction: progress(meter.remainingPercent))
        }
    }

    private func progress(_ remaining: Int?) -> Double {
        guard let remaining else { return 0 }
        return Double(100 - remaining) / 100.0
    }
}

struct MeterBar: View {
    let fraction: Double

    private static let fill = Color(nsColor: NSColor(srgbRed: 0.20, green: 0.47, blue: 0.96, alpha: 1))

    var body: some View {
        let clamped = min(1, max(0, fraction))
        Capsule()
            .fill(Self.fill.opacity(0.18))
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Self.fill)
                    .scaleEffect(x: clamped, y: 1, anchor: .leading)
            }
            .clipShape(Capsule())
            .frame(height: 6)
            .animation(nil, value: fraction)
    }
}
