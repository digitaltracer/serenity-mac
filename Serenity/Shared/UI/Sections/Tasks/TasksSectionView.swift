import SwiftUI

/// Tasks section: task list with quick add, a read-only projects list, and a due-date calendar.
struct TasksSectionView: View {
  @EnvironmentObject private var appState: AppState

  private enum HubTab: String, CaseIterable, Identifiable {
    case tasks
    case projects
    case calendar

    var id: String { rawValue }

    var title: String {
      switch self {
      case .tasks:
        return "Tasks"
      case .projects:
        return "Projects"
      case .calendar:
        return "Calendar"
      }
    }
  }

  private enum TaskListFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case completed

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
  }

  @State private var activeTab: HubTab = .tasks
  @State private var taskFilter: TaskListFilter = .all
  @State private var searchQuery = ""
  @State private var showQuickAddForm = false

  @State private var newTaskTitle = ""
  @State private var newTaskDescription = ""
  @State private var newTaskTags: [String] = []
  @State private var newTaskTagInput = ""
  @State private var newTaskProjectID = ""
  @State private var newTaskPriority: TaskPriority = .medium
  @State private var includeDueDate = false
  @State private var dueDate = Date()
  @State private var calendarVisibleMonth = Calendar.current.startOfMonth(for: Date())
  @State private var selectedCalendarDate = Calendar.current.startOfDay(for: Date())
  @State private var subtaskDraftByTaskID: [String: String] = [:]
  @State private var expandedDescriptionTaskIDs: Set<String> = []
  @State private var editingTask: TaskEntity?
  @State private var showQuickProjectCreator = false
  @State private var quickProjectName = ""
  @State private var quickProjectDescription = ""
  @State private var quickProjectColor: Color = ProjectColorCodec.fallbackColor

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.md) {
      Picker("View", selection: $activeTab) {
        ForEach(HubTab.allCases) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 380)

      switch activeTab {
      case .tasks:
        tasksView
      case .projects:
        projectsView
      case .calendar:
        calendarView
      }
    }
  }

  private var tasksView: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.md) {
      if showQuickAddForm {
        VStack(spacing: SerenityUI.Spacing.sm) {
          progressCard
          quickAddPanel
        }
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: SerenityUI.Spacing.sm) {
            progressCard
            quickAddPanel
          }
          VStack(spacing: SerenityUI.Spacing.sm) {
            progressCard
            quickAddPanel
          }
        }
      }

      HStack(spacing: SerenityUI.Spacing.sm) {
        HStack(spacing: SerenityUI.Spacing.xs) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(SerenityPalette.textSecondary)
          TextField("Search tasks, projects, or tags...", text: $searchQuery)
            .textFieldStyle(.plain)
        }
        .serenityInputField()

        Spacer(minLength: SerenityUI.Spacing.xs)

        Picker("Filter", selection: $taskFilter) {
          ForEach(TaskListFilter.allCases) { filter in
            Text(filter.title).tag(filter)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 280)
      }

      HStack(spacing: SerenityUI.Spacing.xs) {
        Button("Complete Selected") {
          Task { await appState.markSelectedTasksCompleted() }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .disabled(appState.selectedTaskIDs.isEmpty)

        Button("Delete Selected", role: .destructive) {
          Task { await appState.deleteSelectedTasks() }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .disabled(appState.selectedTaskIDs.isEmpty)
      }

      if displayedTasks.isEmpty {
        SerenityCard {
          SerenityEmptyState(
            systemImage: "checklist",
            title: "No tasks match your filters",
            message: "Adjust the search or filters, or add a new task."
          )
          .frame(maxWidth: .infinity)
        }
      } else {
        SerenityCard(padding: 0) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(displayedTasks) { task in
              taskRow(task)

              if task.id != displayedTasks.last?.id {
                Divider()
                  .padding(.leading, SerenityUI.Spacing.md)
              }
            }
          }
        }
      }
    }
    .sheet(item: $editingTask) { task in
      TaskEditorView(task: task, availableProjects: assignableProjects) {
        title,
        description,
        priority,
        dueDate,
        projectID,
        tags in
        Task {
          await appState.updateTask(
            id: task.id,
            title: title,
            description: description,
            priority: priority,
            dueDate: dueDate,
            projectID: projectID,
            tags: tags
          )
        }
      }
      .frame(minWidth: 500, minHeight: 430)
    }
  }

  private var progressCard: some View {
    SerenityCard {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
        HStack(alignment: .firstTextBaseline) {
          Text("Overall Progress")
            .font(SerenityType.bodyMedium)
          Spacer()
          Text("\(progressPercent)%")
            .font(SerenityType.bodyMedium)
            .monospacedDigit()
            .foregroundStyle(SerenityPalette.textSecondary)
        }

        ProgressView(value: progressFraction)
          .progressViewStyle(.linear)

        VStack(spacing: SerenityUI.Spacing.xxs) {
          SerenityStatRow("Completed", value: "\(completedCount)", systemImage: "checkmark.circle", tint: .green)
          SerenityStatRow("Remaining", value: "\(max(totalTaskCount - completedCount, 0))", systemImage: "circle")
          SerenityStatRow("Total", value: "\(totalTaskCount)", systemImage: "number")
        }
        .padding(.top, SerenityUI.Spacing.xs)
      }
    }
  }

  private var quickAddPanel: some View {
    SerenityCard {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
        if showQuickAddForm {
          TextField("Task title", text: $newTaskTitle)
            .textFieldStyle(.plain)
            .serenityInputField()

          TaskMarkdownDescriptionField(text: $newTaskDescription)

          SerenityTagInputField(tags: $newTaskTags, inputText: $newTaskTagInput)

          HStack(alignment: .top, spacing: SerenityUI.Spacing.sm) {
            VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
              Text("Project")
                .font(SerenityType.caption)
                .foregroundStyle(SerenityPalette.textSecondary)
              SerenityDropdownField(
                placeholder: "No project",
                selection: $newTaskProjectID,
                options: projectDropdownOptions
              ) {
                Divider()
                Button {
                  showQuickProjectCreator = true
                } label: {
                  HStack(spacing: SerenityUI.Spacing.xs) {
                    Image(systemName: "plus.circle.fill")
                      .foregroundStyle(SerenityPalette.accent)
                    Text("Create new project")
                      .font(SerenityType.bodyMedium)
                      .foregroundStyle(SerenityPalette.textPrimary)
                    Spacer(minLength: 0)
                  }
                  .padding(.horizontal, SerenityUI.Spacing.xs)
                  .padding(.vertical, SerenityUI.Spacing.xs)
                }
                .buttonStyle(.plain)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
              Text("Priority")
                .font(SerenityType.caption)
                .foregroundStyle(SerenityPalette.textSecondary)
              SerenityDropdownField(
                placeholder: "Priority",
                selection: $newTaskPriority,
                options: priorityDropdownOptions
              )
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .frame(maxWidth: .infinity)

          if showQuickProjectCreator {
            quickProjectCreator
          }

          HStack(spacing: SerenityUI.Spacing.sm) {
            Toggle("Due date", isOn: $includeDueDate)
              .toggleStyle(.switch)
              .frame(maxWidth: 120, alignment: .leading)

            if includeDueDate {
              DueDateSelectionField(selection: $dueDate)
                .frame(maxWidth: 280, alignment: .leading)
            }

            Spacer(minLength: 0)
          }

          HStack {
            Button("Create Task") {
              let title = newTaskTitle
              let description = newTaskDescription
              let tags = tagsIncludingPendingInput(newTaskTags, input: newTaskTagInput)
              let projectID = newTaskProjectID.isEmpty ? nil : newTaskProjectID
              let priority = newTaskPriority
              let taskDueDate = includeDueDate ? dueDate : nil

              Task {
                let created = await appState.createTask(
                  title: title,
                  priority: priority,
                  dueDate: taskDueDate,
                  tags: tags,
                  subtaskTitles: [],
                  description: description,
                  projectID: projectID
                )

                guard created else { return }
                newTaskTitle = ""
                newTaskDescription = ""
                newTaskTags = []
                newTaskTagInput = ""
                newTaskProjectID = ""
                searchQuery = ""
                taskFilter = .all
                includeDueDate = false
                resetQuickProjectForm()
                showQuickProjectCreator = false
                showQuickAddForm = false
              }
            }
            .buttonStyle(SerenityPrimaryButtonStyle())
            .disabled(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Cancel") {
              newTaskTags = []
              newTaskTagInput = ""
              resetQuickProjectForm()
              showQuickProjectCreator = false
              showQuickAddForm = false
            }
            .buttonStyle(SerenitySecondaryButtonStyle())
          }
        } else {
          Button {
            showQuickAddForm = true
          } label: {
            VStack(spacing: SerenityUI.Spacing.xs) {
              Image(systemName: "plus")
                .font(.title2.weight(.light))
                .foregroundStyle(SerenityPalette.textSecondary)
              Text("Add new task...")
                .font(SerenityType.bodyMedium)
                .foregroundStyle(SerenityPalette.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
            .background(
              RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous)
                .stroke(SerenityPalette.thinBorder, style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
            )
            .contentShape(RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous))
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var quickProjectCreator: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
      Label(
        assignableProjects.isEmpty ? "Create a project to organize this task" : "New project",
        systemImage: "folder.badge.plus"
      )
      .font(SerenityType.bodyMedium)
      .foregroundStyle(SerenityPalette.textPrimary)

      TextField("Project name", text: $quickProjectName)
        .textFieldStyle(.plain)
        .serenityInputField()

      TextField("Description (optional)", text: $quickProjectDescription)
        .textFieldStyle(.plain)
        .serenityInputField()

      HStack(spacing: SerenityUI.Spacing.xs) {
        ColorPicker("Project color", selection: $quickProjectColor, supportsOpacity: false)
          .labelsHidden()
        Text(ProjectColorCodec.hex(from: quickProjectColor))
          .font(.caption.monospaced())
          .foregroundStyle(SerenityPalette.textSecondary)

        Spacer()

        Button("Cancel") {
          resetQuickProjectForm()
          showQuickProjectCreator = false
        }
        .buttonStyle(SerenitySecondaryButtonStyle())

        Button("Create Project") {
          let name = quickProjectName
          let description = quickProjectDescription
          let colorHex = ProjectColorCodec.hex(from: quickProjectColor)

          Task {
            guard let project = await appState.createProject(
              name: name,
              description: description,
              color: colorHex
            ) else {
              return
            }

            newTaskProjectID = project.id
            resetQuickProjectForm()
            showQuickProjectCreator = false
          }
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
        .disabled(quickProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(SerenityUI.Spacing.sm)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
  }

  @ViewBuilder
  private func taskRow(_ task: TaskEntity) -> some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
      HStack(spacing: SerenityUI.Spacing.sm) {
        Button {
          appState.toggleTaskSelection(id: task.id)
        } label: {
          Image(systemName: appState.selectedTaskIDs.contains(task.id) ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(appState.selectedTaskIDs.contains(task.id) ? SerenityPalette.accent : SerenityPalette.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(appState.selectedTaskIDs.contains(task.id) ? "Deselect task" : "Select task")

        Button {
          Task { await appState.toggleTaskCompletion(id: task.id) }
        } label: {
          Image(systemName: task.completed ? "checkmark.square.fill" : "square")
            .foregroundStyle(task.completed ? .green : SerenityPalette.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(task.completed ? "Mark incomplete" : "Mark complete")

        taskEditorButton(task, accessibilityLabel: "Edit task \(task.title)") {
          HStack(spacing: SerenityUI.Spacing.sm) {
            Text(task.title)
              .font(SerenityType.bodyMedium)
              .strikethrough(task.completed)
              .foregroundStyle(task.completed ? SerenityPalette.textSecondary : SerenityPalette.textPrimary)
              .lineLimit(2)

            Spacer()

            SerenityBadge(task.priority.rawValue.capitalized, tint: priorityTint(task.priority))
          }
        }
      }

      taskEditorButton(task, accessibilityLabel: "Edit task \(task.title) details") {
        HStack(spacing: SerenityUI.Spacing.xs) {
          SerenityBadge("Created \(task.createdAt.formatted(date: .numeric, time: .omitted))")
          if let dueDate = task.dueDate {
            SerenityBadge(
              "Due \(dueDate.formatted(date: .numeric, time: .omitted))",
              tint: isOverdue(task) ? .red : SerenityPalette.accent
            )
          }
          if let projectName = projectName(for: task.projectId) {
            SerenityBadge(projectName, tint: SerenityPalette.accent)
          }
        }
      }

      if let description = task.description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        taskDescriptionPreview(task: task, description: description)
      }

      if !task.tags.isEmpty {
        taskEditorButton(task, accessibilityLabel: "Edit task \(task.title) tags") {
          HStack(spacing: SerenityUI.Spacing.xxs) {
            ForEach(task.tags.prefix(4), id: \.self) { tag in
              SerenityBadge(tag)
            }
            if task.tags.count > 4 {
              SerenityBadge("+\(task.tags.count - 4)")
            }
          }
        }
      }

      if !task.subtasks.isEmpty {
        VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
          ForEach(task.subtasks, id: \.id) { subtask in
            Button {
              Task { await appState.toggleSubtask(taskID: task.id, subtaskID: subtask.id) }
            } label: {
              HStack(spacing: SerenityUI.Spacing.xxs) {
                Image(systemName: subtask.completed ? "checkmark.circle.fill" : "circle")
                  .foregroundStyle(subtask.completed ? .green : SerenityPalette.textSecondary)
                Text(subtask.title)
                  .font(SerenityType.caption)
                  .strikethrough(subtask.completed)
                Spacer()
              }
            }
            .buttonStyle(.plain)
          }
        }
      }

      HStack {
        TextField("Add subtask", text: subtaskBinding(for: task.id))
          .textFieldStyle(.plain)
          .serenityInputField()

        Button("Add") {
          let subtaskText = subtaskBinding(for: task.id).wrappedValue
          Task { await appState.addSubtask(taskID: task.id, title: subtaskText) }
          subtaskBinding(for: task.id).wrappedValue = ""
        }
        .buttonStyle(SerenitySecondaryButtonStyle())

        Spacer()

        Button("Edit") {
          openTaskEditor(task)
        }
        .buttonStyle(SerenitySecondaryButtonStyle())

        Button("Delete", role: .destructive) {
          Task { await appState.deleteTask(id: task.id) }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
      }
    }
    .padding(.horizontal, SerenityUI.Spacing.md)
    .padding(.vertical, SerenityUI.Spacing.sm)
  }

  private func taskEditorButton<Content: View>(
    _ task: TaskEntity,
    accessibilityLabel: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    Button {
      openTaskEditor(task)
    } label: {
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(.isButton)
  }

  private func openTaskEditor(_ task: TaskEntity) {
    editingTask = task
  }

  private func taskDescriptionPreview(task: TaskEntity, description: String) -> some View {
    let shouldCollapse = TaskMarkdownParser.shouldCollapseInTaskList(description)
    let isExpanded = expandedDescriptionTaskIDs.contains(task.id)

    return VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
      taskEditorButton(task, accessibilityLabel: "Edit task \(task.title) description") {
        GitHubFlavoredMarkdownView(markdown: description, compact: !isExpanded)
          .frame(maxWidth: .infinity, alignment: .leading)
          .frame(maxHeight: shouldCollapse && !isExpanded ? 132 : nil, alignment: .top)
          .clipped()
          .mask(alignment: .bottom) {
            if shouldCollapse && !isExpanded {
              VStack(spacing: 0) {
                Rectangle()
                LinearGradient(
                  colors: [.black, .black.opacity(0)],
                  startPoint: .top,
                  endPoint: .bottom
                )
                .frame(height: 28)
              }
            } else {
              Rectangle()
            }
          }
      }

      if shouldCollapse {
        Button {
          withAnimation(.easeInOut(duration: 0.18)) {
            if isExpanded {
              expandedDescriptionTaskIDs.remove(task.id)
            } else {
              expandedDescriptionTaskIDs.insert(task.id)
            }
          }
        } label: {
          Label(isExpanded ? "Show less" : "Read more", systemImage: isExpanded ? "chevron.up" : "chevron.down")
            .font(SerenityType.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(SerenityPalette.accent)
      }
    }
  }

  @ViewBuilder
  private var projectsView: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
      SerenitySectionHeader("Projects")

      if appState.projects.isEmpty {
        SerenityCard {
          SerenityEmptyState(
            systemImage: "folder",
            title: "No projects yet",
            message: "Create one from task assignments."
          )
          .frame(maxWidth: .infinity)
        }
      } else {
        SerenityCard(padding: 0) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(appState.projects) { project in
              HStack {
                Text(project.name)
                  .font(SerenityType.body)
                Spacer()
                SerenityBadge(
                  project.archived ? "Archived" : "Active",
                  tint: project.archived ? SerenityPalette.textSecondary : .green
                )
              }
              .padding(.horizontal, SerenityUI.Spacing.md)
              .padding(.vertical, 10)

              if project.id != appState.projects.last?.id {
                Divider()
                  .padding(.leading, SerenityUI.Spacing.md)
              }
            }
          }
        }
      }
    }
  }

  private var calendarView: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
      HStack(alignment: .top, spacing: SerenityUI.Spacing.sm) {
        VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
          Text("Schedule Calendar")
            .font(SerenityType.sectionTitle)
          Text("\(dueTasksSorted.count) task\(dueTasksSorted.count == 1 ? "" : "s") with due dates")
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)
        }

        Spacer(minLength: SerenityUI.Spacing.md)

        SerenityBadge("Today \(appState.todayTasks.count)", tint: SerenityPalette.accent)
        SerenityBadge("Overdue \(appState.overdueTasks.count)", tint: appState.overdueTasks.isEmpty ? SerenityPalette.textSecondary : .red)

        HStack(spacing: SerenityUI.Spacing.xxs) {
          Button {
            shiftCalendarMonth(by: -1)
          } label: {
            Image(systemName: "chevron.left")
              .font(SerenityType.caption)
              .frame(width: 26, height: 26)
          }
          .buttonStyle(SerenitySecondaryButtonStyle())

          Text(calendarVisibleMonth.formatted(.dateTime.month(.wide).year()))
            .font(SerenityType.bodyMedium)
            .frame(minWidth: 170, alignment: .center)

          Button {
            shiftCalendarMonth(by: 1)
          } label: {
            Image(systemName: "chevron.right")
              .font(SerenityType.caption)
              .frame(width: 26, height: 26)
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
        }

        Button("Today") {
          jumpCalendarToToday()
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
      }

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: SerenityUI.Spacing.sm) {
          calendarMonthPanel
          calendarAgendaPanel
            .frame(width: 340)
        }

        VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
          calendarMonthPanel
          calendarAgendaPanel
        }
      }
    }
  }

  private var totalTaskCount: Int {
    appState.tasks.count
  }

  private var completedCount: Int {
    appState.tasks.filter(\.completed).count
  }

  private var progressFraction: Double {
    guard totalTaskCount > 0 else { return 0 }
    return Double(completedCount) / Double(totalTaskCount)
  }

  private var progressPercent: Int {
    Int(progressFraction * 100)
  }

  private var displayedTasks: [TaskEntity] {
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    return appState.tasks
      .filter { task in
        switch taskFilter {
        case .all:
          break
        case .active:
          if task.completed { return false }
        case .completed:
          if !task.completed { return false }
        }

        guard !query.isEmpty else { return true }
        let haystack = [
          task.title,
          task.description ?? "",
          task.tags.joined(separator: " "),
          task.subtasks.map(\.title).joined(separator: " "),
        ]
          .joined(separator: " ")
          .lowercased()
        return haystack.contains(query)
      }
      .sorted { lhs, rhs in
        (lhs.dueDate ?? lhs.createdAt) < (rhs.dueDate ?? rhs.createdAt)
      }
  }

  private var dueTasksSorted: [TaskEntity] {
    appState.tasks
      .filter { $0.dueDate != nil }
      .sorted { lhs, rhs in
        (lhs.dueDate ?? lhs.createdAt) < (rhs.dueDate ?? rhs.createdAt)
      }
  }

  private var dueTasksByDay: [Date: [TaskEntity]] {
    Dictionary(grouping: dueTasksSorted) { task in
      Calendar.current.startOfDay(for: task.dueDate ?? task.createdAt)
    }
  }

  private var selectedDayStart: Date {
    Calendar.current.startOfDay(for: selectedCalendarDate)
  }

  private var selectedDayTasks: [TaskEntity] {
    (dueTasksByDay[selectedDayStart] ?? [])
      .sorted { lhs, rhs in
        (lhs.dueDate ?? lhs.createdAt) < (rhs.dueDate ?? rhs.createdAt)
      }
  }

  private var calendarWeekdaySymbols: [String] {
    Calendar.current.orderedVeryShortStandaloneWeekdaySymbols()
  }

  private var calendarGridDates: [Date] {
    Calendar.current.monthGridDates(for: calendarVisibleMonth)
  }

  private var calendarMonthPanel: some View {
    SerenityCard {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
        HStack(spacing: SerenityUI.Spacing.xs) {
          ForEach(Array(calendarWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
            Text(symbol)
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
              .frame(maxWidth: .infinity)
          }
        }
        .padding(.horizontal, SerenityUI.Spacing.xxs)

        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
          ForEach(calendarGridDates, id: \.self) { date in
            calendarDayCell(date)
          }
        }
      }
    }
  }

  private var calendarAgendaPanel: some View {
    SerenityCard {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
        HStack(alignment: .firstTextBaseline) {
          Text(selectedDayStart.formatted(date: .complete, time: .omitted))
            .font(SerenityType.sectionTitle)
            .lineLimit(1)
          Spacer(minLength: SerenityUI.Spacing.xs)
          SerenityBadge("\(selectedDayTasks.count) due", tint: SerenityPalette.accent)
        }

        HStack(spacing: SerenityUI.Spacing.xs) {
          SerenityBadge("\(selectedDayTasks.filter { !$0.completed }.count) open", tint: .orange)
          SerenityBadge("\(selectedDayTasks.filter(\.completed).count) done", tint: .green)
        }

        if selectedDayTasks.isEmpty {
          Text("No tasks due on this date.")
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)
            .padding(.top, 2)
        } else {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(selectedDayTasks.prefix(8))) { task in
              calendarAgendaTaskRow(task)

              if task.id != selectedDayTasks.prefix(8).last?.id {
                Divider()
              }
            }
          }

          if selectedDayTasks.count > 8 {
            Text("+\(selectedDayTasks.count - 8) more due task\(selectedDayTasks.count - 8 == 1 ? "" : "s")")
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
              .padding(.top, 2)
          }
        }
      }
    }
  }

  private func calendarDayCell(_ date: Date) -> some View {
    let calendar = Calendar.current
    let dayStart = calendar.startOfDay(for: date)
    let isSelected = calendar.isDate(dayStart, inSameDayAs: selectedDayStart)
    let isInVisibleMonth = calendar.isDate(dayStart, equalTo: calendarVisibleMonth, toGranularity: .month)
    let isToday = calendar.isDateInToday(dayStart)
    let dueItems = dueTasksByDay[dayStart] ?? []
    let openDueCount = dueItems.filter { !$0.completed }.count

    return Button {
      selectedCalendarDate = dayStart
      calendarVisibleMonth = calendar.startOfMonth(for: dayStart)
    } label: {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
        Text("\(calendar.component(.day, from: dayStart))")
          .font(SerenityType.bodyMedium.weight(isSelected || isToday ? .semibold : .regular))
          .foregroundStyle(isToday ? SerenityPalette.accent : SerenityPalette.textPrimary)

        Spacer(minLength: 0)

        if !dueItems.isEmpty {
          HStack(spacing: SerenityUI.Spacing.xxs) {
            Circle()
              .fill(openDueCount == 0 ? Color.green : SerenityPalette.accent)
              .frame(width: 6, height: 6)

            Text("\(dueItems.count)")
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
          }
        }
      }
      .padding(SerenityUI.Spacing.xs)
      .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
      .background(
        isSelected ? SerenityPalette.activeItemBackground : Color.clear,
        in: RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous)
          .stroke(isToday ? SerenityPalette.accent : SerenityPalette.thinBorder, lineWidth: 1)
      )
      .opacity(isInVisibleMonth ? 1 : 0.44)
      .contentShape(RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  private func calendarAgendaTaskRow(_ task: TaskEntity) -> some View {
    HStack(alignment: .top, spacing: SerenityUI.Spacing.xs) {
      Circle()
        .fill(task.completed ? Color.green : priorityTint(task.priority))
        .frame(width: 8, height: 8)
        .padding(.top, 4)

      VStack(alignment: .leading, spacing: 2) {
        Text(task.title)
          .font(SerenityType.bodyMedium)
          .strikethrough(task.completed)
          .lineLimit(2)

        HStack(spacing: SerenityUI.Spacing.xxs) {
          if let dueDate = task.dueDate {
            Text(dueDate.formatted(date: .omitted, time: .shortened))
          }
          if let projectName = projectName(for: task.projectId) {
            Text(projectName)
          }
        }
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
      }

      Spacer(minLength: 0)
    }
    .padding(.vertical, SerenityUI.Spacing.xs)
  }

  private func jumpCalendarToToday() {
    let today = Calendar.current.startOfDay(for: Date())
    selectedCalendarDate = today
    calendarVisibleMonth = Calendar.current.startOfMonth(for: today)
  }

  private func shiftCalendarMonth(by value: Int) {
    let calendar = Calendar.current
    guard let shifted = calendar.date(byAdding: .month, value: value, to: calendarVisibleMonth) else { return }
    let monthStart = calendar.startOfMonth(for: shifted)
    let preferredDay = calendar.component(.day, from: selectedCalendarDate)
    let dayCount = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
    let clampedDay = min(preferredDay, dayCount)
    let nextSelected = calendar.date(byAdding: .day, value: clampedDay - 1, to: monthStart) ?? monthStart
    calendarVisibleMonth = monthStart
    selectedCalendarDate = calendar.startOfDay(for: nextSelected)
  }

  private func isOverdue(_ task: TaskEntity) -> Bool {
    guard let dueDate = task.dueDate else { return false }
    return !task.completed && dueDate < Calendar.current.startOfDay(for: Date())
  }

  private func priorityTint(_ priority: TaskPriority) -> Color {
    switch priority {
    case .low:
      return .green
    case .medium:
      return SerenityPalette.textSecondary
    case .high:
      return .red
    }
  }

  private func priorityIcon(_ priority: TaskPriority) -> String {
    switch priority {
    case .low:
      return "arrow.down.circle"
    case .medium:
      return "equal.circle"
    case .high:
      return "exclamationmark.circle"
    }
  }

  private func subtaskBinding(for taskID: String) -> Binding<String> {
    Binding(
      get: { subtaskDraftByTaskID[taskID, default: ""] },
      set: { subtaskDraftByTaskID[taskID] = $0 }
    )
  }

  private var assignableProjects: [ProjectEntity] {
    appState.projects.filter { !$0.archived }
  }

  private var projectDropdownOptions: [SerenityDropdownOption<String>] {
    [SerenityDropdownOption(value: "", title: "No project", systemImage: "minus.circle")] +
      assignableProjects.map { project in
        SerenityDropdownOption(
          value: project.id,
          title: project.name,
          subtitle: project.description,
          tint: ProjectColorCodec.color(from: project.color) ?? SerenityPalette.accent
        )
      }
  }

  private var priorityDropdownOptions: [SerenityDropdownOption<TaskPriority>] {
    TaskPriority.allCases.map { priority in
      SerenityDropdownOption(
        value: priority,
        title: priority.rawValue.capitalized,
        systemImage: priorityIcon(priority),
        tint: priorityTint(priority)
      )
    }
  }

  private func projectName(for projectID: String?) -> String? {
    guard let projectID else { return nil }
    return appState.projects.first(where: { $0.id == projectID })?.name
  }

  private func resetQuickProjectForm() {
    quickProjectName = ""
    quickProjectDescription = ""
    quickProjectColor = ProjectColorCodec.fallbackColor
  }
}
