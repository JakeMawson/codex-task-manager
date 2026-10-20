import Foundation

enum AutomatedReadResult { case read, returned, returnCancelled }

@MainActor enum AutomatedReadOperation {
    static func run(
        id: String, navigation: any TaskReadNavigating, returnAfterRead: Bool, delay: Double,
        readState: @MainActor () async throws -> CodexUnreadState,
        isCurrent: @MainActor () -> Bool,
        canReturn: @MainActor () -> Bool,
        wait: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> AutomatedReadResult {
        let before = try await readState()
        guard isCurrent() else { throw CancellationError() }
        guard before.ids.contains(id) else { return .read }
        let originalTicket = returnAfterRead ? try navigation.prepareReturn() : nil
        defer { originalTicket?.finish() }
        var ticket = originalTicket
        try navigation.openChat(id)
        var returnCancelled = false
        // Bounded observation, never a local optimistic read acknowledgement.
        for _ in 0..<40 {
            try await wait(.milliseconds(200))
            guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
            if let active = ticket, !canReturn() || !active.isSafe() {
                ticket = nil; returnCancelled = true
            }
            let current = try await readState()
            guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
            guard current.context == before.context else {
                throw TaskReadError.failed("Codex's account changed. Read confirmation and automatic return were cancelled.")
            }
            guard !current.ids.contains(id) else { continue }
            if let ticket {
                let ticks = Int((min(max(delay.isFinite ? delay : 2, 1), 10) * 5).rounded(.up))
                for _ in 0..<ticks {
                    try await wait(.milliseconds(200))
                    guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
                    guard canReturn(), ticket.isSafe() else { return .returnCancelled }
                    let confirmed = try await readState()
                    guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
                    guard canReturn(), ticket.isSafe() else { return .returnCancelled }
                    guard confirmed.context == before.context, !confirmed.ids.contains(id) else { return .returnCancelled }
                }
                try ticket.perform()
                return .returned
            }
            return returnCancelled ? .returnCancelled : .read
        }
        throw TaskReadError.failed("Codex did not confirm this chat as read within 8 seconds. Its unread status has been preserved; try again or read it in Codex.")
    }
}
