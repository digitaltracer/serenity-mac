import Foundation

/// The pure parts of running a review: what each choice does to a date, what the picks are, what goes
/// in the journal, and which reminders the accepted actions ask for.
extension WeeklyReview {
  static let tag = "weekly-review"

  /// What "Monday" means for an open item: today, since the review happens on or after Monday.
  static func carryDueDate(_ choice: WeeklyReviewPayload.CarryChoice, now: Date, calendar: Calendar = WeeklyReview.calendar) -> Date? {
    let today = calendar.startOfDay(for: now)
    switch choice {
    case .monday:
      return today
    case .thisWeek:
      let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
      let friday = calendar.date(byAdding: .day, value: 4, to: week) ?? today
      return max(friday, today)
    case .someday, .drop:
      return nil
    }
  }

  /// "Monday" while it is Monday, "Today" after.
  static func carryLabel(_ choice: WeeklyReviewPayload.CarryChoice, now: Date, calendar: Calendar = WeeklyReview.calendar) -> String {
    if choice == .monday, calendar.component(.weekday, from: now) != 2 { return "Today" }
    return choice.label
  }

  /// What accepting an action does, in a few words.
  static func effect(of action: WeeklyAction, format: RecapFormat) -> String {
    switch action {
    case .bookFocus(_, _, let slots):
      return "Books \(format.slotList(slots)) in your plan"
    case .firstOnToday:
      return "Puts it first on Today"
    case .lateEveningReminder(_, let hour, let minute):
      return "After late evenings, reminds you at \(hour):\(String(format: "%02d", minute)) instead"
    case .scheduleTask(_, let day):
      return "Plans it for \(format.weekday(day))"
    case .pauseGoal:
      return "Pauses it for this week, so it doesn't count as behind"
    }
  }

  /// Up to three findings with actions, then open items, each saying what picking it does.
  static func suggestedPicks(
    findings: [WeeklyFinding],
    carryOver: [WeeklyRecap.CarryItem],
    format: RecapFormat
  ) -> [WeeklyReviewPayload.Pick] {
    var picks = findings.compactMap { finding -> WeeklyReviewPayload.Pick? in
      guard let action = finding.action else { return nil }
      return WeeklyReviewPayload.Pick(
        id: "finding:\(finding.id)",
        title: finding.actionTitle ?? finding.title,
        context: finding.linked.isEmpty ? finding.tag : finding.linked,
        effect: effect(of: action, format: format),
        findingId: finding.id,
        taskId: nil
      )
    }
    let named = Set(findings.compactMap { finding -> String? in
      if case .firstOnToday(let id)? = finding.action { return id }
      if case .scheduleTask(let id, _)? = finding.action { return id }
      return nil
    })
    for item in carryOver.prefix(4) where !named.contains(item.taskId) {
      picks.append(WeeklyReviewPayload.Pick(
        id: "task:\(item.taskId)",
        title: item.title,
        context: item.projectName ?? "Open item",
        effect: "Adds it to today's top three",
        findingId: nil,
        taskId: item.taskId
      ))
    }
    return picks
  }

  static func snapshot(of recap: WeeklyRecap) -> WeeklyReviewPayload.Snapshot {
    WeeklyReviewPayload.Snapshot(
      tasksDone: recap.tasks.done,
      focusHours: (recap.focus.hours * 10).rounded() / 10,
      focusTarget: recap.focus.target,
      routineLines: recap.routines.map { "\($0.title): \($0.done) of \($0.expected)" },
      goals: recap.goals.map { .init(goalId: $0.goalId, title: $0.title, status: $0.after.statusLabel) }
    )
  }

  static func journalTitle(weekStart: Date, format: RecapFormat) -> String {
    "Weekly review · week of \(format.range(weekStart, format.calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart))"
  }

  /// The entry the review leaves in the journal: only the lines kept, the person's own words, and what changed.
  static func journalText(
    recap: WeeklyRecap,
    payload: WeeklyReviewPayload,
    accepted: [WeeklyAcceptedAction]
  ) -> String {
    var sections: [String] = []
    let kept = Set(payload.keptLines)
    let moved = recap.moved.filter { kept.contains($0.id) }
    let stalled = recap.stalled.filter { kept.contains($0.id) }
    if !moved.isEmpty {
      sections.append((["## What moved"] + moved.map { "- \($0.text)" }).joined(separator: "\n"))
    }
    var stall = stalled.map { "- \($0.text)" }
    let why = payload.why.trimmingCharacters(in: .whitespacesAndNewlines)
    if !why.isEmpty { stall.append("\nWhy: \(why)") }
    if !stall.isEmpty {
      sections.append((["## What stalled"] + stall).joined(separator: "\n"))
    }
    let goals = recap.goals.filter { $0.kind != .area || payload.goalNotes[$0.goalId] != nil }.map { change -> String in
      var line = "- \(change.title): \(change.after.statusLabel)"
      if payload.pausedGoalIds.contains(change.goalId) { line += ", paused this week" }
      if let note = payload.goalNotes[change.goalId]?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
        line += ". \(note)"
      }
      return line
    }
    if !goals.isEmpty {
      sections.append((["## Goals"] + goals).joined(separator: "\n"))
    }
    if !payload.picks.isEmpty {
      sections.append((["## This week"] + payload.picks.map { "- \($0.title)" }).joined(separator: "\n"))
    }
    if !accepted.isEmpty {
      sections.append((["## Changes made"] + accepted.map { "- \($0.title)" }).joined(separator: "\n"))
    }
    return sections.isEmpty ? "Nothing to add this week." : sections.joined(separator: "\n\n")
  }

  static let reminderPrefix = "review:"

  /// Morning nudges for routines whose late-evening reminder was accepted and not undone.
  static func reminderOccurrences(
    reviews: [WeeklyReviewEntity],
    routines: [RoutineEntity],
    tasks: [TaskEntity],
    now: Date,
    calendar: Calendar = .current
  ) -> [NotifiableOccurrence] {
    var rules: [String: (hour: Int, minute: Int)] = [:]
    for review in reviews {
      for accepted in review.payload.liveActions {
        if case .lateEveningReminder(let routineId, let hour, let minute) = accepted.action {
          rules[routineId] = (hour, minute)
        }
      }
    }
    guard !rules.isEmpty else { return [] }

    let horizon = now.addingTimeInterval(8 * 86_400)
    let lateEvenings = tasks.filter { task in
      guard WeeklyRecap.isCalendarEvent(task), !task.completed, let start = task.dueDate else { return false }
      return start > now.addingTimeInterval(-86_400) && start < horizon && calendar.component(.hour, from: start) >= WeeklyRecap.lateEveningHour
    }
    var occurrences: [String: NotifiableOccurrence] = [:]
    for (routineId, time) in rules {
      guard let routine = routines.first(where: { $0.id == routineId && !$0.archived }) else { continue }
      for evening in lateEvenings {
        guard let morning = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: evening.dueDate!)),
              RoutineStreaks.isScheduled(routine.schedule, on: morning, calendar: calendar),
              let fire = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: morning)
        else { continue }
        let id = "\(reminderPrefix)\(routineId):\(RoutineDay.key(for: morning, calendar: calendar))"
        occurrences[id] = NotifiableOccurrence(id: id, fireDate: fire, title: routine.title, body: "A later start after \(evening.title).")
      }
    }
    return occurrences.values.sorted { $0.fireDate < $1.fireDate }
  }
}
