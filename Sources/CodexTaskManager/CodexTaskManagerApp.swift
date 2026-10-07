import CodexTaskManagerKit
import AppKit
import SwiftUI

@main @MainActor
enum CodexTaskManagerMain {
    // NSApplication retains its delegate weakly. Keep the delegate, and hence
    // its status item, alive for the complete native application run loop.
    private static let appDelegate = AppDelegate()

    static func main() {
        if Bundle.main.bundleIdentifier == "com.jakemawson.codex-task-manager.menubar",
           !CommandLine.arguments.contains("--qa-fixture"),
           !CommandLine.arguments.contains("--qa-no-response") {
            TaskManagerPreferencesMigration.migrate(
                into: .standard,
                legacyDomains: [UserDefaults.standard.persistentDomain(forName: "com.jakemawson.codex-task-manager") ?? [:]]
            )
        }
        let application = NSApplication.shared
        application.delegate = appDelegate
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let taskManagerModel = TaskManagerModel()

    private var statusItem: NSStatusItem?
    private lazy var statusPopover = NSPopover()
    private var previewWindow: NSWindow?
    private var statusRefreshTimer: Timer?
    private var registrationAttempt = 0
    private var outsideClickMonitors: [Any] = []
    private static let reopenNotification = Notification.Name("com.jakemawson.codex-task-manager.show-tasks")

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !handOffToExistingInstance() else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        installApplicationMenu()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showTasks(_:)), name: Self.reopenNotification, object: nil
        )
        installStatusItem()
    }

    private func handOffToExistingInstance() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains(where: { $0.processIdentifier != currentPID }) else { return false }
        DistributedNotificationCenter.default().postNotificationName(
            Self.reopenNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
        NSApplication.shared.terminate(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Codex Task Manager")
        let quit = NSMenuItem(title: "Quit Codex Task Manager", action: #selector(quitApplication(_:)), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")
        ] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApplication.shared.mainMenu = menu
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        // Let AppKit register the retained item before SwiftUI hosting and task
        // refresh begin. QuotaWise uses this same native startup ordering.
        DispatchQueue.main.async { [weak self, weak item] in
            guard let self, let item, self.statusItem === item else { return }
            self.configureStatusItem(item)
        }
    }

    private func configureStatusItem(_ item: NSStatusItem) {
        guard !CommandLine.arguments.contains("--qa-status-item-registration-failure"),
              let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            guard registrationAttempt == 0 else {
                logLifecycle("registration failed after one retry; terminating")
                NSApplication.shared.terminate(nil)
                return
            }
            registrationAttempt += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.installStatusItem()
            }
            return
        }

        button.image = NSImage(systemSymbolName: "list.bullet.rectangle.fill", accessibilityDescription: "Codex Task Manager")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.toolTip = "Codex Task Manager"
        button.setAccessibilityLabel("Codex Task Manager")
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])

        // The outside-click monitor below owns dismissal. A transient popover
        // can dismiss itself before the status-item action receives the click,
        // which makes a second click look like it did nothing.
        statusPopover.behavior = .applicationDefined
        statusPopover.animates = false
        if outsideClickMonitors.isEmpty {
            installOutsideClickMonitors()
            installEscapeKeyMonitor()
        }
        Self.taskManagerModel.startBackgroundRefresh()
        refreshStatusSummary()
        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStatusSummary() }
        }
        logLifecycle("status item configured")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak item] in
            guard let self, let item, self.statusItem === item else { return }
            // Enabling removal termination during registration can terminate a
            // valid new item before macOS has finished publishing it.
            item.behavior.insert(.terminationOnRemoval)
            self.logLifecycle("status item registration settled")
            if CommandLine.arguments.contains("--qa-status-item-loss") {
                NSStatusBar.system.removeStatusItem(item)
                NSApplication.shared.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--qa-menu") { presentPreview() }
        if CommandLine.arguments.contains("--qa-open-popover") { showTasks(nil) }
    }

    private func refreshStatusSummary() {
        guard let button = statusItem?.button else { return }
        let model = Self.taskManagerModel
        let needs = model.attentionCount
        let running = model.stateCount(.running)
        let complete = model.stateCount(.complete)
        button.title = needs > 0 ? " \(needs)" : ""
        button.toolTip = "Codex Task Manager · \(needs) need you · \(running) running · \(complete) complete"
        button.setAccessibilityLabel(button.toolTip!)
    }

    private func logLifecycle(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("[Codex Task Manager] \(message)\n".utf8))
    }

    private func presentPreview() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 392, height: 672),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Codex Task Manager Preview"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: TaskManagerPanel(model: Self.taskManagerModel))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        previewWindow = window
    }

    @objc private func showTasks(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if !statusPopover.isShown {
            resetStatusPopoverContent()
            NSApplication.shared.activate(ignoringOtherApps: true)
            statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            statusPopover.contentViewController?.view.window?.makeKey()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Activation from an ordinary status click is not an explicit reopen:
        // let the click handler own its toggle instead of opening it twice.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusRefreshTimer?.invalidate()
        statusPopover.close()
        for monitor in outsideClickMonitors { NSEvent.removeMonitor(monitor) }
        outsideClickMonitors.removeAll()
        DistributedNotificationCenter.default().removeObserver(self)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        if NSApplication.shared.currentEvent?.type == .rightMouseDown {
            showStatusItemMenu()
        } else {
            toggleStatusPopover(sender)
        }
    }

    private func toggleStatusPopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if statusPopover.isShown {
            statusPopover.close()
        } else {
            // A popover can be dismissed while a SwiftUI sheet is being torn
            // down. Rehosting makes every new opening start without stale
            // sheet-presentation state.
            resetStatusPopoverContent()
            NSApplication.shared.activate(ignoringOtherApps: true)
            statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            statusPopover.contentViewController?.view.window?.makeKey()
        }
    }

    private func resetStatusPopoverContent() {
        statusPopover.contentViewController = NSHostingController(
            rootView: TaskManagerPanel(model: Self.taskManagerModel)
        )
        _ = statusPopover.contentViewController?.view
    }

    private func installOutsideClickMonitors() {
        let closeForLocalEvent: (NSEvent) -> Void = { [weak self] event in
            guard let self, self.statusPopover.isShown else { return }
            guard let eventWindow = event.window else { return }
            guard !self.isInsideStatusUI(eventWindow) else { return }
            self.statusPopover.close()
        }
        if let localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { event in
            closeForLocalEvent(event)
            return event
        }) {
            outsideClickMonitors.append(localMonitor)
        }
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] _ in
            // Global monitor events originate outside this app and do not carry
            // a usable local window. They are always click-offs for the status
            // popover, including clicks in another app's window or popup.
            guard let self, self.statusPopover.isShown else { return }
            self.statusPopover.close()
        }) {
            outsideClickMonitors.append(globalMonitor)
        }
    }

    private func installEscapeKeyMonitor() {
        if let escapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                guard let self else { return event }
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                   event.charactersIgnoringModifiers == "q" {
                    self.quitApplication(nil)
                    return nil
                }
                guard event.keyCode == 53, self.statusPopover.isShown else {
                    return event
                }

                // Let the attached editor sheet receive Escape first. Its
                // Cancel button owns the cancellation shortcut, leaving the
                // popover open for a second Escape to dismiss.
                if self.statusPopover.contentViewController?.view.window?.attachedSheet != nil {
                    return event
                }

                self.statusPopover.close()
                return nil
            }
        ) {
            outsideClickMonitors.append(escapeMonitor)
        }
    }

    private func isInsideStatusUI(_ window: NSWindow) -> Bool {
        guard let popoverWindow = statusPopover.contentViewController?.view.window else {
            return window === statusItem?.button?.window
        }

        if window === popoverWindow || window === statusItem?.button?.window {
            return true
        }

        // SwiftUI presents the project-arrangement view as a sheet with its
        // own NSWindow. Keep the parent popover alive while that sheet, or
        // any nested sheet, is receiving the interaction.
        var candidate: NSWindow? = window
        while let current = candidate {
            if current === popoverWindow {
                return true
            }
            candidate = current.sheetParent
        }

        return popoverWindow.sheets.contains { $0 === window }
            || popoverWindow.childWindows?.contains { $0 === window } == true
    }

    private func showStatusItemMenu() {
        guard let button = statusItem?.button else { return }
        statusPopover.close()

        let menu = NSMenu()
        let showItem = NSMenuItem(title: "Show tasks", action: #selector(showTasks(_:)), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        let refreshItem = NSMenuItem(title: "Refresh tasks", action: #selector(refreshTasks(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit Codex Task Manager",
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func quitApplication(_ sender: Any?) {
        NSApplication.shared.terminate(sender)
    }

    @objc private func refreshTasks(_ sender: Any?) {
        Task { await Self.taskManagerModel.refresh() }
    }
}
