import AppKit
import Foundation
import Observation
import ServiceManagement

enum LoginStartupStatus: String, Decodable, Sendable {
    case enabled, notRegistered, requiresApproval, notFound
}

@MainActor protocol LoginStartupServicing {
    func status() async throws -> LoginStartupStatus
    func setEnabled(_ enabled: Bool) async throws -> LoginStartupStatus
    func openSystemSettings()
}

/// The outer launcher owns SMAppService.mainApp; calling it from the nested
/// menu agent would register the wrong app. Only our fixed installed launcher
/// may run these fixed commands. No shell or remote metadata is involved.
@MainActor struct NativeLoginStartupService: LoginStartupServicing {
    let launcher: URL?
    let runner: any AppUpdateCommandRunning

    init(bundle: Bundle = .main, runner: any AppUpdateCommandRunning = AppUpdateCommandRunner()) {
        self.runner = runner
        let outer = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        if bundle.bundleIdentifier == InstalledTaskManagerLifecycle.agentID,
           outer.path == InstalledTaskManagerLifecycle.appPath,
           Bundle(url: outer)?.bundleIdentifier == InstalledTaskManagerLifecycle.bundleID {
            launcher = outer.appendingPathComponent("Contents/MacOS/CodexTaskManagerLauncher")
        } else { launcher = nil }
    }

    func status() async throws -> LoginStartupStatus { try await command("status") }
    func setEnabled(_ enabled: Bool) async throws -> LoginStartupStatus {
        try await command(enabled ? "enable" : "disable")
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func command(_ action: String) async throws -> LoginStartupStatus {
        guard let launcher else { throw StartupError.notInstalled }
        let output = try await runner.run(launcher.path, arguments: ["--login-startup", action])
        let reply = try JSONDecoder().decode(Reply.self, from: Data(output.utf8))
        if let error = reply.error { throw StartupError.operation(error) }
        return reply.status
    }
    private struct Reply: Decodable { let status: LoginStartupStatus; let error: String? }
    private enum StartupError: LocalizedError {
        case notInstalled, operation(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: "Install Codex Task Manager in Applications to manage login startup."
            case .operation(let detail): "macOS couldn’t change login startup. \(detail)"
            }
        }
    }
}

@MainActor @Observable public final class LoginStartupModel {
    public static let shared = LoginStartupModel()
    static let preferenceKey = "CodexTaskManager.startOnBoot.v1"
    static let attemptedKey = "CodexTaskManager.startOnBootDefaultAttempted.v1"
    private let defaults: UserDefaults
    private let service: any LoginStartupServicing
    private var started = false
    private(set) var status: LoginStartupStatus = .notRegistered
    public private(set) var busy = false
    public private(set) var message: String?
    public var isOn: Bool { status == .enabled || status == .requiresApproval }
    public var needsApproval: Bool { status == .requiresApproval }
    public var statusText: String {
        switch status {
        case .enabled: "Enabled at login"
        case .notRegistered: "Off"
        case .requiresApproval: "Approval required in System Settings"
        case .notFound: "Login startup unavailable"
        }
    }

    init(defaults: UserDefaults = .standard, service: any LoginStartupServicing = NativeLoginStartupService()) {
        self.defaults = defaults; self.service = service
    }

    /// One best-effort default attempt, never repeated after failure, an app
    /// opt-out, or a later macOS override. QA launches call refresh only.
    public func start() async {
        guard !started, !busy else { return }
        started = true; busy = true
        defer { busy = false }
        let wanted = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
        let attempt = !defaults.bool(forKey: Self.attemptedKey)
        defaults.set(true, forKey: Self.attemptedKey)
        do {
            status = try await service.status()
            if wanted && attempt && (status == .notRegistered || status == .notFound) {
                defaults.set(true, forKey: Self.preferenceKey)
                status = try await service.setEnabled(true)
            }
        } catch { await record(error) }
    }

    public func refresh() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { status = try await service.status(); message = nil }
        catch { message = error.localizedDescription }
    }

    public func setEnabled(_ enabled: Bool) async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        defaults.set(enabled, forKey: Self.preferenceKey)
        defaults.set(true, forKey: Self.attemptedKey)
        do {
            status = try await service.status()
            if enabled ? status != .enabled && status != .requiresApproval : status != .notRegistered {
                status = try await service.setEnabled(enabled)
            }
        } catch { await record(error) }
    }

    public func openSystemSettings() { service.openSystemSettings() }
    public func retry() async {
        await setEnabled(defaults.object(forKey: Self.preferenceKey) as? Bool ?? true)
    }

    private func record(_ error: Error) async {
        // Registration can return an error while recording requiresApproval.
        // Always reread macOS before displaying the resulting switch state.
        if let actual = try? await service.status() { status = actual }
        message = error.localizedDescription
    }
}
