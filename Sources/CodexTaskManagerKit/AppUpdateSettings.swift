import SwiftUI

public struct AppUpdateSettings: View {
    @Bindable private var updates: AppUpdateModel
    private let onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    public init(updates: AppUpdateModel = .shared, onClose: (() -> Void)? = nil) { self.updates = updates; self.onClose = onClose }
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
