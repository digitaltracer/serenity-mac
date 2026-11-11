import Foundation

/// Something on Today that needs a decision, with the reason it is there rather than a count of
/// how late it is.
struct AttentionItem: Identifiable, Equatable {
  enum Destination: Equatable {
    case inbox
    case overdue
    case goal(String)
    case routines
    case slackProposals
    case standup
    case shutdown
    case weeklyReview
  }

  let id: String
  let title: String
  let reason: String
  let actionTitle: String
  let destination: Destination
  /// Amber when a goal or habit is at stake; plain when it is housekeeping.
  let isUrgent: Bool
}

struct PlanItem: Identifiable, Equatable {
  enum Kind: Equatable {
    case calendar
    case task
    case focus
  }

  let id: String
  let title: String
  let start: Date
  let end: Date
  let kind: Kind
  let isDone: Bool
  var column = 0
  var columns = 1
}

enum TodayBriefing {
  /// Timed tasks have no length of their own; this is how tall they draw on the plan.
  static let defaultTaskMinutes: Double = 30
  static let calendarTag = "google-calendar"

  static func greeting(now: Date = Date(), calendar: Calendar = .current) -> String {
    switch calendar.component(.hour, from: now) {
    case 5..<12:
      return "Good morning"
    case 12..<17:
      return "Good afternoon"
    default:
      return "Good evening"
    }
  }

  static func isSlipping(_ summary: RoutineSummary) -> Bool {
    guard summary.unit == .days else { return false }
    let past = summary.lastSevenDays.dropLast().filter { $0 == .done || $0 == .missed || $0 == .skipped }
    return past.suffix(3).filter { $0 == .missed }.count >= 2
  }

  static func attentionItems(
    inboxCount: Int,
    overdueCount: Int,
    goalReports: [GoalReport],
    routineSummaries: [RoutineSummary],
    pendingProposals: Int,
    standupPending: Int,
    shutdownDue: Bool = false,
    weeklyReviewDue: Bool = false
  ) -> [AttentionItem] {
    var items: [AttentionItem] = []

    if shutdownDue {
      items.append(AttentionItem(
        id: "shutdown",
        title: "Close out the day",
        reason: "Settle today's open tasks, pick tomorrow's top three, one line for the journal.",
        actionTitle: "Start shutdown",
        destination: .shutdown,
        isUrgent: false
      ))
    }

    if weeklyReviewDue {
      items.append(AttentionItem(
        id: "weekly-review",
        title: "Time for the weekly review",
        reason: "Ten minutes on what moved, what stalled, and three things for next week.",
        actionTitle: "Review the week",
        destination: .weeklyReview,
        isUrgent: false
      ))
    }

    if inboxCount > 0 {
      items.append(AttentionItem(
        id: "inbox",
        title: inboxCount == 1 ? "1 capture to sort" : "\(inboxCount) captures to sort",
        reason: "Undated tasks wait in the inbox until they get a date or a project.",
        actionTitle: "Sort now",
        destination: .inbox,
        isUrgent: false
      ))
    }

    for report in goalReports where report.needsAttention {
      let reason: String
      if report.kind == .area {
        reason = "Nothing has touched it since \(report.lastActivity?.formatted(.dateTime.day().month(.wide)) ?? "it was added")."
      } else if let projected = report.projected {
        reason = "\(report.progressLabel). At this rate it lands on about \(GoalReport.format(projected.rounded()))."
      } else {
        reason = report.progressLabel
      }
      items.append(AttentionItem(
        id: "goal-\(report.id)",
        title: report.kind == .area ? "\(report.goal.title) has been quiet for \(report.daysQuiet ?? 0) days" : "\(report.goal.title) is \(report.statusLabel)",
        reason: reason,
        actionTitle: "Open goal",
        destination: .goal(report.id),
        isUrgent: true
      ))
    }

    for summary in routineSummaries where isSlipping(summary) && summary.today != .done {
      items.append(AttentionItem(
        id: "routine-\(summary.id)",
        title: "\(summary.routine.title) is slipping",
        reason: "Missed on two of the last three days it was due.",
        actionTitle: "See routines",
        destination: .routines,
        isUrgent: true
      ))
    }

    if overdueCount > 0 {
      items.append(AttentionItem(
        id: "overdue",
        title: overdueCount == 1 ? "1 task is past its date" : "\(overdueCount) tasks are past their date",
        reason: "Give each a new date, or let it go.",
        actionTitle: "Review",
        destination: .overdue,
        isUrgent: false
      ))
    }

    if pendingProposals > 0 {
      items.append(AttentionItem(
        id: "slack",
        title: pendingProposals == 1 ? "1 Slack suggestion to review" : "\(pendingProposals) Slack suggestions to review",
        reason: "Nothing reaches your tasks until you accept it.",
        actionTitle: "Review",
        destination: .slackProposals,
        isUrgent: false
      ))
    }

    if standupPending > 0 {
      items.append(AttentionItem(
        id: "standup",
        title: "Ready for stand-up?",
        reason: "\(standupPending) thing\(standupPending == 1 ? "" : "s") to go through.",
        actionTitle: "Build it",
        destination: .standup,
        isUrgent: false
      ))
    }

    return items
  }

