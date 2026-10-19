import AppKit
import Foundation
import Observation

struct AppUpdateVersion: Comparable, Codable, Sendable, CustomStringConvertible {
    let components: [Int]
    init?(_ raw: String) {
        let value = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard value.count <= 64, (1...8).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        var parsed = parts.compactMap { Int($0) }
        guard parsed.count == parts.count else { return nil }
        while parsed.count > 1 && parsed.last == 0 { parsed.removeLast() }
        components = parsed
    }
    var description: String { components.map(String.init).joined(separator: ".") }
    static func < (lhs: Self, rhs: Self) -> Bool {
        for i in 0..<max(lhs.components.count, rhs.components.count) {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b }
        }
        return false
    }
}

struct AppUpdateRelease: Codable, Equatable, Sendable {
    let tag: String
    let notes: String
    var version: AppUpdateVersion? { AppUpdateVersion(tag) }
    init(tag: String, notes: String = "") { self.tag = String(tag.prefix(64)); self.notes = String(notes.prefix(16_000)) }
    enum CodingKeys: String, CodingKey { case tag = "tag_name", notes = "body", prerelease, draft }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .tag)
        guard tag.count <= 64, AppUpdateVersion(tag) != nil,
              !(try c.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false),
              !(try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false) else { throw AppUpdateError.invalidRelease }
        self.init(tag: tag, notes: try c.decodeIfPresent(String.self, forKey: .notes) ?? "")
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tag, forKey: .tag); try c.encode(notes, forKey: .notes)
    }
}

enum AppUpdateError: LocalizedError {
    case invalidRelease, homebrewUnavailable, invalidInstallation, commandFailed(String)
    var errorDescription: String? {
        switch self {
        case .invalidRelease: "A supported stable release could not be verified."
        case .homebrewUnavailable: "Install Homebrew to update Codex Task Manager."
        case .invalidInstallation: "The installed app’s identity, signature or version could not be verified. Reinstall with Homebrew."
        case .commandFailed(let detail): detail
        }
    }
}

protocol AppUpdateChecking: Sendable { func latestRelease() async throws -> AppUpdateRelease }
protocol AppUpdateInstalling: Sendable { func stage() async throws; func install() async throws }
@MainActor protocol AppUpdateLifecycle {
    var installedVersion: String { get }
    var allowsAutomaticInstall: Bool { get }
    func verifyInstallation(atLeast version: AppUpdateVersion) async throws
    func relaunch() throws
}

struct GitHubAppUpdateChecker: AppUpdateChecking {
    static let endpoint = URL(string: "https://api.github.com/repos/JakeMawson/codex-task-manager/releases/latest")!
    func latestRelease() async throws -> AppUpdateRelease {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexTaskManager", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.host == Self.endpoint.host else { throw AppUpdateError.invalidRelease }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 131_072 else { throw AppUpdateError.invalidRelease }
            data.append(byte)
        }
        return try JSONDecoder().decode(AppUpdateRelease.self, from: data)
    }
}

protocol AppUpdateCommandRunning: Sendable {
    func run(_ executable: String, arguments: [String]) async throws -> String
}

struct AppUpdateCommandRunner: AppUpdateCommandRunning {
    private final class Output: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        func append(_ chunk: Data) { lock.lock(); defer { lock.unlock() }; data.append(chunk.prefix(max(0, 24_576 - data.count))) }
        func string() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
    func run(_ executable: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process(), pipe = Pipe(), output = Output()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = pipe; process.standardError = pipe
                do {
                    try process.run()
                    // Drain continuously, retaining a strict cap so verbose commands
                    // cannot block on a full pipe or grow application memory.
                    while true {
                        let chunk = pipe.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        output.append(chunk)
                    }
                    process.waitUntilExit()
                    try? pipe.fileHandleForReading.close()
                    if process.terminationStatus == 0 { continuation.resume(returning: output.string()) }
                    else { continuation.resume(throwing: AppUpdateError.commandFailed("Update command exited \(process.terminationStatus). \(output.string())")) }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

struct HomebrewAppUpdater: AppUpdateInstalling {
    static let cask = "JakeMawson/tap/codex-task-manager"
    let runner: any AppUpdateCommandRunning
    let executable: String?
    init(runner: any AppUpdateCommandRunning = AppUpdateCommandRunner(), executable: String? = nil) {
        self.runner = runner
        self.executable = executable ?? ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    private func run(_ arguments: [String]) async throws {
        guard let executable, ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].contains(executable) else { throw AppUpdateError.homebrewUnavailable }
        _ = try await runner.run(executable, arguments: arguments)
    }
    func stage() async throws {
        try await run(["update"])
        try await run(["fetch", "--cask", Self.cask])
    }
    func install() async throws {
        // The fixed cask's preflight verifies Developer ID, both bundle IDs and
        // notarization before Homebrew installs its app artifact.
        try await run(["upgrade", "--cask", Self.cask])
    }
}

@MainActor struct InstalledTaskManagerLifecycle: AppUpdateLifecycle {
    static let appPath = "/Applications/Codex Task Manager.app"
    static let bundleID = "com.jakemawson.codex-task-manager.launcher"
    static let agentID = "com.jakemawson.codex-task-manager.menuagent"
    var installedVersion: String { Bundle(path: Self.appPath)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown" }
    var allowsAutomaticInstall: Bool { Bundle.main.bundleURL.path.hasPrefix(Self.appPath + "/Contents/") }
    func verifyInstallation(atLeast version: AppUpdateVersion) async throws {
        // Read the plist from disk; Bundle caches information for running code.
        let url = URL(fileURLWithPath: Self.appPath + "/Contents/Info.plist")
        guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == Self.bundleID,
              let raw = plist["CFBundleShortVersionString"] as? String,
              let actual = AppUpdateVersion(raw), actual >= version else { throw AppUpdateError.invalidInstallation }
        let runner = AppUpdateCommandRunner()
        for (path, id) in [(Self.appPath, Self.bundleID), (Self.appPath + "/Contents/Library/LoginItems/CodexTaskManagerMenuAgent.app", Self.agentID)] {
            _ = try await runner.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", "-R", "=anchor apple generic and identifier \"\(id)\" and certificate leaf[subject.OU] = \"6RWK4446NQ\"", path])
        }
        _ = try await runner.run("/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", Self.appPath])
    }
    static func relaunchArguments(pid: Int32) -> [String] {
        ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; exec /usr/bin/open -n \"$2\"", "codex-task-manager-relaunch", String(pid), appPath]
    }
    func relaunch() throws {
        let relay = Process()
        relay.executableURL = URL(fileURLWithPath: "/bin/sh")
        relay.arguments = Self.relaunchArguments(pid: ProcessInfo.processInfo.processIdentifier)
        relay.standardInput = FileHandle.nullDevice; relay.standardOutput = FileHandle.nullDevice; relay.standardError = FileHandle.nullDevice
        try relay.run()
        NSApp.terminate(nil)
    }
}

