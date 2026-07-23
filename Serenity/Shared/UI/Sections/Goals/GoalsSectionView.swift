import SwiftUI

/// Goals section: progress overview, new-goal form, and the tracked goal list.
struct GoalsSectionView: View {
  @EnvironmentObject private var appState: AppState

  @State private var newGoalTitle = ""
  @State private var newGoalTarget = "5"
  @State private var newGoalType: GoalType = .weeklyTasks
  @State private var newGoalPriority: GoalPriority = .medium

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.lg) {
      goalsOverview
      newGoalPanel
      goalsPanel
    }
  }

  // MARK: Overview

  private var goalsOverview: some View {
    SerenityCard {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
        SerenityStatRow(
          "Active",
          value: "\(appState.goals.filter { $0.status == .active }.count)",
          systemImage: "target",
          tint: SerenityPalette.accent
        )
        SerenityStatRow(
          "Completed",
          value: "\(appState.goals.filter { $0.status == .completed }.count)",
          systemImage: "checkmark.seal",
          tint: .green
        )
        SerenityStatRow(
          "Average progress",
          value: averageGoalProgress,
          systemImage: "chart.line.uptrend.xyaxis",
          tint: .orange
        )
      }
    }
  }

  // MARK: New goal

  private var newGoalPanel: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
      SerenitySectionHeader("New Goal", subtitle: "Define a target and track it over time")

      SerenityCard {
        VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
          labeledControl("Goal title") {
            TextField("Goal title", text: $newGoalTitle)
              .textFieldStyle(.plain)
              .serenityInputField()
          }

          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: SerenityUI.Spacing.sm) {
              targetField
              goalTypeField
              priorityField
            }

            VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
              targetField
              goalTypeField
              priorityField
            }
          }

          HStack(spacing: SerenityUI.Spacing.xs) {
            Button {
              createGoal()
            } label: {
              Label("Create Goal", systemImage: "plus")
            }
            .buttonStyle(SerenityPrimaryButtonStyle())

            Button {
              Task {
                await appState.refreshCoreWorkflowData()
              }
            } label: {
              Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SerenitySecondaryButtonStyle())
          }
        }
      }
    }
  }

  private var targetField: some View {
    labeledControl("Target") {
      TextField("5", text: $newGoalTarget)
        .textFieldStyle(.plain)
        .serenityInputField()
    }
    .frame(maxWidth: 140, alignment: .leading)
  }

  private var goalTypeField: some View {
    labeledControl("Type") {
      SerenityDropdownField(
        placeholder: "Type",
        selection: $newGoalType,
        options: goalTypeOptions
      )
    }
    .frame(maxWidth: 260, alignment: .leading)
  }

  private var priorityField: some View {
    labeledControl("Priority") {
      SerenityDropdownField(
        placeholder: "Priority",
        selection: $newGoalPriority,
        options: goalPriorityOptions
      )
    }
    .frame(maxWidth: 200, alignment: .leading)
  }

  private func labeledControl<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
      Text(title)
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
      content()
    }
  }

  // MARK: Goal list

  private var goalsPanel: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
      SerenitySectionHeader("Goals", subtitle: "\(appState.goals.count) total")

      if appState.goals.isEmpty {
        SerenityCard {
          SerenityEmptyState(
            systemImage: "target",
            title: "No goals yet",
            message: "Create a goal above to start tracking progress."
          )
          .frame(maxWidth: .infinity)
        }
      } else {
        SerenityCard(padding: 0) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(appState.goals) { goal in
              goalRow(goal)

              if goal.id != appState.goals.last?.id {
                Divider()
                  .padding(.leading, SerenityUI.Spacing.md)
              }
            }
          }
        }
      }
    }
  }

  private func goalRow(_ goal: GoalEntity) -> some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
      HStack(alignment: .top, spacing: SerenityUI.Spacing.sm) {
        Image(systemName: icon(for: goal.type))
          .font(.subheadline)
          .foregroundStyle(tint(for: goal.priority))
          .frame(width: 20, alignment: .center)

        VStack(alignment: .leading, spacing: 2) {
          Text(goal.title)
            .font(SerenityType.bodyMedium)
            .foregroundStyle(SerenityPalette.textPrimary)
            .lineLimit(2)

          Text("\(goal.progress.current, specifier: "%.0f") / \(goal.progress.target, specifier: "%.0f") - \(goal.progress.percentage, specifier: "%.0f")%")
            .font(SerenityType.caption)
            .monospacedDigit()
            .foregroundStyle(SerenityPalette.textSecondary)
        }

        Spacer(minLength: SerenityUI.Spacing.xs)

        SerenityBadge(goal.status.rawValue.capitalized, tint: statusTint(for: goal.status))
      }

      ProgressView(value: min(goal.progress.percentage, 100), total: 100)
        .progressViewStyle(.linear)

      HStack(spacing: SerenityUI.Spacing.xs) {
        Text(goalTypeTitle(goal.type))
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)

        Text(goal.priority.rawValue.capitalized)
          .font(SerenityType.caption)
          .foregroundStyle(tint(for: goal.priority))

        Spacer(minLength: SerenityUI.Spacing.xs)

        Button {
          Task {
            await appState.incrementGoalProgress(id: goal.id)
          }
        } label: {
          Label("Increment", systemImage: "plus")
        }
        .buttonStyle(SerenitySecondaryButtonStyle())

        Button(role: .destructive) {
          Task {
            await appState.deleteGoal(id: goal.id)
          }
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .buttonStyle(.borderless)
      }
    }
    .padding(SerenityUI.Spacing.md)
  }

  // MARK: Helpers

  private func createGoal() {
    let target = Double(newGoalTarget) ?? 1
    Task {
      await appState.createGoal(
        title: newGoalTitle,
        target: target,
        type: newGoalType,
        priority: newGoalPriority
      )
    }

    newGoalTitle = ""
    newGoalTarget = "5"
  }

  private var averageGoalProgress: String {
    guard !appState.goals.isEmpty else { return "0%" }
    let average = appState.goals.map(\.progress.percentage).reduce(0, +) / Double(appState.goals.count)
    return String(format: "%.0f%%", average)
  }

  private var goalTypeOptions: [SerenityDropdownOption<GoalType>] {
    goalTypes.map { type in
      SerenityDropdownOption(
        value: type,
        title: goalTypeTitle(type),
        subtitle: goalTypeSubtitle(type),
        systemImage: icon(for: type),
        tint: SerenityPalette.accent
      )
    }
  }

  private var goalPriorityOptions: [SerenityDropdownOption<GoalPriority>] {
    goalPriorities.map { priority in
      SerenityDropdownOption(
        value: priority,
        title: priority.rawValue.capitalized,
        systemImage: priority == .high ? "exclamationmark.triangle.fill" : "circle.fill",
        tint: tint(for: priority)
      )
    }
  }

  private func goalTypeTitle(_ type: GoalType) -> String {
    switch type {
    case .weeklyTasks:
      return "Weekly Tasks"
    case .projectTasks:
      return "Project Tasks"
    case .priorityTasks:
      return "Priority Tasks"
    case .dailyStreak:
      return "Daily Streak"
    case .journalWeekly:
      return "Weekly Journal"
    case .completionRate:
      return "Completion Rate"
    }
  }

  private func goalTypeSubtitle(_ type: GoalType) -> String {
    switch type {
    case .weeklyTasks:
      return "Finish a set number of tasks"
    case .projectTasks:
      return "Move project work forward"
    case .priorityTasks:
      return "Stay focused on high-value tasks"
    case .dailyStreak:
      return "Build a daily habit"
    case .journalWeekly:
      return "Keep reflection consistent"
    case .completionRate:
      return "Improve overall follow-through"
    }
  }

  private func icon(for type: GoalType) -> String {
    switch type {
    case .weeklyTasks:
      return "checklist"
    case .projectTasks:
      return "folder"
    case .priorityTasks:
      return "flag.fill"
    case .dailyStreak:
      return "flame.fill"
    case .journalWeekly:
      return "book.closed.fill"
    case .completionRate:
      return "chart.pie.fill"
    }
  }

  private func tint(for priority: GoalPriority) -> Color {
    switch priority {
    case .low:
      return .green
    case .medium:
      return SerenityPalette.accent
    case .high:
      return .orange
    }
  }

  private func statusTint(for status: GoalStatus) -> Color {
    switch status {
    case .active:
      return SerenityPalette.accent
    case .completed:
      return .green
    case .paused:
      return .orange
    case .failed:
      return .red
    }
  }

  private var goalTypes: [GoalType] {
    [.weeklyTasks, .projectTasks, .priorityTasks, .dailyStreak, .journalWeekly, .completionRate]
  }

  private var goalPriorities: [GoalPriority] {
    [.low, .medium, .high]
  }
}