  /// One sentence about the shape of the day, built from what is actually on it.
  static func sentence(
    meetings: Int,
    focusMinutes: Double,
    behindGoal: GoalReport?,
    inboxCount: Int
  ) -> String {
    var parts: [String] = []

    let meetingText: String? = meetings == 0 ? nil : (meetings == 1 ? "One meeting" : "\(meetings) meetings")
    let focusText: String? = focusMinutes <= 0 ? nil : "\(durationText(minutes: focusMinutes)) of focus planned"
    switch (meetingText, focusText) {
    case let (meeting?, focus?):
      parts.append("\(meeting) and \(focus).")
    case let (meeting?, nil):
      parts.append("\(meeting) today and no focus time planned yet.")
    case let (nil, focus?):
      parts.append("No meetings, \(focus).")
    case (nil, nil):
      parts.append("A clear calendar.")
    }

    if let behindGoal {
      parts.append("\(behindGoal.goal.title) is \(behindGoal.statusLabel).")
    }
    if inboxCount > 0 {
      parts.append(inboxCount == 1 ? "One capture is waiting in the inbox." : "\(inboxCount) captures are waiting in the inbox.")
    }
    return parts.joined(separator: " ")
  }

  static func durationText(minutes: Double) -> String {
    let rounded = Int(minutes.rounded())
    if rounded < 60 { return "\(rounded) min" }
    let hours = Double(rounded) / 60
    return hours.rounded() == hours ? "\(Int(hours)) h" : String(format: "%.1f h", hours)
  }

  /// Today's timed tasks, calendar events and focus blocks, with overlapping items given side-by-side
  /// columns. Tasks dated today without a time are returned apart.
  static func planItems(
    tasks: [TaskEntity],
    focusBlocks: [FocusBlockEntity],
    day: Date,
    calendar: Calendar = .current
  ) -> (timed: [PlanItem], untimed: [TaskEntity]) {
    var timed: [PlanItem] = []
    var untimed: [TaskEntity] = []

    for task in tasks {
      guard let due = task.dueDate, calendar.isDate(due, inSameDayAs: day) else { continue }
      let parts = calendar.dateComponents([.hour, .minute], from: due)
      guard parts.hour != 0 || parts.minute != 0 else {
        untimed.append(task)
        continue
      }
      timed.append(PlanItem(
        id: "task-\(task.id)",
        title: task.title,
        start: due,
        end: due.addingTimeInterval(defaultTaskMinutes * 60),
        kind: task.tags.contains(calendarTag) ? .calendar : .task,
        isDone: task.completed
      ))
    }

    for block in focusBlocks where calendar.isDate(block.start, inSameDayAs: day) {
      timed.append(PlanItem(
        id: "focus-\(block.id)",
        title: block.title,
        start: block.start,
        end: max(block.end, block.start.addingTimeInterval(15 * 60)),
        kind: .focus,
        isDone: block.status == .done
      ))
    }

    return (assignColumns(timed.sorted { ($0.start, $0.end) < ($1.start, $1.end) }), untimed)
  }

  private static func assignColumns(_ items: [PlanItem]) -> [PlanItem] {
    var result: [PlanItem] = []
    var cluster: [PlanItem] = []
    var clusterEnd = Date.distantPast

    func flush() {
      var columnEnds: [Date] = []
      var placed: [PlanItem] = []
      for var item in cluster {
        if let free = columnEnds.firstIndex(where: { $0 <= item.start }) {
          item.column = free
          columnEnds[free] = item.end
        } else {
          item.column = columnEnds.count
          columnEnds.append(item.end)
        }
        placed.append(item)
      }
      result += placed.map { item in
        var item = item
        item.columns = max(columnEnds.count, 1)
        return item
      }
      cluster = []
    }

    for item in items {
      if item.start >= clusterEnd, !cluster.isEmpty {
        flush()
      }
      cluster.append(item)
      clusterEnd = max(clusterEnd, item.end)
    }
    flush()
    return result
  }
}

// MARK: - Shutdown and weekly review

extension TodayBriefing {
  /// From 5 PM until the routine day rolls over at 3 AM, unless today's shutdown is done.
  static func shutdownDue(now: Date = Date(), lastShutdownDay: String?, calendar: Calendar = .current) -> Bool {
    let hour = calendar.component(.hour, from: now)
    guard hour >= 17 || hour < RoutineDay.rolloverHour else { return false }
    return lastShutdownDay != RoutineDay.key(for: RoutineDay.current(now: now, calendar: calendar), calendar: calendar)
  }
}

enum WeeklyReview {
  struct Summary {
    struct RoutineLine: Equatable {
      let title: String
      let done: Int
    }

