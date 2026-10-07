import Foundation

/// Copy only app-owned settings when adopting the repaired menu-bar identity.
/// macOS status-item placement/visibility and system bookkeeping stay behind.
public enum TaskManagerPreferencesMigration {
    public static let settingsKey = "CodexTaskManager.preferences.v1"
    public static let markerKey = "CodexTaskManager.migratedMenuBarIdentity.v1"

    public static func migrate(
        into defaults: UserDefaults,
        legacyDomains: [[String: Any]]
    ) {
        guard !defaults.bool(forKey: markerKey) else { return }
        if defaults.object(forKey: settingsKey) == nil,
           let settings = legacyDomains.lazy.compactMap({ $0[settingsKey] as? Data }).first {
            defaults.set(settings, forKey: settingsKey)
        }
        defaults.set(true, forKey: markerKey)
    }
}
