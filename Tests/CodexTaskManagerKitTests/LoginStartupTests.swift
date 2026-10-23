import Foundation
import Testing
@testable import CodexTaskManagerKit

@MainActor @Suite("Login startup") struct LoginStartupTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "CodexTaskManager.tests.startup.\(UUID().uuidString)")!
    }

    @Test func freshInstallAttemptsOnce() async {
        let d = defaults(), service = FakeStartupService()
        let model = LoginStartupModel(defaults: d, service: service)
        await model.start(); await model.start()
        #expect(service.changes == [true]); #expect(model.isOn)
        #expect(d.bool(forKey: LoginStartupModel.attemptedKey))
        let next = LoginStartupModel(defaults: d, service: service)
        await next.start()
        #expect(service.changes == [true])
    }

    @Test func optOutSurvivesRelaunch() async {
        let d = defaults(), service = FakeStartupService()
        let model = LoginStartupModel(defaults: d, service: service)
        await model.start(); await model.setEnabled(false)
        let next = LoginStartupModel(defaults: d, service: service)
        await next.start()
        #expect(service.changes == [true, false]); #expect(!next.isOn)
        #expect(d.object(forKey: LoginStartupModel.preferenceKey) as? Bool == false)
    }

    @Test func preexistingOptOutDoesNotRegister() async {
        let d = defaults(), service = FakeStartupService()
        d.set(false, forKey: LoginStartupModel.preferenceKey)
        await LoginStartupModel(defaults: d, service: service).start()
        #expect(service.changes.isEmpty)
    }

    @Test func existingEnabledAndPendingApprovalAreNotReregistered() async {
        for state in [LoginStartupStatus.enabled, .requiresApproval] {
            let service = FakeStartupService(); service.actual = state
            let model = LoginStartupModel(defaults: defaults(), service: service)
            await model.start(); await model.setEnabled(true)
            #expect(service.changes.isEmpty); #expect(model.isOn)
            #expect(model.needsApproval == (state == .requiresApproval))
        }
    }

    @Test func systemOptOutIsRespectedOnNextLaunch() async {
        let d = defaults(), service = FakeStartupService()
        await LoginStartupModel(defaults: d, service: service).start()
        service.actual = .notRegistered
        let next = LoginStartupModel(defaults: d, service: service)
        await next.start()
        #expect(service.changes == [true]); #expect(!next.isOn)
    }

    @Test func errorDoesNotClaimEnabledOrRetryOnLaunch() async {
        let d = defaults(), service = FakeStartupService(); service.failure = true
        let model = LoginStartupModel(defaults: d, service: service)
        await model.start()
        #expect(!model.isOn); #expect(model.message != nil)
        service.failure = false
        await LoginStartupModel(defaults: d, service: service).start()
        #expect(service.changes == [true])
        await model.retry()
        #expect(model.isOn); #expect(model.message == nil)
    }

    @Test func deniedRegistrationRereadsApprovalState() async {
        let service = FakeStartupService(); service.failure = true; service.needsApproval = true
        let model = LoginStartupModel(defaults: defaults(), service: service)
        await model.start()
        #expect(model.needsApproval); #expect(model.isOn); #expect(model.message != nil)
        model.openSystemSettings(); #expect(service.openCount == 1)
    }

    @Test func refreshOnlyHasNoSideEffectsForQAAndSettings() async {
        let d = defaults(), service = FakeStartupService()
        let model = LoginStartupModel(defaults: d, service: service)
        await model.refresh()
        #expect(service.changes.isEmpty)
        #expect(d.object(forKey: LoginStartupModel.attemptedKey) == nil)
        service.actual = .requiresApproval; await model.refresh()
        #expect(model.needsApproval)
        service.actual = .enabled; await model.refresh()
        #expect(model.isOn && !model.needsApproval)
    }

    @Test func failedDisableRemainsHonestAndRetryKeepsOptOut() async {
        let d = defaults(), service = FakeStartupService()
        let model = LoginStartupModel(defaults: d, service: service)
        await model.start(); service.failure = true
        await model.setEnabled(false)
        #expect(model.isOn); #expect(model.message != nil)
        #expect(d.object(forKey: LoginStartupModel.preferenceKey) as? Bool == false)
        service.failure = false; await model.retry()
        #expect(!model.isOn); #expect(service.changes == [true, false, false])
    }

    @Test func notFoundAndReadFailureAreHonest() async {
        let service = FakeStartupService(); service.actual = .notFound
        service.failure = true
        let model = LoginStartupModel(defaults: defaults(), service: service)
        await model.start()
        #expect(!model.isOn); #expect(service.changes == [true])
        #expect(model.statusText == "Login startup unavailable")
        service.readFailure = true; await model.refresh()
        #expect(model.message != nil); #expect(!model.busy)
    }

    @Test func initiallyNotFoundStillAttemptsDefaultRegistration() async {
        let service = FakeStartupService(); service.actual = .notFound
        let model = LoginStartupModel(defaults: defaults(), service: service)
        await model.start()
        #expect(service.changes == [true]); #expect(model.isOn)
    }

    @Test func unsupportedBundleCannotInvokeLauncher() async {
        let service = NativeLoginStartupService(bundle: Bundle(for: BundleMarker.self))
        #expect(service.launcher == nil)
        await #expect(throws: (any Error).self) { try await service.setEnabled(true) }
    }
}

private final class BundleMarker: NSObject {}

@MainActor private final class FakeStartupService: LoginStartupServicing {
    var actual = LoginStartupStatus.notRegistered
    var changes: [Bool] = []
    var failure = false, readFailure = false, needsApproval = false
    var openCount = 0
    func status() async throws -> LoginStartupStatus {
        if readFailure { throw Failure.unavailable }
        return actual
    }
    func setEnabled(_ enabled: Bool) async throws -> LoginStartupStatus {
        changes.append(enabled)
        if needsApproval { actual = .requiresApproval }
        if failure { throw Failure.unavailable }
        actual = enabled ? .enabled : .notRegistered
        return actual
    }
    func openSystemSettings() { openCount += 1 }
    enum Failure: Error { case unavailable }
}
