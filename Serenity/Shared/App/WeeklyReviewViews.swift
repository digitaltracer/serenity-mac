import SwiftUI

/// Last week's recap, the four-step review, and past reviews.
struct WeeklyReviewSectionView: View {
  @EnvironmentObject private var appState: AppState
  @State private var mode: Mode = .recap
  @State private var preparing = false

  enum Mode: Equatable {
    case recap
    case guided
    case history(String)
  }

  var body: some View {
    let start = WeeklyReview.reviewedWeekStart(for: Date())
    let key = WeeklyReview.weekKey(forWeekStart: start)
    let recap = appState.weeklyRecap(weekStart: start)
    let review = appState.weeklyReview(forWeek: key)

    Group {
      switch mode {
      case .recap:
        WeeklyRecapView(recap: recap, review: review, preparing: preparing, onStart: { mode = .guided }, onOpenHistory: { mode = .history($0) })
      case .guided:
        if let review {
          GuidedWeeklyReview(recap: recap, review: review, onBack: { mode = .recap })
        } else {
          ProgressView().frame(maxWidth: .infinity)
        }
      case .history(let weekKey):
        if let past = appState.weeklyReview(forWeek: weekKey) {
          WeeklyReviewHistoryDetail(review: past, onBack: { mode = .recap })
        }
      }
    }
    .task(id: key) {
      preparing = true
      await appState.prepareWeeklyReview(weekStart: start)
      preparing = false
    }
  }
}

// MARK: - Shared pieces

private enum ReviewStyle {
  static func tint(for kind: WeeklyFinding.Kind) -> Color {
    switch kind {
    case .goalAtRisk, .deepWorkBelowBaseline: return SerenityPalette.attention
    case .routineAfterLateEvening, .moodAfterBusyDays, .observation: return SerenityPalette.accent
    case .stuckTask, .quietArea: return SerenityPalette.textSecondary
    }
  }

  static var format: RecapFormat { RecapFormat(calendar: WeeklyReview.calendar, locale: .current) }

  static func weekRange(_ start: Date) -> String {
    format.range(start, WeeklyReview.calendar.date(byAdding: .day, value: 7, to: start) ?? start)
  }
}

private struct ReviewPill: View {
  let text: String
  let tint: Color

  var body: some View {
    Text(text)
      .font(SerenityType.caption.weight(.semibold))
      .foregroundStyle(tint)
      .lineLimit(1)
      .padding(.horizontal, 10)
      .frame(height: 22)
      .background(tint.opacity(0.14), in: Capsule())
  }
}

private extension View {
  func reviewPanel() -> some View {
    padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(SerenityPalette.border, lineWidth: 1))
  }
}

private struct ReviewSectionHeader: View {
  let title: String
  var trailing: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(SerenityType.bodyLarge.weight(.semibold))
        .foregroundStyle(SerenityPalette.textPrimary)
      Spacer(minLength: 8)
      if let trailing {
        Text(trailing)
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }
    }
  }
}

/// Before and after lines for a goal, shared by the recap and the goals step.
enum ReviewGoalText {
  static func line(_ change: WeeklyRecap.GoalChange, format: RecapFormat) -> String {
    if change.kind == .area {
      guard let last = change.lastActivity else { return "Nothing logged yet" }
      return (change.after.daysQuiet ?? 0) >= GoalReports.defaultQuietDays ? "Quiet since \(format.date(last))" : "Last touched \(format.date(last))"
    }
    if change.needsSetup { return "Not counting anything yet" }
    let unit = change.unit.isEmpty ? "" : " \(change.unit)"
    var parts = ["\(GoalReport.format(change.before.current)) → \(GoalReport.format(change.after.current)) of \(GoalReport.format(change.after.target))\(unit)"]
    if let expected = change.after.expected, change.kind == .outcome {
      parts.append("even pace needs \(GoalReport.format(expected.rounded()))")
    }
    if let due = change.dueDate {
      parts.append("due \(format.date(due))")
    }
    return parts.joined(separator: " · ")
  }

  static func pill(_ change: WeeklyRecap.GoalChange) -> (text: String, tint: Color) {
    if change.isPaused { return ("Paused", SerenityPalette.textSecondary) }
    if change.needsSetup { return ("Needs setup", SerenityPalette.textSecondary) }
    if case .behind(let after) = change.after.pace {
      if case .behind(let before) = change.before.pace, before != after {
        return ("\(GoalReport.format(before)) → \(GoalReport.format(after)) behind", SerenityPalette.attention)
      }
      return (change.after.statusLabel, SerenityPalette.attention)
    }
    if change.kind == .area, (change.after.daysQuiet ?? 0) >= GoalReports.defaultQuietDays {
      return (change.after.statusLabel, SerenityPalette.attention)
    }
    return (change.after.statusLabel, SerenityPalette.accent)
  }
}

// MARK: - Recap (5a)

