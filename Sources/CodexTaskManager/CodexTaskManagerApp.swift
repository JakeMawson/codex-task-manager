import CodexTaskManagerKit
import AppKit
import SwiftUI

@main
struct CodexTaskManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppDelegate.taskManagerModel
    private let showMenuForQA = CommandLine.arguments.contains("--qa-menu")

    var body: some Scene {
        Window("Codex Task Manager Preview", id: "menu-preview") {
            TaskManagerPanel(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(showMenuForQA ? .presented : .suppressed)

        Settings {
            ProjectOrderView(model: model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let taskManagerModel = TaskManagerModel()

    private var statusItem: NSStatusItem?
    private let statusPopover = NSPopover()
    private var userRequestedTermination = false
    private var outsideClickMonitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isQALaunch = CommandLine.arguments.contains("--qa-menu")
        NSApplication.shared.setActivationPolicy(isQALaunch ? .regular : .accessory)
        installStatusItem()
        Self.taskManagerModel.startBackgroundRefresh()
        if isQALaunch {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        userRequestedTermination ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        button.image = NSImage(systemSymbolName: "list.bullet.rectangle.fill", accessibilityDescription: "Codex Task Manager")
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
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
        resetStatusPopoverContent()
        statusItem = item

        installOutsideClickMonitors()
        installEscapeKeyMonitor()
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
                guard let self, event.keyCode == 53, self.statusPopover.isShown else {
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
        userRequestedTermination = true
        NSApplication.shared.terminate(sender)
    }
}
