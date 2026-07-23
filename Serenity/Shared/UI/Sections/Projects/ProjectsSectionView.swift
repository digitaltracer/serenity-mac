import SwiftUI

/// Projects section: new-project form and the project list with archive/edit/delete actions.
struct ProjectsSectionView: View {
  @EnvironmentObject private var appState: AppState

  @State private var newProjectName = ""
  @State private var newProjectDescription = ""
  @State private var newProjectColor: Color = ProjectColorCodec.fallbackColor
  @State private var editingProject: ProjectEntity?

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.lg) {
      newProjectPanel
      projectsPanel
    }
    .sheet(item: $editingProject) { project in
      ProjectEditorView(project: project) { name, description, color in
        Task {
          await appState.updateProject(id: project.id, name: name, description: description, color: color)
        }
      }
      .frame(minWidth: 420, minHeight: 260)
    }
  }

  // MARK: New project

  private var newProjectPanel: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
      SerenitySectionHeader("New Project")

      SerenityCard {
        VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
          TextField("Project name", text: $newProjectName)
            .textFieldStyle(.plain)
            .serenityInputField()

          TextField("Description", text: $newProjectDescription)
            .textFieldStyle(.plain)
            .serenityInputField()

          HStack(spacing: SerenityUI.Spacing.xs) {
            ColorPicker("Project color", selection: $newProjectColor, supportsOpacity: false)
            Text(ProjectColorCodec.hex(from: newProjectColor))
              .font(.caption.monospaced())
              .foregroundStyle(SerenityPalette.textSecondary)
          }

          HStack {
            Button("Create Project") {
              createProject()
            }
            .buttonStyle(SerenityPrimaryButtonStyle())

            Toggle("Include archived", isOn: $appState.includeArchivedProjects)
              .onChange(of: appState.includeArchivedProjects) { _, _ in
                Task {
                  await appState.refreshCoreWorkflowData()
                }
              }
          }
        }
      }
    }
  }

  private func createProject() {
    let name = newProjectName
    let description = newProjectDescription
    let colorHex = ProjectColorCodec.hex(from: newProjectColor)

    Task {
      await appState.createProject(
        name: name,
        description: description,
        color: colorHex
      )
    }

    newProjectName = ""
    newProjectDescription = ""
    newProjectColor = ProjectColorCodec.fallbackColor
  }

  // MARK: Project list

  private var projectsPanel: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
      SerenitySectionHeader("Projects", subtitle: "\(appState.projects.count) total")

      if appState.projects.isEmpty {
        SerenityCard {
          SerenityEmptyState(
            systemImage: "folder",
            title: "No projects available",
            message: "Create a project above to organize your work."
          )
          .frame(maxWidth: .infinity)
        }
      } else {
        SerenityCard(padding: 0) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(appState.projects) { project in
              projectRow(project)

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

  private func projectRow(_ project: ProjectEntity) -> some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
      HStack(alignment: .top, spacing: SerenityUI.Spacing.sm) {
        Circle()
          .fill(ProjectColorCodec.color(from: project.color) ?? Color.secondary)
          .frame(width: 10, height: 10)
          .padding(.top, 4)

        VStack(alignment: .leading, spacing: 2) {
          Text(project.name)
            .font(SerenityType.bodyMedium)
            .foregroundStyle(SerenityPalette.textPrimary)

          Text(project.description ?? "No description")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)

          Text(project.color)
            .font(.caption2.monospaced())
            .foregroundStyle(SerenityPalette.textSecondary)
        }

        Spacer(minLength: SerenityUI.Spacing.xs)

        if project.archived {
          SerenityBadge("Archived", systemImage: "archivebox")
        }
      }

      HStack(spacing: SerenityUI.Spacing.xs) {
        Button(project.archived ? "Unarchive" : "Archive") {
          Task {
            await appState.toggleProjectArchive(id: project.id)
          }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())

        Button("Edit") {
          editingProject = project
        }
        .buttonStyle(SerenitySecondaryButtonStyle())

        Spacer()

        Button("Delete", role: .destructive) {
          Task {
            await appState.deleteProject(id: project.id)
          }
        }
        .buttonStyle(.borderless)
      }
    }
    .padding(SerenityUI.Spacing.md)
  }
}