    let weekStart: Date
    let weekEnd: Date
    let completedTasks: [TaskEntity]
    let focusHours: Double
    let routines: [RoutineLine]
    let goals: [GoalReport]
  }

  struct Answers: Equatable {
    var moved = ""
    var stalled = ""
    var goalNotes: [String: String] = [:]
    var nextWeek = ["", "", ""]
  }

  /// Weeks start on Monday here whatever the locale, so "this week" means the same on every device.
  static var calendar: Calendar {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = .current
    return calendar
  }

  /// On a Monday the review looks back at the week just finished; otherwise at the current one.
  static func reviewedWeekStart(for now: Date, calendar: Calendar = WeeklyReview.calendar) -> Date {
    let anchor = calendar.component(.weekday, from: now) == 2 ? (calendar.date(byAdding: .day, value: -1, to: now) ?? now) : now
    return calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? calendar.startOfDay(for: anchor)
  }

  static func weekKey(for now: Date, calendar: Calendar = WeeklyReview.calendar) -> String {
    let start = reviewedWeekStart(for: now, calendar: calendar)
    let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: start)
    return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
  }

  /// Due from Friday afternoon through Monday, once per week.
  static func isDue(now: Date = Date(), lastReviewedWeek: String?, calendar: Calendar = WeeklyReview.calendar) -> Bool {
    let weekday = calendar.component(.weekday, from: now)
    let hour = calendar.component(.hour, from: now)
    let inWindow = (weekday == 6 && hour >= 15) || weekday == 7 || weekday == 1 || weekday == 2
    return inWindow && lastReviewedWeek != weekKey(for: now, calendar: calendar)
  }

  /// The Monday next week's picks are due: today when reviewing on a Monday.
  static func nextMonday(after now: Date, calendar: Calendar = WeeklyReview.calendar) -> Date {
    let today = calendar.startOfDay(for: now)
    if calendar.component(.weekday, from: today) == 2 { return today }
    return calendar.nextDate(after: today, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? today
  }

  static func summary(
    tasks: [TaskEntity],
    focusBlocks: [FocusBlockEntity],
    routineSummaries: [RoutineSummary],
    routineChecks: [RoutineCheckEntity],
    goalReports: [GoalReport],
    now: Date,
    calendar: Calendar = WeeklyReview.calendar
  ) -> Summary {
    let start = reviewedWeekStart(for: now, calendar: calendar)
    let end = calendar.date(byAdding: .day, value: 7, to: start) ?? now
    let window = DateInterval(start: start, end: max(min(end, now), start))
    let inWeek: (Date) -> Bool = { $0 >= window.start && $0 < end && $0 <= now }

    let completed = tasks
      .filter { $0.completed && ($0.completedAt.map(inWeek) ?? false) }
      .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    let focus = focusBlocks
      .filter { $0.status == .done && inWeek($0.finishedAt ?? $0.end) }
      .reduce(0) { $0 + $1.loggedMinutes } / 60
    let routines = routineSummaries.map { summary in
      Summary.RoutineLine(
        title: summary.routine.title,
        done: routineChecks.filter { check in
          check.routineId == summary.routine.id && check.status == .done
            && (GoalReports.date(fromDayKey: check.day).map(inWeek) ?? false)
        }.count
      )
    }

    return Summary(
      weekStart: start,
      weekEnd: end,
      completedTasks: completed,
      focusHours: focus,
      routines: routines,
      goals: goalReports.filter { $0.kind != .area }
    )
  }

  static func journalText(summary: Summary, answers: Answers) -> String {
    var lines: [String] = []
    lines.append("## Wins")
    lines.append("- \(summary.completedTasks.count) tasks finished")
    if summary.focusHours > 0 {
      lines.append("- \(GoalReport.format((summary.focusHours * 10).rounded() / 10)) h of focus")
    }
    for routine in summary.routines where routine.done > 0 {
      lines.append("- \(routine.title): \(routine.done) day\(routine.done == 1 ? "" : "s")")
    }
    for task in summary.completedTasks.prefix(8) {
      lines.append("- Done: \(task.title)")
    }

    if !answers.moved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append("")
      lines.append("## What moved")
      lines.append(answers.moved.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if !answers.stalled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append("")
      lines.append("## What stalled, and why")
      lines.append(answers.stalled.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    if !summary.goals.isEmpty {
      lines.append("")
      lines.append("## Goals")
      for report in summary.goals {
        var line = "- \(report.goal.title): \(report.statusLabel) (\(report.progressLabel))"
        if let note = answers.goalNotes[report.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
          line += ". \(note)"
        }
        lines.append(line)
      }
    }

    let next = answers.nextWeek.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    if !next.isEmpty {
      lines.append("")
      lines.append("## Next week")
      lines.append(contentsOf: next.map { "- \($0)" })
    }
    return lines.joined(separator: "\n")
  }
}
