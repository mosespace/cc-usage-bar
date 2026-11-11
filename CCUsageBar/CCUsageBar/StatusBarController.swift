import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

final class StatusBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private let viewModels = [
        UsageViewModel(provider: .claude),
        UsageViewModel(provider: .codex),
    ]
    private let sessionMonitor = SessionUsageMonitor()
    private var rightClickMonitor: Any?
    private var rightClickMenu: NSMenu!
    private var refreshTimer: Timer?
    private var sessionTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        // Status item with SF Symbol icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()

        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.yaxis", accessibilityDescription: "AI Usage")
            button.image?.isTemplate = true  // Adapts to light/dark menu bar
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp])
            button.target = self
        }

        // Right-click context menu
        rightClickMenu = NSMenu()
        rightClickMenu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        rightClickMenu.items.forEach { $0.target = self }

        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let button = self.statusItem.button, event.window == button.window else {
                return event
            }
            self.statusItem.menu = self.rightClickMenu
            button.performClick(nil)
            self.statusItem.menu = nil
            return nil
        }

        // Popover hosting the stacked per-provider SwiftUI views
        popover.contentSize = NSSize(width: 520, height: 450)
        popover.behavior = .transient     // Dismiss on outside click
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: UsageStackView(viewModels: viewModels, sessionMonitor: sessionMonitor))

        // Size the popover to what's actually visible (installed CLIs + sessions).
        viewModels.forEach { vm in
            vm.$state.sink { [weak self] _ in
                DispatchQueue.main.async { self?.updatePopoverHeight() }
            }.store(in: &cancellables)
        }
        sessionMonitor.$sessions.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updatePopoverHeight() }
        }.store(in: &cancellables)
        updatePopoverHeight()

        // Prefetch on launch so data is cached before the first click, then refresh
        // periodically in the background to keep it reasonably fresh.
        viewModels.forEach { $0.run(force: true) }
        sessionMonitor.refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.viewModels.forEach { $0.run(force: true) }
            }
        }

        KeyboardShortcuts.onKeyUp(for: .toggleUsagePopover) { [weak self] in
            self?.togglePopover(nil)
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        viewModels.forEach { $0.dismissPopover() }
        sessionTimer?.invalidate()
        sessionTimer = nil
    }

    private func updatePopoverHeight() {
        var height: CGFloat = 0
        for vm in viewModels {
            if case .notInstalled = vm.state { continue }
            height += PopoverLayout.providerHeight(vm.provider.id)
            if vm.provider.id == "claude" {
                height += PopoverLayout.sessionsHeight(count: sessionMonitor.sessions.count)
            }
        }
        guard height > 0, popover.contentSize.height != height else { return }
        popover.contentSize = NSSize(width: 520, height: height)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            guard let button = statusItem.button else { return }
            viewModels.forEach { $0.run() }
            sessionMonitor.refresh()
            // Keep session token counts live while the popover is open.
            sessionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionMonitor.refresh() }
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

}
