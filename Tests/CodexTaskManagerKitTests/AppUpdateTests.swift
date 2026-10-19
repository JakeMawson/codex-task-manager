import Foundation
import Testing
@testable import CodexTaskManagerKit

private enum UpdateTestError: Error { case failed }
private actor UpdateChecker: AppUpdateChecking {
    var result: Result<AppUpdateRelease, Error>
    init(_ result: Result<AppUpdateRelease, Error>) { self.result = result }
    func set(_ result: Result<AppUpdateRelease, Error>) { self.result = result }
    func latestRelease() async throws -> AppUpdateRelease { try result.get() }
}
private actor UpdateInstaller: AppUpdateInstalling {
    var staged = 0, installed = 0
    let stageFails: Bool, installFails: Bool
    init(stageFails: Bool = false, installFails: Bool = false) { self.stageFails = stageFails; self.installFails = installFails }
    func stage() async throws { staged += 1; if stageFails { throw UpdateTestError.failed } }
    func install() async throws { installed += 1; if installFails { throw UpdateTestError.failed } }
    func counts() -> [Int] { [staged, installed] }
}
@MainActor private final class UpdateLifecycle: AppUpdateLifecycle {
    var installedVersion = "1.0"
    var allowsAutomaticInstall = true
    var verifyFails = false, relaunchFails = false
    var verified: AppUpdateVersion?, relaunched = false
    func verifyInstallation(atLeast version: AppUpdateVersion) async throws { if verifyFails { throw UpdateTestError.failed }; verified = version }
    func relaunch() throws { if relaunchFails { throw UpdateTestError.failed }; relaunched = true }
}
private actor UpdateRunner: AppUpdateCommandRunning {
    var calls: [[String]] = []
    func run(_ executable: String, arguments: [String]) async throws -> String { calls.append([executable] + arguments); return "" }
    func recorded() -> [[String]] { calls }
}

