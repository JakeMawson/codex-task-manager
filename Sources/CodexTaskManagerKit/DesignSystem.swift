import SwiftUI

public enum TaskManagerPalette {
    public static let nightInk = Color(red: 11 / 255, green: 16 / 255, blue: 23 / 255)
    public static let slateGlass = Color(red: 21 / 255, green: 29 / 255, blue: 40 / 255)
    public static let liftedSlate = Color(red: 27 / 255, green: 37 / 255, blue: 50 / 255)
    public static let porcelain = Color(red: 242 / 255, green: 245 / 255, blue: 247 / 255)
    public static let secondary = Color(red: 152 / 255, green: 166 / 255, blue: 183 / 255)
    public static let signalBlue = Color(red: 91 / 255, green: 140 / 255, blue: 255 / 255)
    public static let mineralTeal = Color(red: 60 / 255, green: 200 / 255, blue: 180 / 255)
    public static let burntAmber = Color(red: 242 / 255, green: 164 / 255, blue: 58 / 255)
    public static let danger = Color(red: 255 / 255, green: 107 / 255, blue: 115 / 255)
    public static let hairline = Color.white.opacity(0.09)

    public static func color(for state: TaskAttentionState) -> Color {
        switch state {
        case .needsApproval: danger
        case .needsResponse: burntAmber
        case .running: mineralTeal
        case .complete: signalBlue
        case .idle: secondary.opacity(0.55)
        }
    }
}

public enum TaskManagerMetrics {
    public static let panelWidth: CGFloat = 392
    public static let panelHeight: CGFloat = 672
    public static let outerPadding: CGFloat = 16
    public static let cardRadius: CGFloat = 15
    public static let controlRadius: CGFloat = 11
}

public extension Font {
    static func taskHeading(_ size: CGFloat, weight: Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func taskUtility(_ size: CGFloat, weight: Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
