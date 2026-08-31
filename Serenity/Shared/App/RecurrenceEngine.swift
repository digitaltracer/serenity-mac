import Foundation

/// Advances a recurring task to its next occurrence. Pure and calendar-driven so
/// it can be tested without touching storage.
///
/// This is the substrate a habit sits on: a habit is a recurring task plus a
/// streak computed from the completion history this engine leaves behind.
enum RecurrenceEngine {
  /// Returns the next due date after `date`, or nil once the pattern has run
  /// past its end date.
  static func nextOccurrence(
    after date: Date,
    pattern: TaskRecurringPattern,
    calendar: Calendar = .current
  ) -> Date? {
    let interval = max(pattern.interval, 1)

    let component: Calendar.Component
    switch pattern.type {
    case .daily:
      component = .day
    case .weekly:
      component = .weekOfYear
    case .monthly:
      component = .month
    case .custom:
      // `custom` carries no unit of its own; the interval is a day count.
      component = .day
    }

    // `Calendar` clamps overflowing days, so Jan 31 + 1 month lands on the last
    // day of February rather than spilling into March.
    guard let next = calendar.date(byAdding: component, value: interval, to: date) else {
      return nil
    }

    if let endDate = pattern.endDate, next > endDate {
      return nil
    }

    return next
  }

  /// The successor task to insert when `task` is completed, or nil when it does
  /// not recur or the series has ended. The completed instance is left alone —
  /// it is the history a streak will later be computed from.
  static func successor(
    for task: TaskEntity,
    now: Date = Date(),
    calendar: Calendar = .current,
    makeID: () -> String = { UUID().uuidString }
  ) -> TaskEntity? {
    guard let pattern = task.recurring else { return nil }

    // An undated recurring task has nothing to advance from, so anchor to the
    // completion instant.
    let anchor = task.dueDate ?? now
    guard let nextDueDate = nextOccurrence(after: anchor, pattern: pattern, calendar: calendar) else {
      return nil
    }

    var successor = task
    successor.id = makeID()
    successor.completed = false
    successor.completedAt = nil
    successor.dueDate = nextDueDate
    successor.createdAt = now
    successor.updatedAt = now
    successor.subtasks = task.subtasks.map { subtask in
      var reset = subtask
      reset.completed = false
      return reset
    }

    return successor
  }
}