private struct WeeklyRecapView: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.serenityCompactLayout) private var compactLayout
  let recap: WeeklyRecap
  let review: WeeklyReviewEntity?
  let preparing: Bool
  let onStart: () -> Void
  let onOpenHistory: (String) -> Void

  @State private var selectedDay = 0

  private var format: RecapFormat { ReviewStyle.format }

  var body: some View {
    let findings = review?.payload.preparedAt != nil ? review!.payload.findings : recap.findings

    VStack(alignment: .leading, spacing: 18) {
      header
      if let line = loopLine {
        Label(line, systemImage: "arrow.triangle.2.circlepath")
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      metrics
      dayChart
      findingsSection(findings)
      if !recap.carryOver.isEmpty, review?.completedAt == nil {
        carrySection
      }
      if !recap.goals.isEmpty {
        goalsSection
      }
      sourcesLine
      historySection
    }
    .onAppear {
      let today = WeeklyReview.calendar.component(.weekday, from: Date())
      selectedDay = recap.days.lastIndex { $0.focusHours > 0 || !$0.done.isEmpty } ?? (today == 2 ? 6 : 0)
    }
  }

  /// How the changes from the review before went.
  private var loopLine: String? {
    guard let start = WeeklyReview.calendar.date(byAdding: .day, value: -7, to: recap.weekStart),
          let previous = appState.weeklyReview(forWeek: WeeklyReview.weekKey(forWeekStart: start))
    else { return nil }
    return WeeklyReview.loopLine(for: previous)
  }

  private var header: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 16) {
        headerText
        Spacer(minLength: 12)
        startButton
      }
      VStack(alignment: .leading, spacing: 12) {
        headerText
        startButton
      }
    }
  }

  private var headerText: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Week of \(ReviewStyle.weekRange(recap.weekStart))")
        .font(SerenityType.sectionTitle)
        .foregroundStyle(SerenityPalette.textPrimary)
      Text(recap.hasPatterns
        ? "Compared with your four weeks before it. Pick a day to see what's behind it."
        : "Plain numbers for now. Patterns appear after 4 weeks of use.")
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
    }
  }

  @ViewBuilder
  private var startButton: some View {
    if let completed = review?.completedAt {
      Label("Reviewed \(completed.formatted(.dateTime.weekday(.wide)))", systemImage: "checkmark.circle.fill")
        .font(SerenityType.bodyMedium)
        .foregroundStyle(SerenityPalette.routineAccent)
    } else {
      Button(action: onStart) {
        Label("Start the review · 4 steps", systemImage: "arrow.right")
      }
      .buttonStyle(SerenityPrimaryButtonStyle())
      .hoverCursor(.pointingHand)
      .disabled(review == nil)
    }
  }

  // MARK: Metrics

  private var metrics: some View {
    let tiles = metricTiles
    return LazyVGrid(columns: [GridItem(.adaptive(minimum: compactLayout ? 150 : 200), spacing: 12)], alignment: .leading, spacing: 12) {
      ForEach(tiles, id: \.title) { tile in
        VStack(alignment: .leading, spacing: 6) {
          Text(tile.title)
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
          Text(tile.value)
            .font(SerenityType.scaledSystem(size: 22, weight: .semibold))
            .foregroundStyle(SerenityPalette.textPrimary)
          if !tile.detail.isEmpty {
            Text(tile.detail)
              .font(SerenityType.caption)
              .foregroundStyle(tile.warn ? SerenityPalette.attention : SerenityPalette.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .reviewPanel()
        .accessibilityElement(children: .combine)
      }
    }
  }

  private struct Tile {
    let title: String
    let value: String
    let detail: String
    let warn: Bool
  }

  private var metricTiles: [Tile] {
    var tiles: [Tile] = []
    var taskDetail: [String] = []
    if let usual = recap.tasks.baseline { taskDetail.append("Usual week: \(format.decimal(usual))") }
    let projects = recap.tasks.byProject.prefix(3).map { "\($0.name) \($0.count)" }
    if !projects.isEmpty { taskDetail.append(projects.joined(separator: ", ")) }
    tiles.append(Tile(title: "Tasks finished", value: "\(recap.tasks.done)", detail: taskDetail.joined(separator: " · "), warn: false))

    let focus = recap.focus
    var focusDetail: [String] = []
    var warn = false
    if let target = focus.target {
      let gap = target - focus.hours
      if gap > 0.05 {
        focusDetail.append("\(format.hours(gap)) short")
        warn = true
      } else {
        focusDetail.append("Target met")
      }
    }
    if let usual = focus.baseline { focusDetail.append("usual \(format.hours(usual))") }
    if !focus.emptyDays.isEmpty, focus.emptyDays.count <= 3 { focusDetail.append("nothing on \(format.dayList(focus.emptyDays))") }
    let focusValue = focus.target.map { "\(format.hours(focus.hours)) of \(GoalReport.format($0))" } ?? format.hours(focus.hours)
    tiles.append(Tile(title: "Deep work", value: focusValue, detail: focusDetail.joined(separator: " · "), warn: warn))

    let routines = recap.routines.sorted { ($0.missed.count, $0.expected) > ($1.missed.count, $1.expected) }.prefix(2)
    for routine in routines {
      var detail: [String] = []
      if !routine.missed.isEmpty { detail.append("Missed \(format.dayList(routine.missed))") }
      if let usual = routine.baseline { detail.append("usual \(format.decimal(usual))") }
      tiles.append(Tile(title: routine.title, value: "\(routine.done) of \(routine.expected) days", detail: detail.joined(separator: " · "), warn: !routine.missed.isEmpty))
    }
    return tiles
  }

  // MARK: Days

  private var topProjects: [String] {
    var totals: [String: Double] = [:]
    for day in recap.days {
      for slice in day.focus where slice.projectId != nil { totals[slice.name, default: 0] += slice.hours }
    }
    return totals.sorted { $0.value > $1.value }.prefix(2).map(\.key)
  }

  private func color(for name: String, top: [String]) -> Color {
    switch top.firstIndex(of: name) {
    case 0: return SerenityPalette.accent
    case 1: return SerenityPalette.attention
    default: return SerenityPalette.textSecondary.opacity(0.55)
    }
  }

  private var dayChart: some View {
    let top = topProjects
    let maxHours = max(recap.days.map(\.focusHours).max() ?? 0, 1)
    let marked = recap.routines.first { $0.expected > 0 }
    let selected = recap.days[min(selectedDay, recap.days.count - 1)]

    return VStack(alignment: .leading, spacing: 14) {
      ReviewSectionHeader(title: "Deep work by day, by project")
      HStack(spacing: 12) {
        ForEach(top + ["Other"], id: \.self) { name in
          HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color(for: name, top: top)).frame(width: 10, height: 10)
            Text(name).font(SerenityType.caption).foregroundStyle(SerenityPalette.textSecondary)
          }
        }
        HStack(spacing: 6) {
          Circle().fill(SerenityPalette.attention).frame(width: 6, height: 6)
          Text("Event at 19:00 or later").font(SerenityType.caption).foregroundStyle(SerenityPalette.textSecondary)
        }
      }
      HStack(alignment: .bottom, spacing: 8) {
        ForEach(Array(recap.days.enumerated()), id: \.offset) { index, day in
          Button {
            selectedDay = index
          } label: {
            VStack(spacing: 6) {
              Circle().fill(day.lateEvent == nil ? Color.clear : SerenityPalette.attention).frame(width: 6, height: 6)
              Text(day.focusHours == 0 ? "0 h" : format.hours(day.focusHours))
                .font(SerenityType.caption)
                .foregroundStyle(SerenityPalette.textSecondary)
              VStack(spacing: 1) {
                ForEach(Array(day.focus.reversed().enumerated()), id: \.offset) { _, slice in
                  Rectangle()
                    .fill(color(for: slice.projectId == nil ? "Other" : slice.name, top: top))
                    .frame(height: max(CGFloat(slice.hours / maxHours) * 110, 3))
                }
              }
              .frame(maxWidth: 34)
              .frame(height: 112, alignment: .bottom)
              Text(format.weekday(day.date))
                .font(SerenityType.bodyMedium)
                .foregroundStyle(SerenityPalette.textPrimary)
              Text(dayCaption(day))
                .font(SerenityType.caption)
                .foregroundStyle(SerenityPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
              if let marked {
                RoundedRectangle(cornerRadius: 2)
                  .fill(markColor(day.routineMarks[marked.routineId]))
                  .frame(width: 8, height: 8)
              }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(index == selectedDay ? SerenityPalette.activeItemBackground : Color.clear)
            )
          }
          .buttonStyle(.plain)
          .hoverCursor(.pointingHand)
          .accessibilityLabel("\(format.dayLabel(day.date)): \(format.hours(day.focusHours)) focus, \(day.done.count) tasks finished")
          .accessibilityAddTraits(index == selectedDay ? .isSelected : [])
        }
      }
      if let marked {
        Text("Small square: \(marked.title) done (green) or missed (amber).\(recap.usedJournal ? " Mood is from that day's journal entry, out of 5." : "")")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }
      Divider()
      dayDetail(selected)
    }
    .reviewPanel()
  }

  private func dayCaption(_ day: WeeklyRecap.Day) -> String {
    var caption = "\(day.done.count) done"
    if recap.usedJournal, let mood = day.mood { caption += " · mood \(mood)" }
    return caption
  }

  private func markColor(_ mark: RoutineDayMark?) -> Color {
    switch mark {
    case .done: return SerenityPalette.routineAccent
    case .missed: return SerenityPalette.attention
    default: return SerenityPalette.thinBorder
    }
  }

  private func dayDetail(_ day: WeeklyRecap.Day) -> some View {
    let sessions = day.sessions.isEmpty ? ["No focus sessions"] : day.sessions.map { "\($0.title) · \(format.hoursOneDecimal($0.hours))\($0.projectName.map { " · \($0)" } ?? "")" }
    let done = day.done.isEmpty ? ["Nothing finished"] : day.done.map(\.title)
    var notes = day.calendar.map { "Calendar: \($0.title), \(format.time($0.date))" }
    if recap.usedJournal {
      notes += day.journal.map { "Journal: “\($0.excerpt)”" }
    }
    if notes.isEmpty { notes = ["Nothing on the calendar\(recap.usedJournal ? " or in the journal" : "")"] }

    return VStack(alignment: .leading, spacing: 10) {
      Text("\(format.weekday(day.date)) \(format.date(day.date))")
        .font(SerenityType.bodyMedium)
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 18) {
          detailColumn("Focus", sessions)
          detailColumn("Finished", done)
          detailColumn(recap.usedJournal ? "Journal and calendar" : "Calendar", notes)
        }
        VStack(alignment: .leading, spacing: 12) {
          detailColumn("Focus", sessions)
          detailColumn("Finished", done)
          detailColumn(recap.usedJournal ? "Journal and calendar" : "Calendar", notes)
        }
      }
    }
  }

  private func detailColumn(_ title: String, _ lines: [String]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(SerenityType.caption.weight(.semibold))
        .foregroundStyle(SerenityPalette.textSecondary)
      ForEach(Array(lines.prefix(8).enumerated()), id: \.offset) { _, line in
        Text(line)
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  // MARK: Findings

  private func findingsSection(_ findings: [WeeklyFinding]) -> some View {
    let hidden = Set(review?.payload.feedback.map(\.findingId) ?? [])
    let acted = Set(review?.payload.liveActions.compactMap(\.findingId) ?? [])
    let waiting = findings.filter { !hidden.contains($0.id) && !acted.contains($0.id) }.count
    let title = findings.count == 1 ? "One thing worth acting on" : (findings.count == 2 ? "Two things worth acting on" : "Three things worth acting on")

    return VStack(alignment: .leading, spacing: 12) {
      if findings.isEmpty {
        ReviewSectionHeader(title: preparing ? "Looking at the week…" : "Nothing stood out this week")
        if !preparing {
          Text(recap.hasPatterns ? "No goal slipped and nothing broke from your usual week." : "Patterns appear after 4 weeks of use.")
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)
        }
      } else {
        ReviewSectionHeader(title: title, trailing: waiting == 0 ? "All handled" : "\(waiting) waiting on you")
        ForEach(findings) { finding in
          if let review {
            WeeklyFindingCard(finding: finding, review: review)
          }
        }
      }
    }
  }

  // MARK: Open items

  private var carrySection: some View {
    let choices = review?.payload.carry ?? [:]
    let undecided = recap.carryOver.filter { choices[$0.taskId] == nil }.count
    return VStack(alignment: .leading, spacing: 12) {
      ReviewSectionHeader(title: "Still open from last week", trailing: undecided == 0 ? "All decided" : "\(undecided) to decide · nothing moves until you save the review")
      ReviewCarryList(items: recap.carryOver, choices: choices) { taskId, choice in
        guard let review else { return }
        Task {
          await appState.updateWeeklyReview(weekKey: review.weekKey) { payload in
            payload.carry[taskId] = payload.carry[taskId] == choice ? nil : choice
          }
        }
      }
    }
    .reviewPanel()
  }

  // MARK: Goals

  private var goalsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        ReviewSectionHeader(title: "Goals: last Monday to this one")
        Button("Open Goals") { appState.setSection(.goals) }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
      }
      ForEach(recap.goals, id: \.goalId) { change in
        let pill = ReviewGoalText.pill(change)
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(change.title).font(SerenityType.bodyMedium)
            Text(ReviewGoalText.line(change, format: format))
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
          }
          Spacer(minLength: 8)
          ReviewPill(text: pill.text, tint: pill.tint)
        }
      }
    }
    .reviewPanel()
  }

  private var sourcesLine: some View {
    let sources = recap.sources
    var parts = [
      format.count(sources.tasks, "finished task"),
      format.count(sources.sessions, "focus session"),
    ]
    if recap.usedJournal { parts.append(format.count(sources.journal, "journal entry", plural: "journal entries")) }
    parts.append(format.count(sources.routineChecks, "routine check-in"))
    parts.append(format.count(sources.calendar, "calendar event"))
    let model = review?.payload.writtenByModel == true ? " Your AI provider only reworded the findings." : ""
    return Text("Counted in Serenity from \(format.list(parts)).\(model)")
      .font(SerenityType.caption)
      .foregroundStyle(SerenityPalette.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: History

  @ViewBuilder
  private var historySection: some View {
    let past = appState.weeklyReviews.filter { $0.completedAt != nil && $0.weekKey != review?.weekKey }
    if !past.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        ReviewSectionHeader(title: "Past reviews")
        ForEach(past.prefix(12)) { item in
          Button {
            onOpenHistory(item.weekKey)
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text("Week of \(ReviewStyle.weekRange(item.weekStart))").font(SerenityType.bodyMedium)
                Text(historySummary(item))
                  .font(SerenityType.caption)
                  .foregroundStyle(SerenityPalette.textSecondary)
              }
              Spacer()
              Image(systemName: "chevron.right").foregroundStyle(SerenityPalette.textSecondary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .hoverCursor(.pointingHand)
        }
      }
      .reviewPanel()
    }
  }

  private func historySummary(_ review: WeeklyReviewEntity) -> String {
    let snapshot = review.payload.snapshot
    let changes = review.payload.liveActions.count
    return [
      format.count(snapshot.tasksDone, "task"),
      "\(format.hours(snapshot.focusHours)) focus",
      format.count(review.payload.findings.count, "finding"),
      format.count(changes, "change"),
    ].joined(separator: " · ")
  }
}

