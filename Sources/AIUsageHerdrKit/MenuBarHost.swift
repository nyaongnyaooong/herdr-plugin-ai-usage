import AppKit
import Combine
import SwiftUI

@MainActor
public enum MenuBarHost {
    public static func start() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = MenuBarDelegate.shared
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class MenuBarDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    static let shared = MenuBarDelegate()

    private let session = UsageSession()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?
    private var buttonAppearanceObservation: NSKeyValueObservation?
    private var popoverWindowObservers: [NSObjectProtocol] = []
    private weak var observedPopoverWindow: NSWindow?
    private var isLockingPopover = false
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "AIUsageHerdrStatusItem"
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleNone
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        let root = PopoverView(session: session)
            .environment(\.controlActiveState, .key)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.hasFullSizeContent = true
        popover.contentViewController = hosting
        popover.delegate = self
        self.popover = popover

        session.$snapshot
            .combineLatest(session.$visibleIDs, session.$menuBarFontID)
            .combineLatest(session.$accounts)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)

        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateStatusItem()
                if self?.popover?.isShown == true {
                    self?.lockPopoverOpaque()
                }
            }
        }
        buttonAppearanceObservation = item.button?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateStatusItem()
            }
        }

        updateStatusItem()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.session.refresh(forceNetwork: false)
            }
        }
        Task { await session.refresh(forceNetwork: true) }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let visible = session.orderedVisibleIDs
        button.image = StatusItemArtwork.image(
            snapshot: session.snapshot,
            visibleIDs: visible,
            fontID: session.menuBarFontID,
            appearance: button.effectiveAppearance
        )
        button.toolTip = StatusItemArtwork.tooltip(snapshot: session.snapshot, visibleIDs: visible)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            makePopoverKey()
            lockPopoverOpaque()
        }
    }

    private func makePopoverKey() {
        guard let window = popover?.contentViewController?.view.window else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func lockPopoverOpaque() {
        guard popover?.isShown == true else { return }
        guard !isLockingPopover else { return }
        isLockingPopover = true
        defer { isLockingPopover = false }
        guard let content = popover?.contentViewController?.view else { return }
        if let window = content.window {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            observePopoverWindow(window)
        }
        paintOpaque(content)
        if let chrome = content.superview {
            paintOpaque(chrome)
            lockEffects(in: chrome)
            if let parent = chrome.superview {
                paintOpaque(parent)
                lockEffects(in: parent)
            }
        }
    }

    private func paintOpaque(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    private func lockEffects(in view: NSView) {
        if let effect = view as? NSVisualEffectView {
            effect.state = .active
            effect.isEmphasized = true
            effect.material = .windowBackground
            effect.blendingMode = .withinWindow
        }
        let typeName = NSStringFromClass(type(of: view))
        if typeName.contains("Glass") {
            paintOpaque(view)
        }
        view.subviews.forEach(lockEffects)
    }

    private func observePopoverWindow(_ window: NSWindow) {
        guard window !== observedPopoverWindow else { return }
        removePopoverWindowObservers()
        observedPopoverWindow = window
        let names: [Notification.Name] = [
            NSWindow.didResignKeyNotification,
            NSWindow.didResignMainNotification,
            NSWindow.didBecomeKeyNotification
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.lockPopoverOpaque()
                }
            }
            popoverWindowObservers.append(token)
        }
    }

    private func removePopoverWindowObservers() {
        for token in popoverWindowObservers {
            NotificationCenter.default.removeObserver(token)
        }
        popoverWindowObservers.removeAll()
        observedPopoverWindow = nil
    }

    func popoverDidShow(_ notification: Notification) {
        makePopoverKey()
        lockPopoverOpaque()
        DispatchQueue.main.async { [weak self] in
            self?.makePopoverKey()
            self?.lockPopoverOpaque()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removePopoverWindowObservers()
    }
}
