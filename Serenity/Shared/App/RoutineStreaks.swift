import Foundation

/// A routine day runs from 3 AM to 3 AM, so ticking something off just after midnight still counts
/// for the evening you were in.
enum RoutineDay {
  static let rolloverHour = 3

  static func current(now: Date = Date(), calendar: Calendar = .current) -> Date {
    let shifted = calendar.date(byAdding: .hour, value: -rolloverHour, to: now) ?? now
    return calendar.startOfDay(for: shifted)
  }

  static func key(for day: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: day)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }
}

enum RoutineDayMark: Equatable {
  case done
  case skipped
  case missed
  /// Today, not yet marked.
  case open
  /// Not a scheduled day, before the routine existed, or a free day in an N-times-a-week routine.
  case off
}

enum RoutineStreakUnit: Equatable {
  case days
  case weeks
}

struct RoutineSummary: Identifiable, Equatable {
  let routine: RoutineEntity
  let today: RoutineCheckStatus?
  let isScheduledToday: Bool
  /// Oldest first; the last entry is today.
  let lastSevenDays: [RoutineDayMark]
  let streak: Int
  let unit: RoutineStreakUnit
  /// Set for N-times-a-week routines: marks done in the current week, against the target.
  let weekProgress: (done: Int, target: Int)?
  /// True when the streak is zero because a scheduled day or week was missed, not because it is new.
  let wasReset: Bool

  var id: String { routine.id }

  var streakLabel: String {
    if streak > 0 {
      switch unit {
      case .days:
        return streak == 1 ? "1 day" : "\(streak) days"
      case .weeks:
        return streak == 1 ? "1 wk" : "\(streak) wks"
      }
    }
    return wasReset ? "reset" : "new"
  }

  static func == (lhs: RoutineSummary, rhs: RoutineSummary) -> Bool {
    lhs.routine == rhs.routine
      && lhs.today == rhs.today
      && lhs.isScheduledToday == rhs.isScheduledToday
      && lhs.lastSevenDays == rhs.lastSevenDays
      && lhs.streak == rhs.streak
      && lhs.unit == rhs.unit
      && lhs.weekProgress?.done == rhs.weekProgress?.done
      && lhs.weekProgress?.target == rhs.weekProgress?.target
      && lhs.wasReset == rhs.wasReset
  }
}

enum RoutineStreaks {
  /// Stops a streak walk on very old routines; a decade of daily ticks is far past anything shown.
  private static let maximumLookback = 3_660

  static func summary(
    for routine: RoutineEntity,
    checks: [String: RoutineCheckStatus],
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> RoutineSummary {
    let today = RoutineDay.current(now: now, calendar: calendar)
    let firstDay = calendar.startOfDay(for: routine.createdAt) > today ? today : calendar.startOfDay(for: routine.createdAt)
    let status: (Date) -> RoutineCheckStatus? = { checks[RoutineDay.key(for: $0, calendar: calendar)] }

    let lastSevenDays: [RoutineDayMark] = (0..<7).reversed().map { offset in
      let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
      return mark(for: day, today: today, firstDay: firstDay, routine: routine, status: status(day), calendar: calendar)
    }

    switch routine.schedule {
    case .timesPerWeek(let target):
      let weekly = weeklyStreak(target: max(target, 1), today: today, firstDay: firstDay, status: status, calendar: calendar)
      return RoutineSummary(
        routine: routine,
        today: status(today),
        isScheduledToday: true,
        lastSevenDays: lastSevenDays,
        streak: weekly.streak,
        unit: .weeks,
        weekProgress: (weekly.doneThisWeek, max(target, 1)),
        wasReset: weekly.wasReset
      )
    case .daily, .weekdays:
      let daily = dailyStreak(routine: routine, today: today, firstDay: firstDay, status: status, calendar: calendar)
      return RoutineSummary(
        routine: routine,
        today: status(today),
        isScheduledToday: isScheduled(routine.schedule, on: today, calendar: calendar),
        lastSevenDays: lastSevenDays,
        streak: daily.streak,
        unit: .days,
        weekProgress: nil,
        wasReset: daily.wasReset
      )
    }
  }

  static func isScheduled(_ schedule: RoutineSchedule, on day: Date, calendar: Calendar = .current) -> Bool {
    switch schedule {
    case .daily, .timesPerWeek:
      return true
    case .weekdays(let weekdays):
      return weekdays.contains(calendar.component(.weekday, from: day))
    }
  }

  private static func mark(
    for day: Date,
    today: Date,
    firstDay: Date,
    routine: RoutineEntity,
    status: RoutineCheckStatus?,
    calendar: Calendar
  ) -> RoutineDayMark {
    switch status {
    case .done:
      return .done
    case .skipped:
      return .skipped
    case nil:
      break
    }
    if day == today {
      return isScheduled(routine.schedule, on: day, calendar: calendar) ? .open : .off
    }
    if day < firstDay || !isScheduled(routine.schedule, on: day, calendar: calendar) {
      return .off
    }
    if case .timesPerWeek = routine.schedule {
      return .off
    }
    return .missed
  }

  /// Done days in a row on scheduled days. Today stays open until marked, and a skip neither
  /// counts nor breaks the run.
  private static func dailyStreak(
    routine: RoutineEntity,
    today: Date,
    firstDay: Date,
    status: (Date) -> RoutineCheckStatus?,
    calendar: Calendar
  ) -> (streak: Int, wasReset: Bool) {
    var streak = status(today) == .done ? 1 : 0
    var day = today

    for _ in 0..<maximumLookback {
      guard let previous = calendar.date(byAdding: .day, value: -1, to: day), previous >= firstDay else { break }
      day = previous
      guard isScheduled(routine.schedule, on: day, calendar: calendar) else { continue }

      switch status(day) {
      case .done:
        streak += 1
      case .skipped:
        continue
      case nil:
        return (streak, streak == 0)
      }
    }
    return (streak, false)
  }

  /// Weeks in a row that hit the target. The current week stays open until it does.
  private static func weeklyStreak(
    target: Int,
    today: Date,
    firstDay: Date,
    status: (Date) -> RoutineCheckStatus?,
    calendar: Calendar
  ) -> (streak: Int, doneThisWeek: Int, wasReset: Bool) {
    func doneCount(inWeekOf day: Date) -> Int {
      guard let week = calendar.dateInterval(of: .weekOfYear, for: day) else { return 0 }
      var count = 0
      var cursor = week.start
      while cursor < week.end {
        if status(cursor) == .done { count += 1 }
        guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
        cursor = next
      }
      return count
    }

    let doneThisWeek = doneCount(inWeekOf: today)
    var streak = doneThisWeek >= target ? 1 : 0
    guard let firstWeekStart = calendar.dateInterval(of: .weekOfYear, for: firstDay)?.start,
          var weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start
    else {
      return (streak, doneThisWeek, false)
    }

    for _ in 0..<(maximumLookback / 7) {
      guard let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart), previous >= firstWeekStart else { break }
      weekStart = previous
      if doneCount(inWeekOf: weekStart) >= target {
        streak += 1
      } else if weekStart == firstWeekStart {
        // The week the routine was added in may have started before it existed.
        break
      } else {
        return (streak, doneThisWeek, streak == 0)
      }
    }
    return (streak, doneThisWeek, false)
  }
}