// MARK: - Finding card

private struct WeeklyFindingCard: View {
  @EnvironmentObject private var appState: AppState
  let finding: WeeklyFinding
  let review: WeeklyReviewEntity
  var readOnly = false

  @State private var evidenceOpen = false
  @State private var reasonsOpen = false
  @State private var working = false

  private var accepted: WeeklyAcceptedAction? {
    review.payload.liveActions.first { $0.findingId == finding.id }
  }

  private var feedback: WeeklyFindingFeedback? {
    review.payload.feedback.first { $0.findingId == finding.id }
  }

  var body: some View {
    if let feedback, !readOnly {
      HStack {
        Text("Hidden: “\(finding.title)”. You'll see fewer like this.")
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
        Spacer()
        Button("Undo") {
          Task { await appState.undoNotUseful(feedback.findingId, weekKey: review.weekKey) }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)
      }
      .reviewPanel()
    } else {
      card
    }
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        ReviewPill(text: finding.tag, tint: ReviewStyle.tint(for: finding.kind))
        if !finding.linked.isEmpty {
          Text(finding.linked)
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
            .lineLimit(1)
        }
      }
      Text(finding.title)
        .font(SerenityType.bodyLarge.weight(.semibold))
        .foregroundStyle(SerenityPalette.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      Text(finding.body)
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      Button {
        withAnimation(.easeOut(duration: 0.15)) { evidenceOpen.toggle() }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .rotationEffect(.degrees(evidenceOpen ? 90 : 0))
          Text(finding.evidenceLabel)
        }
        .font(SerenityType.caption.weight(.medium))
        .foregroundStyle(SerenityPalette.accent)
      }
      .buttonStyle(.plain)
      .hoverCursor(.pointingHand)
      .accessibilityValue(evidenceOpen ? "Shown" : "Hidden")

