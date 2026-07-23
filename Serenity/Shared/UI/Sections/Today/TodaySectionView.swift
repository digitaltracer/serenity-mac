import SwiftUI

/// Landing section: today's date, completion progress, and the day's tasks.
struct TodaySectionView: View {
  @EnvironmentObject private var appState: AppState

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d"
    return formatter
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.lg) {
      Text(Self.dateFormatter.string(from: Date()))
        .font(SerenityType.pageSubtitle)
        .foregroundStyle(SerenityPalette.textSecondary)

      if totalTodayCount > 0 {
        progressCard
      }

      tasksPanel
    }
  }

  private var progressCard: some View {
    SerenityCard {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
        HStack(alignment: .firstTextBaseline) {
          Text("\(completedTodayCount) of \(totalTodayCount) done")
            .font(SerenityType.bodyMedium)
          Spacer()
          Text("\(Int(completionPercent * 100))%")
            .font(SerenityType.bodyMedium)
            .monospacedDigit()
            .foregroundStyle(SerenityPalette.textSecondary)
        }

        ProgressView(value: completionPercent)
          .progressViewStyle(.linear)
      }
    }
  }

  @ViewBuilder
  private var tasksPanel: some View {
    if appState.todayTasks.isEmpty {
      SerenityCard {
        SerenityEmptyState(
          systemImage: "checkmark.circle",
          title: "No tasks scheduled for today",
          message: "You're clear. Add a task to plan something.",
          actionTitle: "Add a Task",
          action: { appState.setSection(.tasks) }
        )
        .frame(maxWidth: .infinity)
      }
    } else {
      SerenityCard(padding: 0) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(appState.todayTasks) { task in
            taskRow(task)

            if task.id != appState.todayTasks.last?.id {
              Divider()
                .padding(.leading, SerenityUI.Spacing.md)
            }
          }
        }
      }
    }
  }

  private func taskRow(_ task: TaskEntity) -> some View {
    HStack(spacing: SerenityUI.Spacing.sm) {
      Button {
        Task { await appState.toggleTaskCompletion(id: task.id) }
      } label: {
        Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 16))
          .foregroundStyle(task.completed ? SerenityPalette.accent : SerenityPalette.textSecondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(task.completed ? "Mark incomplete" : "Mark complete")

      Text(task.title)
        .font(SerenityType.body)
        .strikethrough(task.completed, color: SerenityPalette.textSecondary)
        .foregroundStyle(task.completed ? SerenityPalette.textSecondary : SerenityPalette.textPrimary)

      Spacer()

      if let dueDate = task.dueDate {
        Text(dueDate, style: .time)
          .font(SerenityType.caption)
          .monospacedDigit()
          .foregroundStyle(SerenityPalette.textSecondary)
      }
    }
    .padding(.horizontal, SerenityUI.Spacing.md)
    .padding(.vertical, 10)
  }

  private var totalTodayCount: Int {
    appState.todayTasks.count
  }

  private var completedTodayCount: Int {
    appState.todayTasks.filter { $0.completed }.count
  }

  private var completionPercent: Double {
    guard totalTodayCount > 0 else { return 0 }
    return Double(completedTodayCount) / Double(totalTodayCount)
  }
}
