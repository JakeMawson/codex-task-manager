import SwiftUI

public struct ProjectOrderView: View {
    @Bindable private var model: TaskManagerModel
    @Environment(\.dismiss) private var dismiss

    public init(model: TaskManagerModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CUSTOM PROJECT ORDER")
                        .font(.taskUtility(10, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(TaskManagerPalette.mineralTeal)
                    Text("Arrange task groups")
                        .font(.taskHeading(22, weight: .bold))
                        .foregroundStyle(TaskManagerPalette.porcelain)
                    Text("Use the arrows to set any project order.")
                        .font(.taskHeading(11))
                        .foregroundStyle(TaskManagerPalette.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(TaskManagerPalette.signalBlue)
            }
            .padding(20)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(model.projectPaths.enumerated()), id: \.element) { index, path in
                        projectRow(path: path, index: index)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            HStack {
                Button("Reset to recent") { model.resetProjectOrder() }
                    .buttonStyle(.plain)
                    .font(.taskUtility(9, weight: .semibold))
                    .foregroundStyle(TaskManagerPalette.secondary)
                Spacer()
                Text("USED BY RECENT + PRIORITY GROUPS")
                    .font(.taskUtility(8, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(TaskManagerPalette.secondary.opacity(0.65))
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(TaskManagerPalette.slateGlass)
            .overlay(alignment: .top) { Rectangle().fill(TaskManagerPalette.hairline).frame(height: 1) }
        }
        .frame(width: 430, height: 540)
        .background(TaskManagerPalette.nightInk)
        .preferredColorScheme(.dark)
    }

    private func projectRow(path: String, index: Int) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.taskUtility(10, weight: .bold))
                .foregroundStyle(TaskManagerPalette.mineralTeal)
                .frame(width: 22)
            if model.isProjectPinned(path) {
                Image(systemName: "pin.fill")
                    .foregroundStyle(TaskManagerPalette.burntAmber)
            }
            Image(systemName: "folder.fill")
                .foregroundStyle(TaskManagerPalette.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.taskHeading(13, weight: .bold))
                    .foregroundStyle(TaskManagerPalette.porcelain)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    let pinned = model.pinnedCount(in: path)
                    if pinned > 0 {
                        Text("• \(pinned) PINNED")
                            .foregroundStyle(TaskManagerPalette.signalBlue)
                    }
                }
                .font(.taskUtility(8, weight: .medium))
                .foregroundStyle(TaskManagerPalette.secondary)
            }
            Spacer(minLength: 8)
            VStack(spacing: 3) {
                Button { model.moveProject(from: index, to: index - 1) } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                Button { model.moveProject(from: index, to: index + 1) } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == model.projectPaths.count - 1)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(TaskManagerPalette.secondary)
        }
        .padding(.horizontal, 13)
        .frame(height: 62)
        .background(TaskManagerPalette.slateGlass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(TaskManagerPalette.hairline)
        }
        .contextMenu {
            Button {
                model.toggleProjectPin(path)
            } label: {
                Label(
                    model.isProjectPinned(path) ? "Unpin project" : "Pin project",
                    systemImage: model.isProjectPinned(path) ? "pin.slash" : "pin"
                )
            }
        }
    }
}
