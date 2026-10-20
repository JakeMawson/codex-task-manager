import Foundation
import Observation

public enum TaskReadMode: String, CaseIterable, Sendable {
    case simulated, automated
}

@MainActor @Observable
public final class ReadBehaviorSettings {
    private let defaults: UserDefaults
    public var mode: TaskReadMode { didSet { defaults.set(mode.rawValue, forKey: "readBehavior.mode") } }
    public var returnToPriorChat: Bool { didSet { defaults.set(returnToPriorChat, forKey: "readBehavior.return") } }
    public var returnDelay: Double { didSet { defaults.set(returnDelay, forKey: "readBehavior.delay") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: "readBehavior.mode").flatMap(TaskReadMode.init) ?? .simulated
        returnToPriorChat = defaults.bool(forKey: "readBehavior.return")
        let saved = defaults.object(forKey: "readBehavior.delay") as? Double ?? 2
        returnDelay = saved.isFinite ? min(max(saved, 1), 10) : 2
    }
}