@Suite("App updates") @MainActor struct AppUpdateTests {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "TaskManagerUpdateTests.\(UUID().uuidString)")! }
    let newer = AppUpdateRelease(tag: "v1.2.0", notes: "A useful update")
    @Test func versionsAndReleaseBounds() throws {
        #expect(AppUpdateVersion("1.4") == AppUpdateVersion("1.4.0"))
        #expect(try #require(AppUpdateVersion("1.10")) > #require(AppUpdateVersion("1.9.9")))
        for raw in ["", "1..2", "1.0-beta", "1; echo hi", "1.２", "-1", "9999999999999999999999999999", " 1.0"] { #expect(AppUpdateVersion(raw) == nil) }
        let release = try JSONDecoder().decode(AppUpdateRelease.self, from: JSONSerialization.data(withJSONObject: ["tag_name": "v2.0", "body": String(repeating: "x", count: 20_000)]))
        #expect(release.notes.count == 16_000)
        for data in [#"{"tag_name":"v2-beta"}"#, #"{"tag_name":"v2","prerelease":true}"#, #"{"tag_name":"2","draft":true}"#, #"{}"#] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(AppUpdateRelease.self, from: Data(data.utf8)) }
        }
    }
    @Test func defaultAndOptOut() async {
        let d = defaults(), installer = UpdateInstaller(), lifecycle = UpdateLifecycle()
        #expect(AppUpdateModel(defaults: d).automaticallyPrepare)
        d.set(false, forKey: AppUpdateModel.preferenceKey)
        let model = AppUpdateModel(checker: UpdateChecker(.success(newer)), installer: installer, lifecycle: lifecycle, defaults: d, currentVersion: "1.0")
        #expect(!model.automaticallyPrepare)
        await model.check()
        #expect(model.phase == .available)
        #expect(await installer.counts() == [0, 0])
        #expect(d.data(forKey: AppUpdateModel.preparedKey) == nil)
    }
    @Test func preparationAndExplicitInstall() async throws {
        let d = defaults(), installer = UpdateInstaller(), lifecycle = UpdateLifecycle()
        let model = AppUpdateModel(checker: UpdateChecker(.success(newer)), installer: installer, lifecycle: lifecycle, defaults: d, currentVersion: "1.0")
        await model.check()
        #expect(model.phase == .ready)
        #expect(await installer.counts() == [1, 0])
        #expect(try JSONDecoder().decode(AppUpdateRelease.self, from: #require(d.data(forKey: AppUpdateModel.preparedKey))) == newer)
        await model.install()
        #expect(await installer.counts() == [1, 1])
        #expect(lifecycle.verified == newer.version)
        #expect(lifecycle.relaunched)
        #expect(d.data(forKey: AppUpdateModel.preparedKey) == nil)
    }
    @Test func checkAndStageFailuresPreserveCandidate() async {
        let checker = UpdateChecker(.failure(UpdateTestError.failed)), d = defaults()
        let model = AppUpdateModel(checker: checker, installer: UpdateInstaller(stageFails: true), lifecycle: UpdateLifecycle(), defaults: d, currentVersion: "1")
        await model.check(); #expect(model.phase == .current); #expect(model.message != nil)
        await checker.set(.success(newer)); await model.check()
        #expect(model.phase == .available); #expect(model.release == newer)
        #expect(d.data(forKey: AppUpdateModel.preparedKey) == nil)
        await checker.set(.failure(UpdateTestError.failed)); await model.check()
        #expect(model.phase == .available); #expect(model.release == newer)
    }
    @Test(arguments: [0, 1, 2]) func installFailuresDoNotRelaunchOrLosePreparation(_ failure: Int) async {
        let d = defaults(), lifecycle = UpdateLifecycle()
        lifecycle.verifyFails = failure == 1; lifecycle.relaunchFails = failure == 2
        let model = AppUpdateModel(checker: UpdateChecker(.success(newer)), installer: UpdateInstaller(installFails: failure == 0), lifecycle: lifecycle, defaults: d, currentVersion: "1")
        await model.check(); await model.install()
        #expect(model.phase == .ready); #expect(!lifecycle.relaunched); #expect(model.message != nil)
        if failure != 2 { #expect(d.data(forKey: AppUpdateModel.preparedKey) != nil) }
    }
    @Test(arguments: [false, true]) func persistedPreparationAtLaunch(_ optOut: Bool) async throws {
        let d = defaults(), installer = UpdateInstaller(), lifecycle = UpdateLifecycle()
        d.set(!optOut, forKey: AppUpdateModel.preferenceKey)
        d.set(try JSONEncoder().encode(newer), forKey: AppUpdateModel.preparedKey)
        let model = AppUpdateModel(installer: installer, lifecycle: lifecycle, defaults: d, currentVersion: "1")
        await model.onOrdinaryLaunch()
        #expect(await installer.counts() == [0, optOut ? 0 : 1])
        #expect(lifecycle.relaunched == !optOut)
    }
    @Test func stalePreparedRecordIsDiscarded() async throws {
        let d = defaults(), installer = UpdateInstaller()
        d.set(try JSONEncoder().encode(newer), forKey: AppUpdateModel.preparedKey)
        let model = AppUpdateModel(installer: installer, defaults: d, currentVersion: "2.0")
        await model.onOrdinaryLaunch()
        #expect(await installer.counts() == [0, 0]); #expect(d.data(forKey: AppUpdateModel.preparedKey) == nil)
    }
    @Test func fixedHomebrewRouteAndRelaunchArguments() async throws {
        let runner = UpdateRunner()
        let updater = HomebrewAppUpdater(runner: runner, executable: "/opt/homebrew/bin/brew")
        try await updater.stage(); try await updater.install()
        #expect(await runner.recorded() == [
            ["/opt/homebrew/bin/brew", "update"],
            ["/opt/homebrew/bin/brew", "fetch", "--cask", "JakeMawson/tap/codex-task-manager"],
            ["/opt/homebrew/bin/brew", "upgrade", "--cask", "JakeMawson/tap/codex-task-manager"],
        ])
        let args = InstalledTaskManagerLifecycle.relaunchArguments(pid: 42)
        #expect(args[3] == "42"); #expect(args[4] == "/Applications/Codex Task Manager.app")
        #expect(!args[1].contains("42"))
        let rejected = HomebrewAppUpdater(runner: runner, executable: "/tmp/brew")
        await #expect(throws: (any Error).self) { try await rejected.install() }
    }
    @Test func realRunnerDrainsLargeOutputAndRejectsFailures() async throws {
        let runner = AppUpdateCommandRunner()
        let output = try await runner.run("/usr/bin/printf", arguments: ["%s", String(repeating: "x", count: 50_000)])
        #expect(output.utf8.count == 24_576)
        await #expect(throws: (any Error).self) { try await runner.run("/usr/bin/false", arguments: []) }
    }
}