      if evidenceOpen {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(finding.evidence.enumerated()), id: \.offset) { _, row in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              Text(row.when)
                .font(SerenityType.caption.weight(.semibold))
                .foregroundStyle(SerenityPalette.textSecondary)
                .frame(width: 92, alignment: .leading)
              Text(row.what)
                .font(SerenityType.caption)
                .foregroundStyle(SerenityPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
              Text(row.meta)
                .font(SerenityType.caption)
                .foregroundStyle(SerenityPalette.textSecondary)
            }
          }
        }
        .padding(10)
        .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      }

      if !readOnly {
        actions
      } else if let accepted {
        Label(accepted.title, systemImage: "checkmark")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.routineAccent)
      }
    }
    .reviewPanel()
  }

  @ViewBuilder
  private var actions: some View {
    if let accepted {
      HStack(alignment: .firstTextBaseline) {
        Label(actedText(accepted), systemImage: "checkmark.circle.fill")
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.routineAccent)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Button("Undo") {
          working = true
          Task {
            await appState.undoReviewAction(accepted.id, weekKey: review.weekKey)
            working = false
          }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)
        .disabled(working)
      }
    } else {
      SerenityFlowLayout(spacing: 8) {
        if let title = finding.actionTitle, finding.action != nil {
          Button(title) {
            working = true
            Task {
              await appState.acceptFinding(finding.id, weekKey: review.weekKey)
              working = false
            }
          }
          .buttonStyle(SerenityPrimaryButtonStyle())
          .hoverCursor(.pointingHand)
          .disabled(working)
        }
        Button("Not useful") {
          withAnimation(.easeOut(duration: 0.15)) { reasonsOpen.toggle() }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)
      }
      if reasonsOpen {
        VStack(alignment: .leading, spacing: 6) {
          Text("What's off?")
            .font(SerenityType.caption.weight(.semibold))
            .foregroundStyle(SerenityPalette.textSecondary)
          SerenityFlowLayout(spacing: 8) {
            ForEach(WeeklyFindingFeedback.Reason.allCases, id: \.self) { reason in
              Button(reason.label) {
                Task { await appState.markFindingNotUseful(finding.id, reason: reason, weekKey: review.weekKey) }
              }
              .buttonStyle(SerenityPillButtonStyle(selected: false))
              .hoverCursor(.pointingHand)
            }
          }
        }
      }
    }
  }

  private func actedText(_ accepted: WeeklyAcceptedAction) -> String {
    switch accepted.action {
    case .bookFocus:
      return "Booked. The blocks are on Today, and Wednesday's check-in will say whether they held."
    case .firstOnToday:
      return "It's first on Today."
    case .lateEveningReminder(_, let hour, let minute):
      return "Done. After an evening event, the next morning's reminder comes at \(hour):\(String(format: "%02d", minute))\(appState.notificationsEnabled ? "" : " once reminders are on in Settings")."
    case .scheduleTask(_, let day):
      return "Planned for \(day.formatted(.dateTime.weekday(.wide)))."
    case .pauseGoal:
      return "Paused for this week."
    }
  }
}

