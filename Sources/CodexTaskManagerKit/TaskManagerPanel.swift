import SwiftUI

public struct TaskManagerPanel: View {
    @Bindable private var model: TaskManagerModel
    @State private var showsProjectArrangement = false

    public init(model: TaskManagerModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            controls
            taskContent
            footer
        }
        .frame(width: TaskManagerMetrics.panelWidth, height: TaskManagerMetrics.panelHeight)
        .background(TaskManagerPalette.nightInk)
        .preferredColorScheme(.dark)
        .task {
            model.startBackgroundRefresh()
        }
        .sheet(isPresented: $showsProjectArrangement) {
            ProjectOrderView(model: model)
        }
    }

    private var header: some View {
        VStack(spacing: 11) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CODEX TASK MANAGER")
                        .font(.taskUtility(10, weight: .semibold))
                        .tracking(1.25)
                        .foregroundStyle(TaskManagerPalette.mineralTeal)
                    Text("Task dispatch")
                        .font(.taskHeading(23, weight: .bold))
                        .foregroundStyle(TaskManagerPalette.porcelain)
                }

                Spacer(minLength: 8)

                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 31, height: 31)
                        .background(TaskManagerPalette.liftedSlate, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(TaskManagerPalette.hairline)
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(TaskManagerPalette.secondary)
                .help("Refresh tasks")
            }

            statusSummary
        }
        .padding(.horizontal, TaskManagerMetrics.outerPadding)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var statusSummary: some View {
        HStack(spacing: 0) {
            summaryItem(
                value: model.attentionCount,
                label: "NEEDS",
                color: TaskManagerPalette.burntAmber,
                isSelected: model.isAttentionFilterSelected,
                accessibilityLabel: "Show tasks needing attention",
                action: model.selectOnlyAttentionFilters
            )
            summaryDivider
            summaryItem(
                value: model.stateCount(.running),
                label: "RUNNING",
                color: TaskManagerPalette.mineralTeal,
                isSelected: model.isStatusFilterSelected(.running),
                accessibilityLabel: "Show running tasks",
                action: { model.selectOnlyStatusFilter(.running) }
            )
            summaryDivider
            summaryItem(
                value: model.stateCount(.complete),
                label: "COMPLETE",
                color: TaskManagerPalette.signalBlue,
                isSelected: model.isStatusFilterSelected(.complete),
                accessibilityLabel: "Show complete tasks",
                action: { model.selectOnlyStatusFilter(.complete) }
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(TaskManagerPalette.slateGlass, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(TaskManagerPalette.hairline)
        }
    }

    private func summaryItem(
        value: Int,
        label: String,
        color: Color,
        isSelected: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("\(value)")
                    .font(.taskUtility(12, weight: .bold))
                    .foregroundStyle(color)
                Text(label)
                    .font(.taskUtility(9, weight: .medium))
                    .tracking(0.45)
                    .foregroundStyle(TaskManagerPalette.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 24)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color.opacity(0.12))
                        .padding(.horizontal, 3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(accessibilityLabel)
        .help(accessibilityLabel)
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(TaskManagerPalette.hairline)
            .frame(width: 1, height: 18)
    }

    private var controls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TaskManagerPalette.secondary)
                TextField("Search tasks or projects", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.taskHeading(12, weight: .medium))
                    .foregroundStyle(TaskManagerPalette.porcelain)
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(TaskManagerPalette.slateGlass, in: RoundedRectangle(cornerRadius: TaskManagerMetrics.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: TaskManagerMetrics.controlRadius, style: .continuous)
                    .stroke(TaskManagerPalette.hairline)
            }

            HStack(spacing: 8) {
                filterMenu
                sortMenu
                optionsMenu
            }
        }
        .padding(.horizontal, TaskManagerMetrics.outerPadding)
        .padding(.bottom, 11)
    }

    private var filterMenu: some View {
        Menu {
            ForEach(TaskStatusFilter.selectableCases, id: \.self) { filter in
                categoryMenuOption(filter)
            }
        } label: {
            controlLabel(icon: "line.3.horizontal.decrease", title: model.statusFilterLabel)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
    }

    private func categoryMenuOption(_ filter: TaskStatusFilter) -> some View {
        Toggle(
            filter.label,
            isOn: Binding(
                get: { model.isStatusFilterSelected(filter) },
                set: { _ in model.toggleStatusFilter(filter) }
            )
        )
    }

    private var sortMenu: some View {
        Menu {
            ForEach(TaskSortMode.allCases, id: \.self) { sort in
                Button {
                    model.sort = sort
                } label: {
                    if model.sort == sort {
                        Label(sort.label, systemImage: "checkmark")
                    } else {
                        Text(sort.label)
                    }
                }
            }
        } label: {
            controlLabel(icon: "arrow.up.arrow.down", title: model.sort.label)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Group by project", isOn: $model.groupByProject)
                .disabled(model.sort.forcesGrouping)
            if model.groupByProject {
                Toggle("Priority first", isOn: $model.priorityFirstWithinProjects)
            }
            Toggle("Show project names", isOn: $model.showProjectNames)
            Divider()
            Button("Arrange projects…") { showsProjectArrangement = true }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TaskManagerPalette.secondary)
                .frame(width: 35, height: 32)
                .background(TaskManagerPalette.slateGlass, in: RoundedRectangle(cornerRadius: TaskManagerMetrics.controlRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: TaskManagerMetrics.controlRadius, style: .continuous)
                        .stroke(TaskManagerPalette.hairline)
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func controlLabel(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title.uppercased())
                .font(.taskUtility(9, weight: .semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
        }
        .foregroundStyle(TaskManagerPalette.secondary)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(TaskManagerPalette.slateGlass, in: RoundedRectangle(cornerRadius: TaskManagerMetrics.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TaskManagerMetrics.controlRadius, style: .continuous)
                .stroke(TaskManagerPalette.hairline)
        }
    }

    @ViewBuilder
    private var taskContent: some View {
        let presentation = model.presentation
        if model.isLoading && model.tasks.isEmpty {
            Spacer()
            ProgressView()
                .controlSize(.small)
                .tint(TaskManagerPalette.mineralTeal)
            Text("Reading Codex tasks…")
                .font(.taskUtility(10))
                .foregroundStyle(TaskManagerPalette.secondary)
                .padding(.top, 8)
            Spacer()
        } else if presentation.totalCount == 0 {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(presentation.sections) { section in
                        if section.isPinnedSection {
                            pinnedSection(section)
                        } else if section.projectPath != nil || model.effectiveGroupByProject {
                            groupedSection(section)
                        } else {
                            ungroupedSection(section)
                        }
                    }
                }
                .padding(.horizontal, TaskManagerMetrics.outerPadding)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.visible)
        }
    }

    private func pinnedSection(_ section: TaskSection) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("PINNED")
                    .font(.taskUtility(9, weight: .semibold))
                    .tracking(0.45)
                Spacer()
                Text("\(section.tasks.count)")
                    .font(.taskUtility(9, weight: .semibold))
            }
            .foregroundStyle(TaskManagerPalette.secondary.opacity(0.75))
            .padding(.horizontal, 2)

            ForEach(section.tasks) { task in
                taskCard(task)
            }
        }
    }

    private func groupedSection(_ section: TaskSection) -> some View {
        let isCollapsed = section.projectPath.map(model.isProjectCollapsed) ?? false
        return VStack(alignment: .leading, spacing: 7) {
            if let path = section.projectPath,
               model.showProjectNames || model.isProjectPinned(path) {
                projectHeader(path: path, count: section.totalCount, isCollapsible: true)
            }
            if !isCollapsed {
                ForEach(section.tasks) { task in
                    taskCard(task)
                }
                if (section.isLimited || model.expandedProjectPaths.contains(section.projectPath ?? "")),
                   let projectPath = section.projectPath {
                    projectDisclosure(section: section, projectPath: projectPath)
                }
            }
        }
    }

    private func projectDisclosure(section: TaskSection, projectPath: String) -> some View {
        let isExpanded = model.expandedProjectPaths.contains(projectPath)
        return Button {
            model.toggleDisclosure(for: projectPath)
        } label: {
            HStack(spacing: 6) {
                Text(isExpanded ? "SHOW LESS (4)" : "SHOW MORE (\(section.totalCount))")
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.taskUtility(9, weight: .semibold))
            .tracking(0.35)
            .foregroundStyle(TaskManagerPalette.secondary)
            .frame(maxWidth: .infinity, minHeight: 31)
            .background(TaskManagerPalette.slateGlass.opacity(0.56), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(TaskManagerPalette.hairline)
            }
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Show four tasks in this project" : "Show all tasks in this project")
    }

    private func ungroupedSection(_ section: TaskSection) -> some View {
        ForEach(section.tasks) { task in
            VStack(alignment: .leading, spacing: 7) {
                if model.showProjectNames {
                    projectHeader(path: task.projectPath, count: 1)
                }
                taskCard(task)
            }
        }
    }

    private func projectHeader(path: String, count: Int, isCollapsible: Bool = false) -> some View {
        let isCollapsed = model.isProjectCollapsed(path)
        let projectName = URL(fileURLWithPath: path).lastPathComponent.isEmpty
            ? "Home"
            : URL(fileURLWithPath: path).lastPathComponent
        return HStack(spacing: 7) {
            if model.isProjectPinned(path) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(TaskManagerPalette.burntAmber)
                    .frame(width: 15, height: 28)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onEnded { value in
                                guard abs(value.translation.height) > abs(value.translation.width),
                                      abs(value.translation.height) >= 12
                                else { return }
                                let steps = max(1, Int(abs(value.translation.height) / 70))
                                model.movePinnedProject(
                                    path,
                                    by: value.translation.height < 0 ? -steps : steps
                                )
                            }
                    )
                    .help("Drag to reorder pinned projects")
                    .accessibilityLabel("Reorder pinned project \(projectName)")
            }
            if isCollapsible {
                Button {
                    model.toggleProjectCollapsed(path)
                } label: {
                    projectHeaderLabel(
                        projectName: projectName,
                        count: count,
                        isCollapsed: isCollapsed,
                        showsDisclosure: true
                    )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help(isCollapsed ? "Expand \(projectName)" : "Collapse \(projectName)")
                .accessibilityLabel("\(projectName) project")
                .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            } else {
                projectHeaderLabel(
                    projectName: projectName,
                    count: count,
                    isCollapsed: false,
                    showsDisclosure: false
                )
            }
        }
        .padding(.horizontal, 2)
        .help(isCollapsible ? (isCollapsed ? "Expand \(projectName)" : "Collapse \(projectName)") : path)
        .contextMenu {
            Button {
                model.toggleProjectPin(path)
            } label: {
                Label(
                    model.isProjectPinned(path) ? "Unpin project" : "Pin project",
                    systemImage: model.isProjectPinned(path) ? "pin.slash" : "pin"
                )
            }

            Divider()

            Button {
                Task { await model.markAllAsRead(in: path) }
            } label: {
                Label("Mark all as read", systemImage: "envelope.open")
            }
            .disabled(model.projectUnreadCount(path) == 0)

            Button {
                Task { await model.pauseAllTasks(in: path) }
            } label: {
                Label("Pause all tasks", systemImage: "pause.circle")
            }
            .disabled(model.projectRunningCount(path) == 0)
        }
    }

    private func projectHeaderLabel(
        projectName: String,
        count: Int,
        isCollapsed: Bool,
        showsDisclosure: Bool
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TaskManagerPalette.secondary.opacity(0.75))
            Text(projectName)
                .font(.taskUtility(9, weight: .semibold))
                .tracking(0.45)
                .foregroundStyle(TaskManagerPalette.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if count > 1 {
                Text("\(count)")
                    .font(.taskUtility(9, weight: .semibold))
                    .foregroundStyle(TaskManagerPalette.secondary.opacity(0.7))
            }
            if showsDisclosure {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(TaskManagerPalette.secondary.opacity(0.72))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func taskCard(_ task: CodexTask) -> some View {
        HStack(spacing: 7) {
            if task.isPinned {
                pinHandle(task)
            }

            Button {
                model.open(task)
            } label: {
                HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title)
                        .font(.taskHeading(13, weight: .bold))
                        .foregroundStyle(TaskManagerPalette.porcelain)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(task.latestAssistantMessage)
                        .font(.taskHeading(11, weight: .regular))
                        .foregroundStyle(TaskManagerPalette.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                statusIndicator(task.state)
                    .frame(width: 82, alignment: .trailing)

                Capsule()
                    .fill(TaskManagerPalette.color(for: task.state))
                    .frame(width: 2.5, height: 38)
                }
                .padding(.leading, 13)
                .padding(.trailing, 9)
                .frame(height: 62)
                .background(TaskManagerPalette.slateGlass, in: RoundedRectangle(cornerRadius: TaskManagerMetrics.cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: TaskManagerMetrics.cardRadius, style: .continuous)
                        .stroke(TaskManagerPalette.hairline)
                }
                .contentShape(RoundedRectangle(cornerRadius: TaskManagerMetrics.cardRadius, style: .continuous))
            }
            .buttonStyle(TaskCardButtonStyle())
        }
        .contextMenu {
            taskContextMenu(task)
        }
        .disabled(model.approvalActionsInFlight.contains(task.id))
        .help("Open \(task.title) in Codex")
    }

    private func pinHandle(_ task: CodexTask) -> some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(TaskManagerPalette.burntAmber)
            .frame(width: 15, height: 42)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onEnded { value in
                        guard abs(value.translation.height) > abs(value.translation.width),
                              abs(value.translation.height) >= 12
                        else { return }
                        let steps = max(1, Int(abs(value.translation.height) / 70))
                        model.movePinnedTask(
                            task.id,
                            by: value.translation.height < 0 ? -steps : steps
                        )
                    }
            )
            .help("Drag to reorder pinned tasks")
            .accessibilityLabel("Reorder pinned task \(task.title)")
    }

    @ViewBuilder
    private func taskContextMenu(_ task: CodexTask) -> some View {
        Button {
            model.togglePin(task)
        } label: {
            Label(task.isPinned ? "Unpin task" : "Pin task", systemImage: task.isPinned ? "pin.slash" : "pin")
        }

        if task.state != .needsResponse && task.state != .idle {
            Divider()
        }

        switch task.state {
        case .needsApproval:
            // Experimental external callback actions are deliberately not
            // exposed here. Codex's own Allow once / Allow similar commands
            // buttons own the original callback and are therefore more
            // reliable. The disabled reference UI and controller code are
            // retained behind CODEX_TASK_MANAGER_EXPERIMENTAL_APPROVAL_ACTIONS
            // for a future revisit.
            /*
            Button {
                Task { await model.performApprovalAction(.allowOnce, for: task) }
            } label: {
                Label("Allow once", systemImage: "checkmark.circle")
            }

            Button {
                Task { await model.performApprovalAction(.allowSimilarCommands, for: task) }
            } label: {
                Label("Allow similar commands", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Divider()
            */

            Button {
                Task { await model.performApprovalAction(.allowAllForTask, for: task) }
            } label: {
                Label("Allow all commands for this task", systemImage: "checkmark.shield")
            }
        case .running:
            Button {
                Task { await model.pause(task) }
            } label: {
                Label("Pause task", systemImage: "pause.circle")
            }
        case .complete:
            Button {
                Task { await model.markAsRead(task) }
            } label: {
                Label("Mark as read", systemImage: "envelope.open")
            }
        case .needsResponse, .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private func statusIndicator(_ state: TaskAttentionState) -> some View {
        switch state {
        case .needsApproval:
            Text("NEEDS\nAPPROVAL")
                .font(.taskUtility(8, weight: .bold))
                .tracking(0.2)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(TaskManagerPalette.danger)
        case .needsResponse:
            Text("NEEDS\nINPUT")
                .font(.taskUtility(8, weight: .bold))
                .tracking(0.2)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(TaskManagerPalette.burntAmber)
        case .running:
            HStack(spacing: 6) {
                ReducedMotionSpinner()
                Text("RUNNING")
                    .font(.taskUtility(8, weight: .bold))
                    .tracking(0.25)
            }
            .foregroundStyle(TaskManagerPalette.mineralTeal)
        case .complete:
            HStack(spacing: 6) {
                Circle()
                    .fill(TaskManagerPalette.signalBlue)
                    .frame(width: 8, height: 8)
                Text("COMPLETE")
                    .font(.taskUtility(8, weight: .bold))
                    .tracking(0.25)
            }
            .foregroundStyle(TaskManagerPalette.signalBlue)
        case .idle:
            Text("READ")
                .font(.taskUtility(8, weight: .semibold))
                .tracking(0.35)
                .foregroundStyle(TaskManagerPalette.secondary.opacity(0.65))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 11) {
            Spacer()
            ZStack {
                Circle()
                    .fill(TaskManagerPalette.liftedSlate)
                    .frame(width: 48, height: 48)
                Image(systemName: model.showsOnlyNeedsAttention ? "checkmark" : "tray")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(TaskManagerPalette.secondary)
            }
            Text(model.emptyMessage)
                .font(.taskHeading(13, weight: .semibold))
                .foregroundStyle(TaskManagerPalette.porcelain)
            if model.showsOnlyNeedsAttention {
                Text("Everything can keep moving.")
                    .font(.taskHeading(11))
                    .foregroundStyle(TaskManagerPalette.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.errorMessage == nil ? TaskManagerPalette.mineralTeal : TaskManagerPalette.danger)
                .frame(width: 5, height: 5)
            Text(model.errorMessage ?? model.approvalMessage ?? "LOCAL CODEX COMPANION")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text("\(model.tasks.count) TASKS")
        }
        .font(.taskUtility(8, weight: .medium))
        .tracking(0.35)
        .foregroundStyle(TaskManagerPalette.secondary.opacity(0.7))
        .padding(.horizontal, TaskManagerMetrics.outerPadding)
        .frame(height: 30)
        .background(TaskManagerPalette.slateGlass.opacity(0.62))
        .overlay(alignment: .top) { Rectangle().fill(TaskManagerPalette.hairline).frame(height: 1) }
    }
}

private struct TaskCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.992 : 1)
            .brightness(configuration.isPressed ? 0.035 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ReducedMotionSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Circle()
                .stroke(TaskManagerPalette.mineralTeal.opacity(0.45), lineWidth: 1.5)
                .frame(width: 11, height: 11)
                .overlay(alignment: .top) {
                    Circle().fill(TaskManagerPalette.mineralTeal).frame(width: 3, height: 3)
                }
        } else {
            ProgressView()
                .controlSize(.mini)
                .tint(TaskManagerPalette.mineralTeal)
        }
    }
}
