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
    standupPending: Int
  ) -> [AttentionItem] {
    var items: [AttentionItem] = []

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