// MARK: - Open items list

private struct ReviewCarryList: View {
  let items: [WeeklyRecap.CarryItem]
  let choices: [String: WeeklyReviewPayload.CarryChoice]
  let pick: (String, WeeklyReviewPayload.CarryChoice) -> Void

  var body: some View {
    let format = ReviewStyle.format
    VStack(alignment: .leading, spacing: 12) {
      ForEach(items, id: \.taskId) { item in
        let choice = choices[item.taskId]
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .center, spacing: 12) {
            itemText(item, choice: choice, format: format)
            Spacer(minLength: 8)
            chips(item, choice: choice)
          }
          VStack(alignment: .leading, spacing: 8) {
            itemText(item, choice: choice, format: format)
            chips(item, choice: choice)
          }
        }
      }
    }
  }

  private func itemText(_ item: WeeklyRecap.CarryItem, choice: WeeklyReviewPayload.CarryChoice?, format: RecapFormat) -> some View {
    var meta: [String] = []
    if let project = item.projectName { meta.append(project) }
    if let due = item.dueDate { meta.append("was due \(format.date(due))") } else { meta.append("open since \(format.date(item.createdAt))") }
    if item.moves >= 2 { meta.append("moved \(item.moves) times") }
    if item.focusHours > 0 { meta.append("\(format.hours(item.focusHours)) of focus so far") }
    return VStack(alignment: .leading, spacing: 2) {
      Text(item.title)
        .font(SerenityType.bodyMedium)
        .strikethrough(choice == .drop)
        .foregroundStyle(choice == .drop ? SerenityPalette.textSecondary : SerenityPalette.textPrimary)
      Text(meta.joined(separator: " · "))
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
    }
  }

  private func chips(_ item: WeeklyRecap.CarryItem, choice: WeeklyReviewPayload.CarryChoice?) -> some View {
    HStack(spacing: 6) {
      ForEach(WeeklyReviewPayload.CarryChoice.allCases, id: \.self) { option in
        Button(WeeklyReview.carryLabel(option, now: Date())) { pick(item.taskId, option) }
          .buttonStyle(SerenityPillButtonStyle(selected: choice == option))
          .hoverCursor(.pointingHand)
          .accessibilityLabel("When to do \(item.title): \(WeeklyReview.carryLabel(option, now: Date()))")
          .accessibilityAddTraits(choice == option ? .isSelected : [])
      }
    }
  }
}

// MARK: - Guided review (5c)

