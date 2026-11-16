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

// MARK: - Closing the loop

extension WeeklyReview {
  /// How an accepted action is going: nil status while there is nothing to judge yet.
  static func outcome(
    of accepted: WeeklyAcceptedAction,
    tasks: [TaskEntity],
    focusBlocks: [FocusBlockEntity],
    routines: [RoutineEntity],
    routineChecks: [RoutineCheckEntity],
    now: Date,
    format: RecapFormat
  ) -> (status: WeeklyAcceptedAction.Outcome?, text: String) {
    let calendar = format.calendar
    switch accepted.action {
    case .bookFocus:
      let blocks = accepted.focusBlockIds.map { id in focusBlocks.first { $0.id == id } }
      let due = blocks.filter { $0 == nil || $0!.end <= now || $0!.status == .done }
      let held = due.compactMap { $0 }.filter { $0.status == .done && $0.loggedMinutes > 0 }
      let next = blocks.compactMap { $0 }.filter { $0.status == .planned && $0.start > now }.min { $0.start < $1.start }
      let nextText = next.map { "next \(format.dayLabel($0.start)) \(format.time($0.start))" }
      guard !due.isEmpty else { return (nil, nextText.map { "Nothing due yet · \($0)" } ?? "Nothing due yet") }
      let status: WeeklyAcceptedAction.Outcome = held.count == due.count ? .held : (held.isEmpty ? .missed : .partly)
      var text = "\(held.count) of \(due.count) booked block\(due.count == 1 ? "" : "s") held"
      let hours = held.reduce(0) { $0 + $1.loggedMinutes } / 60
      if hours > 0 { text += ", \(format.hours(hours)) of focus" }
      if let nextText { text += " · \(nextText)" }
      return (status, text)

    case .firstOnToday(let taskId), .scheduleTask(let taskId, _):
      guard let task = tasks.first(where: { $0.id == taskId }) else { return (.missed, "The task was deleted") }
      if task.completed, let done = task.completedAt {
        return (.held, "Done \(format.weekday(done)) \(format.time(done))")
      }
      let day: Date
      if case .scheduleTask(_, let planned) = accepted.action { day = planned } else { day = accepted.acceptedAt }
      let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? day
      return now >= end ? (.missed, "Still open since \(format.weekday(day))") : (nil, "Planned for \(format.weekday(day))")

    case .pauseGoal:
      return (.held, "Paused for the week")

    case .lateEveningReminder(let routineId, _, _):
      guard let routine = routines.first(where: { $0.id == routineId }) else { return (nil, "Routine archived") }
      let done = Set(routineChecks.filter { $0.routineId == routineId }.map(\.day))
      let lateEvenings = tasks.filter { task in
        guard WeeklyRecap.isCalendarEvent(task), !task.completed, let start = task.dueDate else { return false }
        return start >= accepted.acceptedAt && start < now && calendar.component(.hour, from: start) >= WeeklyRecap.lateEveningHour
      }
      let mornings = lateEvenings.compactMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0.dueDate!)) }
        .filter { RoutineStreaks.isScheduled(routine.schedule, on: $0, calendar: calendar) && $0 < calendar.startOfDay(for: now) }
      let keys = Set(mornings.map { RoutineDay.key(for: $0, calendar: calendar) })
      guard !keys.isEmpty else { return (nil, "No late evenings since") }
      let kept = keys.filter(done.contains).count
      let status: WeeklyAcceptedAction.Outcome = kept == keys.count ? .held : (kept == 0 ? .missed : .partly)
      return (status, "\(routine.title) done \(kept) of \(keys.count) morning\(keys.count == 1 ? "" : "s") after a late evening")
    }
  }

  struct TodayInsight {
    struct Highlight {
      let findingId: String
      let taskId: String
      let title: String
      let body: String
      let evidence: [WeeklyEvidence]
    }

    struct CheckLine: Identifiable {
      let id: String
      let title: String
      let status: WeeklyAcceptedAction.Outcome?
      let text: String
    }

    struct RoutineHint {
      let text: String
      /// A finding to accept from the hint, when its rule isn't on yet.
      let offerFindingId: String?
    }

    var weekKey: String
    var highlight: Highlight?
    var checkIn: [CheckLine] = []
    var routineHints: [String: RoutineHint] = [:]
    var goalHints: [String: String] = [:]
  }

  /// What last week's review puts on Today: the change picked for today, the mid-week check from
  /// Wednesday, and short notes on the routines and goals it touched.
  static func todayInsight(
    reviews: [WeeklyReviewEntity],
    tasks: [TaskEntity],
    focusBlocks: [FocusBlockEntity],
    routines: [RoutineEntity],
    routineChecks: [RoutineCheckEntity],
    now: Date,
    format: RecapFormat
  ) -> TodayInsight {
    let calendar = format.calendar
    let key = weekKey(for: now, calendar: calendar)
    var insight = TodayInsight(weekKey: key)
    guard let review = reviews.first(where: { $0.weekKey == key }) else { return insight }
    let live = review.payload.liveActions

    for accepted in live {
      guard case .firstOnToday(let taskId) = accepted.action,
            calendar.isDate(accepted.acceptedAt, inSameDayAs: now),
            let task = tasks.first(where: { $0.id == taskId }), !task.completed,
            let findingId = accepted.findingId,
            let finding = review.payload.findings.first(where: { $0.id == findingId })
      else { continue }
      insight.highlight = TodayInsight.Highlight(findingId: findingId, taskId: taskId, title: "Do “\(task.title)” first", body: finding.body, evidence: finding.evidence)
      break
    }

    let weekday = calendar.component(.weekday, from: now)
    let fromWednesday = weekday >= 4 || weekday == 1
    if fromWednesday, review.payload.checkInSeenAt == nil {
      insight.checkIn = live.map { accepted in
        let result = outcome(of: accepted, tasks: tasks, focusBlocks: focusBlocks, routines: routines, routineChecks: routineChecks, now: now, format: format)
        return TodayInsight.CheckLine(id: accepted.id, title: accepted.title, status: result.status, text: result.text)
      }
    }

    let tonight = tasks.filter { task in
      guard WeeklyRecap.isCalendarEvent(task), !task.completed, let start = task.dueDate else { return false }
      return calendar.isDate(start, inSameDayAs: now) && calendar.component(.hour, from: start) >= WeeklyRecap.lateEveningHour && start > now
    }.min { $0.dueDate! < $1.dueDate! }
    var ruled = Set<String>()
    for item in reviews {
      for accepted in item.payload.liveActions {
        if case .lateEveningReminder(let routineId, let hour, let minute) = accepted.action, !ruled.contains(routineId) {
          ruled.insert(routineId)
          if let tonight {
            insight.routineHints[routineId] = TodayInsight.RoutineHint(
              text: "\(tonight.title) starts at \(format.time(tonight.dueDate!)) tonight, so tomorrow's reminder comes at \(hour):\(String(format: "%02d", minute)).",
              offerFindingId: nil
            )
          }
        }
      }
    }
    if let tonight {
      let hidden = Set(review.payload.feedback.map(\.findingId))
      for finding in review.payload.findings where finding.kind == .routineAfterLateEvening && !ruled.contains(finding.subjectId) && !hidden.contains(finding.id) {
        insight.routineHints[finding.subjectId] = TodayInsight.RoutineHint(
          text: "\(tonight.title) starts at \(format.time(tonight.dueDate!)) tonight. \(finding.title).",
          offerFindingId: finding.id
        )
      }
    }

    for accepted in live {
      guard case .bookFocus(_, let goalId?, _) = accepted.action else { continue }
      let next = accepted.focusBlockIds.compactMap { id in focusBlocks.first { $0.id == id } }
        .filter { $0.status == .planned && $0.start > now }
        .min { $0.start < $1.start }
      if let next {
        insight.goalHints[goalId] = "Next block \(format.dayLabel(next.start)) \(format.time(next.start)), booked in review"
      }
    }
    return insight
  }

  /// One line for next week's review about the changes made in this one.
  static func loopLine(for review: WeeklyReviewEntity) -> String? {
    let lines = review.payload.liveActions.map { accepted in
      accepted.outcomeText.map { "\(accepted.title): \($0.prefix(1).lowercased() + $0.dropFirst())" } ?? accepted.title
    }
    guard !lines.isEmpty else { return nil }
    return "Last week's changes. " + lines.joined(separator: ". ") + "."
  }
}
