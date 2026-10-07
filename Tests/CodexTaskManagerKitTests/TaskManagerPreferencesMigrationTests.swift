import Foundation
import Testing
@testable import CodexTaskManagerKit

@Suite("Menu-bar identity settings migration")
struct TaskManagerPreferencesMigrationTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "CodexTaskManager.migration-test.\(UUID().uuidString)")!
    }

    @Test("Preserve app settings without inheriting invisible-item bookkeeping")
    func onlyAppOwnedSettings() {
        let target = defaults()
        let data = Data("example settings".utf8)
        TaskManagerPreferencesMigration.migrate(into: target, legacyDomains: [[
            TaskManagerPreferencesMigration.settingsKey: data,
            "NSStatusItem VisibleCC Item-0": false,
            "NSStatusItem Preferred Position Item-0": 999,
            "unrelated": "do not migrate"
        ]])
        #expect(target.data(forKey: TaskManagerPreferencesMigration.settingsKey) == data)
        #expect(target.object(forKey: "NSStatusItem VisibleCC Item-0") == nil)
        #expect(target.object(forKey: "NSStatusItem Preferred Position Item-0") == nil)
        #expect(target.object(forKey: "unrelated") == nil)
    }

    @Test("Existing destination settings win and migration never replays")
    func destinationAndOneTime() {
        let target = defaults()
        let existing = Data("current".utf8)
        target.set(existing, forKey: TaskManagerPreferencesMigration.settingsKey)
        TaskManagerPreferencesMigration.migrate(into: target, legacyDomains: [[TaskManagerPreferencesMigration.settingsKey: Data("legacy".utf8)]])
        #expect(target.data(forKey: TaskManagerPreferencesMigration.settingsKey) == existing)
        target.removeObject(forKey: TaskManagerPreferencesMigration.settingsKey)
        TaskManagerPreferencesMigration.migrate(into: target, legacyDomains: [[TaskManagerPreferencesMigration.settingsKey: Data("later".utf8)]])
        #expect(target.object(forKey: TaskManagerPreferencesMigration.settingsKey) == nil)
    }

    @Test("Newest available app settings win; missing or invalid values fall back")
    func newestValidSettings() {
        let target = defaults()
        let newest = Data("newest".utf8)
        TaskManagerPreferencesMigration.migrate(into: target, legacyDomains: [
            [TaskManagerPreferencesMigration.settingsKey: "invalid type"],
            [:], [TaskManagerPreferencesMigration.settingsKey: newest],
            [TaskManagerPreferencesMigration.settingsKey: Data("older".utf8)]
        ])
        #expect(target.data(forKey: TaskManagerPreferencesMigration.settingsKey) == newest)
        #expect(target.bool(forKey: TaskManagerPreferencesMigration.markerKey))
    }
}