private struct GuidedWeeklyReview: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.serenityCompactLayout) private var compactLayout
  let recap: WeeklyRecap
  let review: WeeklyReviewEntity
  let onBack: () -> Void

  @State private var step = 0
  @State private var draft = WeeklyReviewPayload()
  @State private var loaded = false
  @State private var ownPick = ""
  @State private var saving = false

  private let steps = ["Look back", "Settle open items", "Goals", "Next week"]
  private var format: RecapFormat { ReviewStyle.format }

  private var findings: [WeeklyFinding] {
    let hidden = Set(draft.feedback.map(\.findingId))
    return draft.findings.filter { !hidden.contains($0.id) }
  }

  private var suggestions: [WeeklyReviewPayload.Pick] {
    let acted = Set(draft.liveActions.compactMap(\.findingId))
    return WeeklyReview.suggestedPicks(findings: findings.filter { !acted.contains($0.id) }, carryOver: recap.carryOver, format: format)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(review.completedAt == nil || step < 4 ? heading : "Week reviewed. Here's what changed.")
            .font(SerenityType.sectionTitle)
          Text(intro)
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 12)
        Button("Back to the recap") { persist(); onBack() }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
      }

      if compactLayout {
        stepper
        content
      } else {
        HStack(alignment: .top, spacing: 18) {
          stepper.frame(width: 220)
          content.frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }

      if step < 4 {
        HStack {
          if step > 0 {
            Button("Back") { persist(); step -= 1 }
              .buttonStyle(SerenitySecondaryButtonStyle())
              .hoverCursor(.pointingHand)
          }
          Spacer()
          Text(footNote)
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
          Button(step == 3 ? "Save the review" : "Next") {
            if step == 3 { save() } else { persist(); step += 1 }
          }
          .buttonStyle(SerenityPrimaryButtonStyle())
          .hoverCursor(.pointingHand)
          .disabled(saving)
          .keyboardShortcut(.defaultAction)
        }
      }
    }
    .onAppear {
      guard !loaded else { return }
      draft = review.payload
      loaded = true
      if review.completedAt != nil { step = 4 }
    }
  }

  private var heading: String {
    ["What happened", "What's still open", "Where your goals stand", "What matters this week", "Week reviewed"][min(step, 4)]
  }

  private var intro: String {
    switch step {
    case 0: return "Drafted from \(format.count(recap.sources.tasks, "task")), \(format.count(recap.sources.sessions, "focus session"))\(recap.usedJournal ? ", \(format.count(recap.sources.journal, "journal entry", plural: "journal entries"))" : "") and your calendar. Untick anything that doesn't belong; only ticked lines go in the journal."
    case 1: return "Decide each one so it doesn't silently roll into another week."
    case 2: return "Pace from last Monday to this one, from the same numbers as the Goals screen."
    case 3: return "Suggestions come from what stalled. You can pick none of them."
    default: return "Saved. Nothing else changes without you."
    }
  }

  private var footNote: String {
    switch step {
    case 1:
      let decided = recap.carryOver.filter { draft.carry[$0.taskId] != nil }.count
      return "\(decided) of \(recap.carryOver.count) decided"
    case 3:
      return "\(draft.picks.count) of 3 picked"
    default:
      return ""
    }
  }

  private var stepper: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(steps.enumerated()), id: \.offset) { index, label in
        Button {
          guard step < 4 else { return }
          persist()
          step = index
        } label: {
          HStack(spacing: 10) {
            ZStack {
              Circle().fill(index < step ? SerenityPalette.routineAccent : (index == step ? SerenityPalette.accent : SerenityPalette.panelBackgroundRaised))
              if index < step {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
              } else {
                Text("\(index + 1)").font(SerenityType.caption.weight(.semibold)).foregroundStyle(index == step ? .white : SerenityPalette.textSecondary)
              }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
              Text(label).font(SerenityType.bodyMedium).foregroundStyle(SerenityPalette.textPrimary)
              Text(stepNote(index)).font(SerenityType.caption).foregroundStyle(SerenityPalette.textSecondary)
            }
            Spacer(minLength: 0)
          }
          .padding(8)
          .background(RoundedRectangle(cornerRadius: 10).fill(index == step ? SerenityPalette.activeItemBackground : Color.clear))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverCursor(.pointingHand)
        .accessibilityAddTraits(index == step ? .isSelected : [])
      }
    }
  }

  private func stepNote(_ index: Int) -> String {
    switch index {
    case 0: return "Drafted from your data"
    case 1: return recap.carryOver.isEmpty ? "Nothing left over" : "\(recap.carryOver.count) left from last week"
    case 2: return format.count(recap.goals.count, "goal") + " to look at"
    default: return "Up to 3 things"
    }
  }

  @ViewBuilder
  private var content: some View {
    switch step {
    case 0: lookBack
    case 1: openItems
    case 2: goalsStep
    case 3: picksStep
    default: doneStep
    }
  }

  // Step 1

  private var lookBack: some View {
    VStack(alignment: .leading, spacing: 16) {
      lineGroup("What moved", recap.moved, empty: "Nothing finished last week.")
      lineGroup("What stalled", recap.stalled, empty: "Nothing stalled.")
      VStack(alignment: .leading, spacing: 6) {
        Text("Why did it stall? Only you know this part")
          .font(SerenityType.bodyMedium)
        TextField("Agency work crowded it out", text: $draft.why, axis: .vertical)
          .textFieldStyle(.plain)
          .serenityInputField()
      }
    }
    .reviewPanel()
  }

  private func lineGroup(_ title: String, _ lines: [WeeklyRecap.Line], empty: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(SerenityType.bodyMedium)
      if lines.isEmpty {
        Text(empty).font(SerenityType.body).foregroundStyle(SerenityPalette.textSecondary)
      }
      ForEach(lines, id: \.id) { line in
        let kept = draft.keptLines.contains(line.id)
        Button {
          if kept { draft.keptLines.removeAll { $0 == line.id } } else { draft.keptLines.append(line.id) }
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            SerenityCheckbox(isOn: kept, size: 16)
            Text(line.text)
              .font(SerenityType.body)
              .foregroundStyle(kept ? SerenityPalette.textPrimary : SerenityPalette.textSecondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
            Text(line.source)
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverCursor(.pointingHand)
        .accessibilityAddTraits(kept ? .isSelected : [])
      }
    }
  }

  // Step 2

  @ViewBuilder
  private var openItems: some View {
    if recap.carryOver.isEmpty {
      Text("Nothing was left open last week.")
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
        .reviewPanel()
    } else {
      VStack(alignment: .leading, spacing: 10) {
        Text("Each of these was due last week or touched and left open. Nothing moves until you save.")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
        ReviewCarryList(items: recap.carryOver, choices: draft.carry) { taskId, choice in
          draft.carry[taskId] = draft.carry[taskId] == choice ? nil : choice
        }
      }
      .reviewPanel()
    }
  }

  // Step 3

  private var goalsStep: some View {
    VStack(alignment: .leading, spacing: 14) {
      if recap.goals.isEmpty {
        Text("No active goals.").font(SerenityType.body).foregroundStyle(SerenityPalette.textSecondary)
      }
      ForEach(recap.goals, id: \.goalId) { change in
        let paused = draft.pausedGoalIds.contains(change.goalId)
        let pill = paused ? (text: "Paused this week", tint: SerenityPalette.textSecondary) : ReviewGoalText.pill(change)
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(change.title).font(SerenityType.bodyMedium)
            ReviewPill(text: pill.text, tint: pill.tint)
            Spacer()
            if change.kind != .area, !change.isPaused {
              Button(paused ? "Don't pause" : "Pause this week") {
                if paused { draft.pausedGoalIds.removeAll { $0 == change.goalId } } else { draft.pausedGoalIds.append(change.goalId) }
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
              .hoverCursor(.pointingHand)
            }
          }
          Text(ReviewGoalText.line(change, format: format))
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
          TextField(change.needsSetup ? "Keep it, or archive it?" : "Optional note", text: Binding(
            get: { draft.goalNotes[change.goalId] ?? "" },
            set: { draft.goalNotes[change.goalId] = $0.isEmpty ? nil : $0 }
          ))
          .textFieldStyle(.plain)
          .serenityInputField()
          .accessibilityLabel("Note on \(change.title)")
        }
      }
    }
    .reviewPanel()
  }

  // Step 4

  private var picksStep: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Pick up to three. Each says what it does when you save.")
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
      let acted = draft.liveActions
      if !acted.isEmpty {
        Text("Already done from the recap: \(acted.map(\.title).joined(separator: "; ")).")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.routineAccent)
      }
      if suggestions.isEmpty {
        Text("Nothing to suggest this week.").font(SerenityType.body).foregroundStyle(SerenityPalette.textSecondary)
      }
      ForEach(suggestions) { suggestion in
        pickRow(suggestion)
      }
      ForEach(draft.picks.filter { $0.id.hasPrefix("own:") }) { own in
        pickRow(own)
      }
      HStack {
        TextField("Or write your own", text: $ownPick)
          .textFieldStyle(.plain)
          .serenityInputField()
          .onSubmit(addOwnPick)
        Button("Add", action: addOwnPick)
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
          .disabled(ownPick.trimmingCharacters(in: .whitespaces).isEmpty || draft.picks.count >= 3)
      }
    }
    .reviewPanel()
  }

  private func pickRow(_ pick: WeeklyReviewPayload.Pick) -> some View {
    let on = draft.picks.contains { $0.id == pick.id }
    let blocked = !on && draft.picks.count >= 3
    return Button {
      if on { draft.picks.removeAll { $0.id == pick.id } } else if !blocked { draft.picks.append(pick) }
    } label: {
      HStack(alignment: .top, spacing: 10) {
        SerenityCheckbox(isOn: on, size: 16)
        VStack(alignment: .leading, spacing: 2) {
          Text(pick.context).font(SerenityType.caption).foregroundStyle(SerenityPalette.textSecondary)
          Text(pick.title).font(SerenityType.bodyMedium).foregroundStyle(SerenityPalette.textPrimary)
          Text(pick.effect).font(SerenityType.caption).foregroundStyle(SerenityPalette.textSecondary)
        }
        Spacer(minLength: 0)
      }
      .padding(10)
      .background(RoundedRectangle(cornerRadius: 10).fill(on ? SerenityPalette.activeItemBackground : SerenityPalette.innerCardBackground))
      .opacity(blocked ? 0.5 : 1)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .hoverCursor(.pointingHand)
    .disabled(blocked)
    .accessibilityAddTraits(on ? .isSelected : [])
  }

  private func addOwnPick() {
    let title = ownPick.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, draft.picks.count < 3 else { return }
    draft.picks.append(WeeklyReviewPayload.Pick(id: "own:\(UUID().uuidString)", title: title, context: "Your own", effect: "A task due today, in today's top three", findingId: nil, taskId: nil))
    ownPick = ""
  }

  // Done

  private var doneStep: some View {
    let saved = appState.weeklyReview(forWeek: review.weekKey) ?? review
    let payload = saved.payload
    let booked = payload.liveActions.filter { if case .bookFocus = $0.action { return true } else { return false } }
    let movedToday = payload.carry.values.filter { $0 == .monday }.count
    let dropped = payload.carry.values.filter { $0 == .drop }.count
    let rows: [(String, String)] = [
      ("Journal", "Weekly review entry with \(format.count(payload.keptLines.count, "line"))\(payload.why.isEmpty ? "" : " and your note on why things stalled")"),
      ("Today", payload.picks.isEmpty ? "No picks" : "\(format.count(payload.picks.count, "pick")): \(payload.picks.map(\.title).joined(separator: "; "))"),
      ("Plan", booked.isEmpty ? "Nothing booked" : booked.map(\.title).joined(separator: "; ")),
      ("Open items", "\(movedToday) moved to today, \(payload.carry.count) of \(recap.carryOver.count) decided\(dropped > 0 ? ", \(dropped) dropped" : "")"),
      ("Goals", payload.pausedGoalIds.isEmpty ? "No goals paused" : "\(format.count(payload.pausedGoalIds.count, "goal")) paused this week"),
      ("Wednesday", payload.liveActions.isEmpty ? "No check-in needed" : "A check-in on Today will say whether these changes held"),
    ]
    return VStack(alignment: .leading, spacing: 12) {
      ForEach(rows, id: \.0) { row in
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(row.0).font(SerenityType.caption.weight(.semibold)).foregroundStyle(SerenityPalette.textSecondary).frame(width: 90, alignment: .leading)
          Text(row.1).font(SerenityType.body).fixedSize(horizontal: false, vertical: true)
        }
      }
      HStack {
        Button("Go to Today") { appState.setSection(.home) }
          .buttonStyle(SerenityPrimaryButtonStyle())
          .hoverCursor(.pointingHand)
        if payload.journalEntryId != nil {
          Button("Open the journal") { appState.setSection(.journal) }
            .buttonStyle(SerenitySecondaryButtonStyle())
            .hoverCursor(.pointingHand)
        }
      }
    }
    .reviewPanel()
  }

  // Saving

  /// Keeps the draft's own answers; actions and feedback stay as the recap last saved them.
  private func persist() {
    guard review.completedAt == nil else { return }
    let answers = draft
    Task {
      await appState.updateWeeklyReview(weekKey: review.weekKey) { payload in
        payload.keptLines = answers.keptLines
        payload.why = answers.why
        payload.carry = answers.carry
        payload.goalNotes = answers.goalNotes
        payload.pausedGoalIds = answers.pausedGoalIds
        payload.picks = answers.picks
      }
    }
  }

  private func save() {
    saving = true
    let answers = draft
    Task {
      await appState.updateWeeklyReview(weekKey: review.weekKey) { payload in
        payload.keptLines = answers.keptLines
        payload.why = answers.why
        payload.carry = answers.carry
        payload.goalNotes = answers.goalNotes
        payload.pausedGoalIds = answers.pausedGoalIds
        payload.picks = answers.picks
      }
      await appState.completeWeeklyReview(weekKey: review.weekKey)
      saving = false
      step = 4
    }
  }
}

