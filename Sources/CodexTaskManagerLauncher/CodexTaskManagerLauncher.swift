import AppKit
import Darwin
import IndependentAppLaunch
import ServiceManagement

@main
@MainActor
enum CodexTaskManagerLauncher {
    private static let agentID = "com.jakemawson.codex-task-manager.menuagent"
    private static let reopen = Notification.Name("com.jakemawson.codex-task-manager.menuagent.show-tasks")

    static func main() {
        if CommandLine.arguments.dropFirst().first == "--login-startup" {
            manageLoginStartup()
            return
        }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: agentID).first {
            DistributedNotificationCenter.default().postNotificationName(
                reopen, object: nil, userInfo: nil, deliverImmediately: true
            )
            running.activate(options: [.activateAllWindows])
            return
        }

        // The helper is part of this signed app, with a fixed local path.
        // No release metadata or external command supplies executable input.
        let executable = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/LoginItems/CodexTaskManagerMenuAgent.app/Contents/MacOS/CodexTaskManager"
        )
        let arguments: [UnsafeMutablePointer<CChar>?] =
            ([executable.path] + CommandLine.arguments.dropFirst()).map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        var pid: pid_t = 0
        let result = arguments.withUnsafeBufferPointer { buffer in
            executable.path.withCString { path in ctm_launch_independent(path, buffer.baseAddress, &pid) }
        }
        guard result == 0 else {
            NSLog("Codex Task Manager could not launch its menu agent (error %d)", result)
            let alert = NSAlert()
            alert.messageText = "Codex Task Manager could not start"
            alert.informativeText = "Reinstall the app and try opening it again. If this continues, report launch error \(result)."
            alert.runModal()
            return
        }
    }

    private static func manageLoginStartup() {
        let service = SMAppService.mainApp
        var errorMessage: String?
        do {
            guard CommandLine.arguments.count == 3 else { throw StartupCommandError.invalidAction }
            switch CommandLine.arguments[2] {
            case "status": break
            case "enable":
                if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            case "disable":
                if service.status != .notRegistered { try service.unregister() }
            default: throw StartupCommandError.invalidAction
            }
        } catch { errorMessage = error.localizedDescription }
        let status: String
        switch service.status {
        case .enabled: status = "enabled"
        case .notRegistered: status = "notRegistered"
        case .requiresApproval: status = "requiresApproval"
        case .notFound: status = "notFound"
        @unknown default: status = "notFound"
        }
        var reply = ["status": status]
        if let errorMessage { reply["error"] = String(errorMessage.prefix(500)) }
        if let data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
        }
    }

    private enum StartupCommandError: LocalizedError {
        case invalidAction
        var errorDescription: String? { "Unsupported login startup command." }
    }
}
