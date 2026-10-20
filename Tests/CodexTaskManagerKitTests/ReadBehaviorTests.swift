import Foundation
import Testing
@testable import CodexTaskManagerKit

@MainActor private final class ReadNavigationFixture: TaskReadNavigating {
    var opened: [String] = []
    var returned = 0
    var safe = true
    var permission = true
    func openChat(_ id: String) throws { opened.append(id) }
    func prepareReturn() throws -> TaskReadReturn? {
        guard permission else { throw TaskReadError.failed("Permission missing") }
        return TaskReadReturn(isSafe: { self.safe }, perform: { self.returned += 1 })
    }
}

@Suite("Read behavior") @MainActor
struct ReadBehaviorTests {
    @Test func settingsPersistWithoutChangingOtherPreferences() {
        let defaults = UserDefaults(suiteName: "read-settings-fixture-" + UUID().uuidString)!
        defaults.set("keep", forKey: "unrelated")
        let settings = ReadBehaviorSettings(defaults: defaults)
        #expect(settings.mode == .simulated)
        #expect(!settings.returnToPriorChat)
        settings.mode = .automated; settings.returnToPriorChat = true; settings.returnDelay = 4
        let reopened = ReadBehaviorSettings(defaults: defaults)
        #expect(reopened.mode == .automated && reopened.returnToPriorChat && reopened.returnDelay == 4)
        #expect(defaults.string(forKey: "unrelated") == "keep")
    }

    @Test func automatedReadWaitsForAcknowledgementBeforeReturning() async throws {
        let navigation = ReadNavigationFixture()
        var reads = 0
        var waits = 0
        let result = try await AutomatedReadOperation.run(
            id: "target", navigation: navigation, returnAfterRead: true, delay: 2,
            readState: {
                reads += 1
                return CodexUnreadState(ids: reads < 4 ? ["target"] : [], context: nil)
            }, isCurrent: { true }, canReturn: { true }, wait: { _ in
                waits += 1
                #expect(navigation.returned == 0)
            }
        )
        #expect(result == .returned)
        #expect(navigation.opened == ["target"] && navigation.returned == 1)
        #expect(waits == 13) // Three acknowledgement checks, then ten delay ticks.
    }

    @Test func interactionCancelsReturnPermanently() async throws {
        let navigation = ReadNavigationFixture()
        var waits = 0
        let result = try await AutomatedReadOperation.run(
            id: "target", navigation: navigation, returnAfterRead: true, delay: 1,
            readState: { CodexUnreadState(ids: waits < 3 ? ["target"] : [], context: nil) },
            isCurrent: { true }, canReturn: { true }, wait: { _ in
                waits += 1; navigation.safe = waits != 1
            }
        )
        #expect(result == .returnCancelled && navigation.returned == 0)
    }

    @Test func timeoutAndPermissionFailureNeverReturnOrClearUnread() async throws {
        let navigation = ReadNavigationFixture()
        await #expect(throws: (any Error).self) {
            try await AutomatedReadOperation.run(id: "target", navigation: navigation, returnAfterRead: false, delay: 1,
                readState: { CodexUnreadState(ids: ["target"], context: nil) }, isCurrent: { true }, canReturn: { true }, wait: { _ in })
        }
        #expect(navigation.returned == 0 && navigation.opened == ["target"])
        navigation.opened = []; navigation.permission = false
        await #expect(throws: (any Error).self) {
            try await AutomatedReadOperation.run(id: "target", navigation: navigation, returnAfterRead: true, delay: 1,
                readState: { CodexUnreadState(ids: ["target"], context: nil) }, isCurrent: { true }, canReturn: { true }, wait: { _ in })
        }
        #expect(navigation.opened.isEmpty)
    }

    @Test func newerActionOrAccountSwitchCancelsReturn() async throws {
        let navigation = ReadNavigationFixture()
        var current = true
        await #expect(throws: CancellationError.self) {
            try await AutomatedReadOperation.run(id: "target", navigation: navigation, returnAfterRead: true, delay: 1,
                readState: { CodexUnreadState(ids: ["target"], context: nil) }, isCurrent: { current }, canReturn: { true }, wait: { _ in current = false })
        }
        #expect(navigation.returned == 0)
        var reads = 0
        let changed = CodexReadContext(identity: .null, identityKey: "other", executionHostKey: "local:other")
        await #expect(throws: (any Error).self) {
            try await AutomatedReadOperation.run(id: "target", navigation: navigation, returnAfterRead: true, delay: 1,
                readState: { reads += 1; return CodexUnreadState(ids: reads == 1 ? ["target"] : [], context: reads == 1 ? nil : changed) },
                isCurrent: { true }, canReturn: { true }, wait: { _ in })
        }
        #expect(navigation.returned == 0)
    }
}
