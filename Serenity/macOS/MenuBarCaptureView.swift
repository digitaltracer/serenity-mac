import SwiftUI

/// Capture without raising the app. Reuses `QuickCaptureDateParser`, so "call
/// the bank tomorrow at 3pm" behaves here exactly as it does on Home.
struct MenuBarCaptureView: View {
  @ObservedObject var appState: AppState

  @State private var text = ""
  @State private var submitting = false
  @FocusState private var fieldFocused: Bool

  private var canSubmit: Bool {
    !submitting && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        TextField("Capture a task…", text: $text)
          .textFieldStyle(.plain)
          .focused($fieldFocused)
          .onSubmit { submit() }
          .serenityInputField()

        Button {
          submit()
        } label: {
          Image(systemName: "arrow.up")
            .font(SerenityType.scaledSystem(size: 12, weight: .bold))
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
      }

      Divider()
        .overlay(SerenityPalette.thinBorder)

      summary

      Divider()
        .overlay(SerenityPalette.thinBorder)

      HStack {
        Button("Open Serenity") {
          NSApp.activate(ignoringOtherApps: true)
          appState.setSection(.home)
        }
        .buttonStyle(.plain)
        .foregroundStyle(SerenityPalette.accent)

        Spacer()

        Button("Quit") {
          NSApp.terminate(nil)
        }
        .buttonStyle(.plain)
        .foregroundStyle(SerenityPalette.textSecondary)
      }
      .font(SerenityType.bodyMedium)
    }
    .padding(14)
    .frame(width: 320)
    .onAppear { fieldFocused = true }
  }

  @ViewBuilder
  private var summary: some View {
    let overdue = appState.overdueTasks.count
    let today = appState.todayTasks.filter { !$0.completed }.count

    if overdue == 0 && today == 0 {
      Text("Nothing due today.")
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
    } else {
      VStack(alignment: .leading, spacing: 6) {
        if overdue > 0 {
          Label("\(overdue) overdue", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
        if today > 0 {
          Label("\(today) due today", systemImage: "sun.max.fill")
            .foregroundStyle(SerenityPalette.textPrimary)
        }
      }
      .font(SerenityType.body)
    }
  }

  private func submit() {
    guard canSubmit else { return }
    let input = text
    submitting = true

    Task {
      defer { submitting = false }
      let parsed = QuickCaptureDateParser.parse(input)
      let created = await appState.createTask(
        title: parsed.title,
        priority: .medium,
        dueDate: parsed.dueDate,
        tags: [],
        subtaskTitles: []
      )
      if created {
        text = ""
        await appState.refreshCoreWorkflowData()
      }
    }
  }
}
