import SwiftUI

/// Sheet editor for an existing project: name, description, color.
struct ProjectEditorView: View {
  let project: ProjectEntity
  let onSave: (String, String, String) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var name: String
  @State private var description: String
  @State private var color: Color

  init(project: ProjectEntity, onSave: @escaping (String, String, String) -> Void) {
    self.project = project
    self.onSave = onSave
    _name = State(initialValue: project.name)
    _description = State(initialValue: project.description ?? "")
    _color = State(initialValue: ProjectColorCodec.color(from: project.color) ?? ProjectColorCodec.fallbackColor)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
      Text("Edit Project")
        .font(SerenityType.sectionTitle)

      TextField("Name", text: $name)
        .textFieldStyle(.plain)
        .serenityInputField()

      TextField("Description", text: $description)
        .textFieldStyle(.plain)
        .serenityInputField()

      HStack(spacing: SerenityUI.Spacing.xs) {
        ColorPicker("Project color", selection: $color, supportsOpacity: false)
        Text(ProjectColorCodec.hex(from: color))
          .font(.caption.monospaced())
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .buttonStyle(SerenitySecondaryButtonStyle())

        Button("Save") {
          onSave(name, description, ProjectColorCodec.hex(from: color))
          dismiss()
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
      }
    }
    .padding(SerenityUI.Spacing.lg)
  }
}
