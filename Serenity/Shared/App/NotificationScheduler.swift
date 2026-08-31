import Foundation
import UserNotifications

/// Anything that wants to tap the user on the shoulder. Tasks are the first
/// client; habit check-ins are the intended second, which is why nothing here
/// mentions tasks.
struct NotifiableOccurrence: Equatable, Identifiable {
  let id: String
  let fireDate: Date
  let title: String
  let body: String?

  var isInFuture: Bool { fireDate > Date() }
}

/// The subset of `UNUserNotificationCenter` this needs, so reconciliation is
/// testable without the real notification service.
protocol NotificationCenterAdapter: Sendable {
  func pendingIdentifiers() async -> Set<String>
  func schedule(_ occurrence: NotifiableOccurrence) async
  func cancel(identifiers: [String]) async
}

/// Diffs the occurrences that *should* exist against those already scheduled.
/// Cancellation falls out of the diff, so callers never have to remember to
/// unschedule when something is completed, deleted, or rescheduled — they just
/// stop including it.
actor NotificationScheduler {
  private let center: NotificationCenterAdapter

  init(center: NotificationCenterAdapter) {
    self.center = center
  }

  struct Reconciliation: Equatable {
    var added: [String] = []
    var cancelled: [String] = []
    var unchanged: [String] = []
  }

  @discardableResult
  func reconcile(_ desired: [NotifiableOccurrence]) async -> Reconciliation {
    // A past fire date would either fire immediately or be dropped; either way
    // it is noise rather than a reminder.
    let upcoming = desired.filter(\.isInFuture)
    let desiredIDs = Set(upcoming.map(\.id))
    let pending = await center.pendingIdentifiers()

    var result = Reconciliation()

    let stale = pending.subtracting(desiredIDs)
    if !stale.isEmpty {
      await center.cancel(identifiers: Array(stale))
      result.cancelled = stale.sorted()
    }

    for occurrence in upcoming {
      if pending.contains(occurrence.id) {
        result.unchanged.append(occurrence.id)
      } else {
        await center.schedule(occurrence)
        result.added.append(occurrence.id)
      }
    }

    result.unchanged.sort()
    result.added.sort()
    return result
  }
}

enum TaskNotificationPlan {
  static let identifierPrefix = "task:"

  /// A date-only due date carries no meaningful time — firing at midnight would
  /// be worse than useless, so those land at `defaultHour` instead.
  static func occurrences(
    for tasks: [TaskEntity],
    leadMinutes: Int = 0,
    defaultHour: Int = 9,
    calendar: Calendar = .current
  ) -> [NotifiableOccurrence] {
    tasks.compactMap { task in
      guard !task.completed, let dueDate = task.dueDate else { return nil }

      let components = calendar.dateComponents([.hour, .minute], from: dueDate)
      let isDateOnly = (components.hour ?? 0) == 0 && (components.minute ?? 0) == 0
      let anchor = isDateOnly
        ? calendar.date(bySettingHour: defaultHour, minute: 0, second: 0, of: dueDate) ?? dueDate
        : dueDate

      let fireDate = calendar.date(byAdding: .minute, value: -leadMinutes, to: anchor) ?? anchor

      return NotifiableOccurrence(
        id: identifierPrefix + task.id,
        fireDate: fireDate,
        title: task.title,
        body: isDateOnly ? "Due today" : "Due \(dueDate.formatted(date: .omitted, time: .shortened))"
      )
    }
  }
}

/// Wraps the real notification centre. Only the identifiers this app owns are
/// touched, so a stray identifier from elsewhere is never cancelled.
struct SystemNotificationCenter: NotificationCenterAdapter {
  /// `UNUserNotificationCenter.current()` raises when the host process is not a
  /// bundled app — which is exactly what the SwiftPM test runner is. Every entry
  /// point checks this so tests and previews degrade to a no-op rather than
  /// trapping.
  private var isAvailable: Bool {
    Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
  }

  func authorizationGranted() async -> Bool {
    guard isAvailable else { return false }
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()

    switch settings.authorizationStatus {
    case .authorized, .provisional:
      return true
    case .notDetermined:
      return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    default:
      return false
    }
  }

  func pendingIdentifiers() async -> Set<String> {
    guard isAvailable else { return [] }
    let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
    return Set(
      requests
        .map(\.identifier)
        .filter { $0.hasPrefix(TaskNotificationPlan.identifierPrefix) }
    )
  }

  func schedule(_ occurrence: NotifiableOccurrence) async {
    guard isAvailable else { return }
    let content = UNMutableNotificationContent()
    content.title = occurrence.title
    if let body = occurrence.body {
      content.body = body
    }
    content.sound = .default

    let components = Calendar.current.dateComponents(
      [.year, .month, .day, .hour, .minute],
      from: occurrence.fireDate
    )
    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    let request = UNNotificationRequest(identifier: occurrence.id, content: content, trigger: trigger)

    try? await UNUserNotificationCenter.current().add(request)
  }

  func cancel(identifiers: [String]) async {
    guard isAvailable else { return }
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
  }
}