// MARK: - History

private struct WeeklyReviewHistoryDetail: View {
  let review: WeeklyReviewEntity
  let onBack: () -> Void

  var body: some View {
    let format = ReviewStyle.format
    let payload = review.payload
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Week of \(ReviewStyle.weekRange(review.weekStart))").font(SerenityType.sectionTitle)
          Text("Reviewed \(review.completedAt?.formatted(.dateTime.weekday(.wide).day().month(.wide)) ?? "")· read only")
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)
        }
        Spacer()
        Button("Back to this week", action: onBack)
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("\(format.count(payload.snapshot.tasksDone, "task")) finished · \(format.hours(payload.snapshot.focusHours)) focus\(payload.snapshot.focusTarget.map { " of \(GoalReport.format($0))" } ?? "")")
          .font(SerenityType.bodyMedium)
        ForEach(payload.snapshot.routineLines, id: \.self) { Text($0).font(SerenityType.caption).foregroundStyle(SerenityPalette.textSecondary) }
        ForEach(payload.snapshot.goals, id: \.goalId) { goal in
          Text("\(goal.title): \(goal.status)").font(SerenityType.caption).foregroundStyle(SerenityPalette.textSecondary)
        }
      }
      .reviewPanel()
      if payload.findings.isEmpty {
        Text("Nothing stood out that week.").font(SerenityType.body).foregroundStyle(SerenityPalette.textSecondary)
      }
      ForEach(payload.findings) { finding in
        WeeklyFindingCard(finding: finding, review: review, readOnly: true)
      }
      if !payload.picks.isEmpty || !payload.actions.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ReviewSectionHeader(title: "What you chose")
          ForEach(payload.picks) { pick in
            Text("• \(pick.title)").font(SerenityType.body)
          }
          ForEach(payload.actions) { action in
            Text("• \(action.title)\(action.undoneAt != nil ? " (undone)" : "")\(action.outcomeText.map { ". \($0)" } ?? "")")
              .font(SerenityType.body)
              .foregroundStyle(action.undoneAt != nil ? SerenityPalette.textSecondary : SerenityPalette.textPrimary)
          }
          if !payload.why.isEmpty {
            Text("Why it stalled: \(payload.why)").font(SerenityType.caption).foregroundStyle(SerenityPalette.textSecondary)
          }
        }
        .reviewPanel()
      }
    }
  }
}

