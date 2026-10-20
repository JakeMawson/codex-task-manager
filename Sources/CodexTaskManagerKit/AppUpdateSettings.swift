import SwiftUI

public struct AppUpdateSettings: View {
    @Bindable private var updates: AppUpdateModel
    @Bindable private var model: TaskManagerModel
    @State private var accessibilityAvailable = NativeTaskReadNavigation.accessibilityAvailable
    private let onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    public init(updates: AppUpdateModel = .shared, model: TaskManagerModel, onClose: (() -> Void)? = nil) {
        self.updates = updates; self.model = model; self.onClose = onClose
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Settings").font(.title2.bold())
                    Text("Codex Task Manager").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { if let onClose { onClose() } else { dismiss() } }.keyboardShortcut(.cancelAction)
            }
            Divider()
            readBehavior
            Divider()
            LabeledContent("Version", value: "\(updates.currentVersion) (\(updates.build))")
            Toggle("Automatically prepare updates", isOn: $updates.automaticallyPrepare)
                .disabled(updates.busy)
            Text("Updates are downloaded in the background and installed next time you open the app. You can also install a prepared update here. Codex chats and running work are preserved.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if updates.busy { ProgressView().controlSize(.small) }
                    Text(status).font(.headline)
                }
                if let message = updates.message {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(5).help(message)
                }
                if let checked = updates.lastChecked {
                    Text("Last checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Check for updates") { Task { await updates.check() } }.disabled(updates.busy)
                    if updates.phase == .available {
                        Button("Prepare update") { Task { await updates.prepare() } }.disabled(updates.busy)
                    }
                    if updates.phase == .ready {
                        Button("Install and relaunch") { Task { await updates.install() } }.buttonStyle(.borderedProminent)
                    }
                }
                if let notes = updates.release?.notes, !notes.isEmpty {
                    ScrollView { Text(notes).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        .frame(maxHeight: 150)
                }
            }
            Divider()
            HStack {
                Link("Source and releases", destination: URL(string: "https://github.com/JakeMawson/codex-task-manager")!)
                Spacer()
                Text("Local task monitoring").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24).frame(width: 500)
        .preferredColorScheme(.dark)
        .onChange(of: model.readSettings.mode) { Task { await model.readBehaviorDidChange() } }
        .onChange(of: model.readSettings.returnToPriorChat) { Task { await model.readBehaviorDidChange() } }
        .onChange(of: model.readSettings.returnDelay) { Task { await model.readBehaviorDidChange() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityAvailable = NativeTaskReadNavigation.accessibilityAvailable
        }
    }
    private var readBehavior: some View {
        @Bindable var reads = model.readSettings
        return VStack(alignment: .leading, spacing: 10) {
            Text("Mark as read").font(.headline)
            Picker("Mode", selection: $reads.mode) {
                Text("Simulated").tag(TaskReadMode.simulated)
                Text("Automated").tag(TaskReadMode.automated)
            }.pickerStyle(.segmented)
            Text(reads.mode == .simulated
                 ? "Marks the current unread episode read in Task Manager only. New activity or a later read/unread cycle brings the chat back. Codex’s own unread flag stays unchanged."
                 : "Opens the chat in Codex and waits up to 8 seconds for Codex to confirm it is read.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if reads.mode == .automated {
                Toggle("Return to prior chat", isOn: $reads.returnToPriorChat)
                if reads.returnToPriorChat {
                    Stepper("Return after \(Int(reads.returnDelay)) \(reads.returnDelay == 1 ? "second" : "seconds")", value: $reads.returnDelay, in: 1...10, step: 1)
                    Text("After read confirmation, uses Codex’s Back command. Cancels if you interact, switch apps or change this setting.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !accessibilityAvailable {
                        Button("Enable Accessibility for automatic return…") { NativeTaskReadNavigation.requestAccessibility() }
                    }
                }
            }
        }
    }
    private var status: String {
        switch updates.phase {
        case .current: updates.lastChecked == nil ? "Updates" : "You’re up to date"
        case .checking: "Checking for updates…"
        case .available: "Version \(updates.release?.tag ?? "") is available"
        case .preparing: "Preparing update…"
        case .ready: "Update ready to install"
        case .installing: "Installing update…"
        case .relaunching: "Relaunching…"
        }
    }
}
