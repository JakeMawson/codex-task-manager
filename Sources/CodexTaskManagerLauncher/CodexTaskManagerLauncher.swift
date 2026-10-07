import AppKit
import Darwin
import IndependentAppLaunch

@main
@MainActor
enum CodexTaskManagerLauncher {
    private static let agentID = "com.jakemawson.codex-task-manager.menuagent"
    private static let reopen = Notification.Name("com.jakemawson.codex-task-manager.menuagent.show-tasks")

    static func main() {
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
}