// MARK: - On Today (5b)

/// The change picked in the review for today, with why it is here.
struct TodayReviewHighlightCard: View {
  @EnvironmentObject private var appState: AppState
  @State private var whyOpen = false

  var body: some View {
    let insight = appState.todayReviewInsight()
    if let highlight = insight.highlight {
      let running = appState.activeFocusBlock?.taskId == highlight.taskId
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          ReviewPill(text: "From your weekly review", tint: SerenityPalette.accent)
          Spacer()
        }
        Text(highlight.title)
          .font(SerenityType.bodyLarge.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
        Text(highlight.body)
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        SerenityFlowLayout(spacing: 8) {
          if !running {
            Button("Start 10 minutes") {
              let title = appState.tasks.first { $0.id == highlight.taskId }?.title ?? "Focus"
              Task { await appState.startFocus(title: title, minutes: 10, goalId: nil, taskId: highlight.taskId) }
            }
            .buttonStyle(SerenityPrimaryButtonStyle())
            .hoverCursor(.pointingHand)
          }
          Button("Mark done") {
            Task { await appState.toggleTaskCompletion(id: highlight.taskId) }
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
          Button(whyOpen ? "Hide why" : "Why this?") {
            withAnimation(.easeOut(duration: 0.15)) { whyOpen.toggle() }
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
        }
        if whyOpen {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(highlight.evidence.enumerated()), id: \.offset) { _, row in
              HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(row.when).font(SerenityType.caption.weight(.semibold)).foregroundStyle(SerenityPalette.textSecondary).frame(width: 92, alignment: .leading)
                Text(row.what).font(SerenityType.caption).fixedSize(horizontal: false, vertical: true)
              }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              Text("Shown now").font(SerenityType.caption.weight(.semibold)).foregroundStyle(SerenityPalette.textSecondary).frame(width: 92, alignment: .leading)
              Text("You chose “first on Today” in the review").font(SerenityType.caption)
            }
          }
          .padding(10)
          .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
      }
      .reviewPanel()
    }
  }
}

/// From Wednesday: how the changes made in Monday's review are going.
struct TodayReviewCheckInCard: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    let insight = appState.todayReviewInsight()
    if !insight.checkIn.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text("Mid-week check on Monday's \(insight.checkIn.count == 1 ? "change" : "\(insight.checkIn.count) changes")")
            .font(SerenityType.scaledSystem(size: 17, weight: .semibold))
          Spacer()
          Button("Last week's review") { appState.setSection(.review) }
            .buttonStyle(.plain)
            .font(SerenityType.bodyMedium)
            .foregroundStyle(SerenityPalette.accent)
            .hoverCursor(.pointingHand)
        }
        ForEach(insight.checkIn) { line in
          HStack(alignment: .top, spacing: 10) {
            ReviewPill(text: label(line.status), tint: tint(line.status))
            VStack(alignment: .leading, spacing: 2) {
              Text(line.title).font(SerenityType.bodyMedium)
              Text(line.text).font(SerenityType.caption).foregroundStyle(SerenityPalette.textSecondary)
            }
          }
          .accessibilityElement(children: .combine)
        }
        Button("Got it") {
          Task { await appState.dismissReviewCheckIn(weekKey: insight.weekKey) }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)
      }
      .reviewPanel()
    }
  }

  private func label(_ status: WeeklyAcceptedAction.Outcome?) -> String {
    switch status {
    case .held: return "Held"
    case .partly: return "Partly"
    case .missed: return "Didn't hold"
    case nil: return "So far"
    }
  }

  private func tint(_ status: WeeklyAcceptedAction.Outcome?) -> Color {
    switch status {
    case .held: return SerenityPalette.routineAccent
    case .partly, .missed: return SerenityPalette.attention
    case nil: return SerenityPalette.textSecondary
    }
  }
}

/// A line under a routine or goal on Today, from the review.
struct TodayReviewHint: View {
  @EnvironmentObject private var appState: AppState
  let text: String
  var offerFindingId: String?
  var weekKey: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(text)
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
      if let offerFindingId, let weekKey {
        Button("Remind at 8:30 after late evenings") {
          Task { await appState.acceptFinding(offerFindingId, weekKey: weekKey) }
        }
        .buttonStyle(.plain)
        .font(SerenityType.caption.weight(.semibold))
        .foregroundStyle(SerenityPalette.accent)
        .hoverCursor(.pointingHand)
      }
    }
  }
}
