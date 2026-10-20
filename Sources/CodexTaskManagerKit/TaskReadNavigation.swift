import AppKit
import ApplicationServices

public struct TaskReadReturn {
    let isSafe: @MainActor () -> Bool
    let perform: @MainActor () throws -> Void
    let finish: @MainActor () -> Void
    public init(isSafe: @escaping @MainActor () -> Bool, perform: @escaping @MainActor () throws -> Void,
                finish: @escaping @MainActor () -> Void = {}) {
        self.isSafe = isSafe; self.perform = perform; self.finish = finish
    }
}

@MainActor public protocol TaskReadNavigating {
    func openChat(_ id: String) throws
    func prepareReturn() throws -> TaskReadReturn?
}

enum TaskReadError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case let .failed(message) = self { message } else { nil } }
}

@MainActor final class NativeTaskReadNavigation: TaskReadNavigating {
    static var accessibilityAvailable: Bool { AXIsProcessTrusted() }
    static func requestAccessibility() {
        // The SDK exports this immutable option as a mutable C global, which
        // Swift 6 rejects under strict concurrency. Use its fixed CF key.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func openChat(_ id: String) throws {
        guard let url = CodexDeepLink.url(for: id), NSWorkspace.shared.open(url) else {
            throw TaskReadError.failed("Codex could not open this chat.")
        }
    }

    func prepareReturn() throws -> TaskReadReturn? {
        guard Self.accessibilityAvailable else {
            throw TaskReadError.failed("Return to prior chat needs Accessibility access. Enable it in Settings, or turn automatic return off.")
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let originalWindow = Self.window(element) else { return nil }
        let counters = Self.inputCounters()
        let startingPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var sawCodex = false
        let focus = ReadFocusObservation(codexPID: app.processIdentifier, initialPID: startingPID)
        let center = NSWorkspace.shared.notificationCenter
        let observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { notification in
            guard let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { focus.activated(activated.processIdentifier) }
        }
        let safe: @MainActor () -> Bool = {
            guard !focus.cancelled, !app.isTerminated, Self.inputCounters() == counters else { return false }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if front == app.processIdentifier { sawCodex = true }
            else if sawCodex || front != startingPID { return false }
            guard let currentWindow = Self.window(element), CFEqual(originalWindow, currentWindow) else { return false }
            return true
        }
        return TaskReadReturn(isSafe: safe, perform: {
            guard safe(), NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                throw TaskReadError.failed("Automatic return cancelled because the active app or input changed.")
            }
            guard let menu = Self.attribute(element, kAXMenuBarAttribute), CFGetTypeID(menu) == AXUIElementGetTypeID() else {
                throw TaskReadError.failed("Codex’s navigation menu is unavailable. Stay in this chat and use Back manually.")
            }
            var budget = 400
            guard let back = Self.backItem(menu as! AXUIElement, depth: 0, budget: &budget),
                  AXUIElementPerformAction(back, kAXPressAction as CFString) == .success else {
                throw TaskReadError.failed("Codex’s Back command is unavailable. This chat is read; use Back manually.")
            }
        }, finish: { center.removeObserver(observer) })
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    private static func window(_ app: AXUIElement) -> AXUIElement? {
        guard let value = attribute(app, kAXMainWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func inputCounters() -> [UInt32] {
        // Counts only; never read keystrokes, pointer positions or clipboard.
        [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown,
         .otherMouseDown, .scrollWheel, .mouseMoved].map {
            CGEventSource.counterForEventType(.combinedSessionState, eventType: $0)
        }
    }
    private static func backItem(_ element: AXUIElement, depth: Int, budget: inout Int) -> AXUIElement? {
        guard depth < 8, budget > 0 else { return nil }
        budget -= 1
        let role = attribute(element, kAXRoleAttribute) as? String
        let title = attribute(element, kAXTitleAttribute) as? String
        if role == kAXMenuItemRole,
           title == "Back" || title == "Go Back",
           attribute(element, kAXEnabledAttribute) as? Bool == true { return element }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let found = backItem(child, depth: depth + 1, budget: &budget) { return found }
        }
        return nil
    }
}

@MainActor private final class ReadFocusObservation {
    let codexPID: pid_t
    let initialPID: pid_t?
    var sawCodex = false
    var cancelled = false
    init(codexPID: pid_t, initialPID: pid_t?) { self.codexPID = codexPID; self.initialPID = initialPID }
    func activated(_ pid: pid_t) {
        if pid == codexPID { sawCodex = true }
        else if sawCodex || pid != initialPID { cancelled = true }
    }
}