@MainActor @Observable public final class AppUpdateModel {
    public static let shared = AppUpdateModel()
    enum Phase: Equatable { case current, checking, available, preparing, ready, installing, relaunching }
    static let preferenceKey = "CodexTaskManager.automaticallyPrepareUpdates"
    static let preparedKey = "CodexTaskManager.preparedUpdate"
    public let currentVersion: String
    public let build: String
    var phase: Phase = .current
    var release: AppUpdateRelease?
    var message: String?
    var lastChecked: Date?
    var busy: Bool { [.checking, .preparing, .installing, .relaunching].contains(phase) }
    public var automaticallyPrepare: Bool { didSet { defaults.set(automaticallyPrepare, forKey: Self.preferenceKey) } }
    private let checker: any AppUpdateChecking
    private let installer: any AppUpdateInstalling
    private let lifecycle: any AppUpdateLifecycle
    private let defaults: UserDefaults
    private var loop: Task<Void, Never>?

    init(checker: any AppUpdateChecking = GitHubAppUpdateChecker(), installer: any AppUpdateInstalling = HomebrewAppUpdater(), lifecycle: any AppUpdateLifecycle = InstalledTaskManagerLifecycle(), defaults: UserDefaults = .standard, currentVersion: String? = nil) {
        self.checker = checker; self.installer = installer; self.lifecycle = lifecycle; self.defaults = defaults
        self.currentVersion = currentVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        automaticallyPrepare = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
    }
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.onOrdinaryLaunch()
            while !Task.isCancelled {
                await self?.check()
                do { try await Task.sleep(for: .seconds(7200)) } catch { return }
            }
        }
    }
    func onOrdinaryLaunch() async {
        guard let data = defaults.data(forKey: Self.preparedKey) else { return }
        guard let prepared = try? JSONDecoder().decode(AppUpdateRelease.self, from: data),
              let version = prepared.version, let current = AppUpdateVersion(currentVersion), version > current else {
            defaults.removeObject(forKey: Self.preparedKey); return
        }
        release = prepared; phase = .ready
        if automaticallyPrepare && lifecycle.allowsAutomaticInstall { await install() }
    }
    func check() async {
        guard !busy else { return }
        let priorPhase = phase
        phase = .checking
        do {
            let candidate = try await checker.latestRelease()
            guard let latest = candidate.version, let current = AppUpdateVersion(currentVersion) else { throw AppUpdateError.invalidRelease }
            lastChecked = Date(); message = nil
            if latest <= current { release = nil; phase = .current; defaults.removeObject(forKey: Self.preparedKey); return }
            if release == candidate && priorPhase == .ready { phase = .ready; return }
            release = candidate; phase = .available
            if automaticallyPrepare { await prepare() }
        } catch { phase = priorPhase; message = error.localizedDescription }
    }
    func prepare() async {
        guard !busy, let release, release.version != nil else { return }
        phase = .preparing; message = nil
        do {
            try await installer.stage()
            defaults.set(try JSONEncoder().encode(release), forKey: Self.preparedKey)
            phase = .ready
        } catch { phase = .available; message = error.localizedDescription }
    }
    func install() async {
        guard phase == .ready, let version = release?.version else { return }
        guard lifecycle.allowsAutomaticInstall else { message = "Install this app in Applications with Homebrew before updating."; return }
        phase = .installing; message = nil
        do {
            try await installer.install()
            try await lifecycle.verifyInstallation(atLeast: version)
            defaults.removeObject(forKey: Self.preparedKey)
            phase = .relaunching
            try lifecycle.relaunch()
        } catch { phase = .ready; message = error.localizedDescription }
    }
}
