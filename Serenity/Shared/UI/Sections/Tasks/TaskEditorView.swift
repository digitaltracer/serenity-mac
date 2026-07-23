import SwiftUI

/// Sheet editor for an existing task: title, description, priority, due date, project, tags.
struct TaskEditorView: View {
  let task: TaskEntity
  let availableProjects: [ProjectEntity]
  let onSave: (String, String, TaskPriority, Date?, String?, [String]) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var title: String
  @State private var description: String
  @State private var priority: TaskPriority
  @State private var hasDueDate: Bool
  @State private var dueDate: Date
  @State private var selectedProjectID: String
  @State private var tags: [String]
  @State private var tagInputText = ""

  init(
    task: TaskEntity,
    availableProjects: [ProjectEntity],
    onSave: @escaping (String, String, TaskPriority, Date?, String?, [String]) -> Void
  ) {
    self.task = task
    self.availableProjects = availableProjects
    self.onSave = onSave
    _title = State(initialValue: task.title)
    _description = State(initialValue: task.description ?? "")
    _priority = State(initialValue: task.priority)
    _hasDueDate = State(initialValue: task.dueDate != nil)
    _dueDate = State(initialValue: task.dueDate ?? Date())
    _selectedProjectID = State(initialValue: task.projectId ?? "")
    _tags = State(initialValue: task.tags)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
      Text("Edit Task")
        .font(SerenityType.sectionTitle)

      TextField("Title", text: $title)
        .textFieldStyle(.plain)
        .serenityInputField()

      TaskMarkdownDescriptionField(text: $description, minHeight: 150)

      HStack(spacing: SerenityUI.Spacing.sm) {
        SerenityDropdownField(
          placeholder: "Priority",
          selection: $priority,
          options: priorityDropdownOptions
        )
        .frame(maxWidth: 180)

        Toggle("Due date", isOn: $hasDueDate)
          .toggleStyle(.switch)

        if hasDueDate {
          DueDateSelectionField(selection: $dueDate)
            .frame(maxWidth: 280, alignment: .leading)
        }
      }

      SerenityDropdownField(
        placeholder: "No project",
        selection: $selectedProjectID,
        options: projectDropdownOptions
      )
      .frame(maxWidth: 260)

      SerenityTagInputField(tags: $tags, inputText: $tagInputText)

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .buttonStyle(SerenitySecondaryButtonStyle())

        Button("Save") {
          onSave(
            title,
            description,
            priority,
            hasDueDate ? dueDate : nil,
            selectedProjectID.isEmpty ? nil : selectedProjectID,
            tagsIncludingPendingInput(tags, input: tagInputText)
          )
          dismiss()
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
      }
    }
    .padding(SerenityUI.Spacing.lg)
  }

  private var projectDropdownOptions: [SerenityDropdownOption<String>] {
    [SerenityDropdownOption(value: "", title: "No project", systemImage: "minus.circle")] +
      availableProjects.map { project in
        SerenityDropdownOption(
          value: project.id,
          title: project.name,
          subtitle: project.description,
          tint: ProjectColorCodec.color(from: project.color) ?? SerenityPalette.accent
        )
      }
  }

  private var priorityDropdownOptions: [SerenityDropdownOption<TaskPriority>] {
    TaskPriority.allCases.map { value in
      SerenityDropdownOption(
        value: value,
        title: value.rawValue.capitalized,
        systemImage: priorityIcon(value),
        tint: priorityTint(value)
      )
    }
  }

  private func priorityIcon(_ value: TaskPriority) -> String {
    switch value {
    case .low:
      return "arrow.down.circle"
    case .medium:
      return "equal.circle"
    case .high:
      return "exclamationmark.circle"
    }
  }

  private func priorityTint(_ value: TaskPriority) -> Color {
    switch value {
    case .low:
      return .green
    case .medium:
      return SerenityPalette.textSecondary
    case .high:
      return .red
    }
  }
}
