import Foundation

/// Which part of the stand-up a card belongs to. `leftOut` is a real column
/// rather than an absence, so dropping something is one drag and undoing it is
/// the same drag back.
public enum StandupColumn: String, Codable, CaseIterable, Identifiable, Sendable {
  case since
  case today
  case blocked
  case leftOut

  public var id: String { rawValue }

  /// The three that make up the stand-up, in the order they are spoken.
  public static let spoken: [StandupColumn] = [.since, .today, .blocked]

  public var title: String {
    switch self {
    case .since:
      return "Since"
    case .today:
      return "Today"
    case .blocked:
      return "Blocked on"
    case .leftOut:
      return "Leaving out"
    }
  }

  public var systemImage: String {
    switch self {
    case .since:
      return "checkmark"
    case .today:
      return "clock"
    case .blocked:
      return "exclamationmark.triangle.fill"
    case .leftOut:
      return "tray"
    }
  }
}

/// Where a card's claim came from. The board shows this so you can tell a
/// recorded fact from an inference, and the prompt carries it so the script
/// never states a guess as something you said.
public enum StandupCardSource: String, Codable, Equatable, Sendable {
  case completed
  case progress
  case comment
  case scheduled
  case carried
  case stated
  case guessed
  case calendar
  case manual

  /// Whether the card rests on an inference rather than something recorded.
  public var isGuess: Bool { self == .guessed }

  public var label: String {
    switch self {
    case .completed:
      return "Finished"
    case .progress:
      return "Moved forward"
    case .comment:
      return "Your note"
    case .scheduled:
      return "Scheduled"
    case .carried:
      return "Said before"
    case .stated:
      return "You marked it blocked"
    case .guessed:
      return "Serenity guessed this"
    case .calendar:
      return "Calendar"
    case .manual:
      return "You added this"
    }
  }
}

/// One line of the stand-up, before it has been turned into words. A task can
/// produce two cards — three subtasks closed yesterday and two left today are
/// both true — so identity is the task and the column together, never the task
/// alone.
struct StandupCard: Identifiable, Equatable, Sendable {
  var id: String
  var taskID: String?
  var column: StandupColumn
  var title: String
  var fact: String
  var source: StandupCardSource
  /// What the previous stand-up said about this task, when it mentioned it.
  /// Present so the script can say where the work got to instead of repeating
  /// itself.
  var saidLast: String?

  init(
    id: String,
    taskID: String?,
    column: StandupColumn,
    title: String,
    fact: String,
    source: StandupCardSource,
    saidLast: String? = nil
  ) {
    self.id = id
    self.taskID = taskID
    self.column = column
    self.title = title
    self.fact = fact
    self.source = source
    self.saidLast = saidLast
  }

  static func cardID(taskID: String, column: StandupColumn) -> String {
    "\(taskID):\(column.rawValue)"
  }
}

/// How the window's start was arrived at. The board says which of these applied
/// so a suspiciously thin or suspiciously fat stand-up explains itself.
enum StandupWindowAnchor: String, Equatable, Sendable {
  case lastStandup
  case previousWorkingDay
  case capped
  case sameDay
}

struct StandupWindow: Equatable, Sendable {
  var start: Date
  var end: Date
  var anchor: StandupWindowAnchor
}

/// What the previous stand-up said, reduced to what today's board needs. Keeps
/// the planner free of the storage entity.
struct StandupMention: Equatable, Sendable {
  var column: StandupColumn
  var fact: String

  init(column: StandupColumn, fact: String) {
    self.column = column
    self.fact = fact
  }
}

struct StandupRecall: Equatable, Sendable {
  var generatedAt: Date
  var mentions: [String: StandupMention]

  init(generatedAt: Date, mentions: [String: StandupMention]) {
    self.generatedAt = generatedAt
    self.mentions = mentions
  }
}

struct StandupBoard: Equatable, Sendable {
  var window: StandupWindow
  var cards: [StandupCard]

  func cards(in column: StandupColumn) -> [StandupCard] {
    cards.filter { $0.column == column }
  }

  /// Whether there is anything worth holding a stand-up screen open for. The
  /// leaving-out tray does not count.
  var hasAnythingToSay: Bool {
    cards.contains { $0.column != .leftOut }
  }

  var reportableCount: Int {
    cards.filter { $0.column != .leftOut }.count
  }
}

/// Turns tasks and their activity logs into the three columns of a stand-up.
/// Pure: no storage, no network, no model. Every judgement about what counts as
/// progress and what counts as stuck lives here, which is why it is the part
/// that is tested hardest.
enum StandupPlanner {
  /// Past this, a window stops being a stand-up and becomes a status report.
  static let windowCapDays = 14
  /// Silence this long on something open and late is the signal a blocker is
  /// hiding behind it.
  static let staleBlockerDays = 3
  /// The tag the Google Calendar sync puts on every event it turns into a task.
  static let calendarTag = "google-calendar"
  /// The tag that says a blocker outright, rather than leaving it to be guessed.
  static let blockedTag = "blocked"

  // MARK: - The window

  static func resolveWindow(
    lastStandupAt: Date?,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> StandupWindow {
    guard let lastStandupAt, lastStandupAt < now else {
      let start = previousWorkingDayStart(before: now, calendar: calendar)
      return StandupWindow(start: start, end: now, anchor: .previousWorkingDay)
    }

    let cap = calendar.date(byAdding: .day, value: -windowCapDays, to: now) ?? lastStandupAt
    if lastStandupAt < cap {
      return StandupWindow(start: cap, end: now, anchor: .capped)
    }

    let anchor: StandupWindowAnchor = calendar.isDate(lastStandupAt, inSameDayAs: now)
      ? .sameDay
      : .lastStandup
    return StandupWindow(start: lastStandupAt, end: now, anchor: anchor)
  }

  /// Monday looks back to Friday, and so does a weekend. Working days are
  /// Monday to Friday; making that configurable is not worth a setting until
  /// someone asks.
  static func previousWorkingDayStart(before date: Date, calendar: Calendar) -> Date {
    var cursor = calendar.startOfDay(for: date)

    for _ in 0..<7 {
      guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
      cursor = previous
      let weekday = calendar.component(.weekday, from: cursor)
      let isWeekend = weekday == 1 || weekday == 7
      if !isWeekend {
        return cursor
      }
    }

    return cursor
  }

  // MARK: - The board

  static func build(
    tasks: [TaskEntity],
    recall: StandupRecall? = nil,
    lastStandupAt: Date? = nil,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> StandupBoard {
    let window = resolveWindow(
      lastStandupAt: lastStandupAt ?? recall?.generatedAt,
      now: now,
      calendar: calendar
    )
    return build(tasks: tasks, window: window, recall: recall, now: now, calendar: calendar)
  }

  static func build(
    tasks: [TaskEntity],
    window: StandupWindow,
    recall: StandupRecall?,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> StandupBoard {
    var since: [(card: StandupCard, sort: Date)] = []
    var today: [(card: StandupCard, rank: Int, sort: Date)] = []
    var blocked: [(card: StandupCard, rank: Int)] = []
    var leftOut: [StandupCard] = []

    for task in tasks {
      let mention = task.id.isEmpty ? nil : recall?.mentions[task.id]
      let isCalendarEvent = task.tags.contains(calendarTag)

      if let card = sinceCard(for: task, window: window, mention: mention, calendar: calendar) {
        if isCalendarEvent {
          leftOut.append(divert(card))
        } else {
          since.append((card, lastTouch(of: task, window: window) ?? task.updatedAt))
        }
      }

      // A blocked task is not also today's plan: saying both muddies the ask.
      if let entry = blockedCard(for: task, window: window, mention: mention, now: now, calendar: calendar) {
        if isCalendarEvent {
          leftOut.append(divert(entry.card))
        } else {
          blocked.append(entry)
        }
        continue
      }

      if let entry = todayCard(for: task, window: window, mention: mention, now: now, calendar: calendar) {
        if isCalendarEvent {
          leftOut.append(divert(entry.card))
        } else {
          today.append((entry.card, entry.rank, task.dueDate ?? task.updatedAt))
        }
      }
    }

    let orderedSince = since
      .sorted { $0.sort > $1.sort }
      .map(\.card)
    let orderedToday = today
      .sorted { $0.rank == $1.rank ? $0.sort < $1.sort : $0.rank < $1.rank }
      .map(\.card)
    let orderedBlocked = blocked
      .sorted { $0.rank < $1.rank }
      .map(\.card)

    return StandupBoard(
      window: window,
      cards: orderedSince + orderedToday + orderedBlocked + leftOut
    )
  }

  private static func divert(_ card: StandupCard) -> StandupCard {
    var moved = card
    moved.column = .leftOut
    moved.source = .calendar
    moved.id = card.taskID.map { StandupCard.cardID(taskID: $0, column: .leftOut) } ?? card.id
    return moved
  }

  // MARK: - Since

  private static func sinceCard(
    for task: TaskEntity,
    window: StandupWindow,
    mention: StandupMention?,
    calendar: Calendar
  ) -> StandupCard? {
    let card = { (fact: String, source: StandupCardSource) in
      StandupCard(
        id: StandupCard.cardID(taskID: task.id, column: .since),
        taskID: task.id,
        column: .since,
        title: task.title,
        fact: fact,
        source: source,
        saidLast: mention?.fact
      )
    }

    if task.completed, let completedAt = task.completedAt, inWindow(completedAt, window) {
      return card("Finished \(StandupDateText.dayAndTime(completedAt, calendar: calendar))", .completed)
    }

    guard !task.completed else { return nil }

    let recent = task.activity.filter { inWindow($0.createdAt, window) }

    if let comment = recent.last(where: { $0.kind == .comment }) {
      let quoted = StandupDateText.shorten(comment.text)
      return card(
        "You wrote: \u{201C}\(quoted)\u{201D} \u{00B7} \(StandupDateText.dayAndTime(comment.createdAt, calendar: calendar))",
        .comment
      )
    }

    let events = recent.filter { $0.kind == .event }
    guard let latestEvent = events.last else {
      if inWindow(task.createdAt, window) {
        return card("Picked up \(StandupDateText.day(task.createdAt, calendar: calendar))", .progress)
      }
      return nil
    }

    let closedSubtasks = events.filter { $0.text.hasPrefix("Subtask done") }.count
    if closedSubtasks > 0, !task.subtasks.isEmpty {
      let noun = closedSubtasks == 1 ? "subtask" : "subtasks"
      return card(
        "\(closedSubtasks) of \(task.subtasks.count) \(noun) done \(StandupDateText.day(latestEvent.createdAt, calendar: calendar))",
        .progress
      )
    }

    return card(
      "\(latestEvent.text) \u{00B7} \(StandupDateText.day(latestEvent.createdAt, calendar: calendar))",
      .progress
    )
  }

  // MARK: - Today

  private static func todayCard(
    for task: TaskEntity,
    window: StandupWindow,
    mention: StandupMention?,
    now: Date,
    calendar: Calendar
  ) -> (card: StandupCard, rank: Int)? {
    guard !task.completed else { return nil }

    let wasSaid = mention != nil
    let touched = task.activity.contains { inWindow($0.createdAt, window) }
    let overdueDays = overdueDayCount(for: task, now: now, calendar: calendar)
    let dueToday = task.dueDate.map { calendar.isDate($0, inSameDayAs: now) } ?? false

    guard overdueDays > 0 || dueToday || wasSaid || touched else { return nil }

    // The deadline and how much is left are both worth hearing, so they are
    // joined rather than ranked against each other.
    let schedule: String?
    let rank: Int
    if overdueDays > 0 {
      schedule = "Overdue by \(overdueDays) \(overdueDays == 1 ? "day" : "days")"
      rank = 0
    } else if dueToday {
      schedule = "Due today"
      rank = 1
    } else if let dueDate = task.dueDate {
      schedule = "Due \(StandupDateText.day(dueDate, calendar: calendar))"
      rank = 2
    } else {
      schedule = nil
      rank = 3
    }

    let fact = [schedule, remainingSubtasks(of: task)]
      .compactMap { $0 }
      .joined(separator: " \u{00B7} ")
      .nilIfEmpty ?? "In flight"

    let source: StandupCardSource
    if wasSaid {
      source = .carried
    } else if touched {
      source = .progress
    } else {
      source = .scheduled
    }

    let card = StandupCard(
      id: StandupCard.cardID(taskID: task.id, column: .today),
      taskID: task.id,
      column: .today,
      title: task.title,
      fact: fact,
      source: source,
      saidLast: mention?.fact
    )
    return (card, rank)
  }

  private static func remainingSubtasks(of task: TaskEntity) -> String? {
    let open = task.subtasks.filter { !$0.completed }.count
    guard open > 0 else { return nil }
    return "\(open) \(open == 1 ? "subtask" : "subtasks") left"
  }

  // MARK: - Blocked

  private static func blockedCard(
    for task: TaskEntity,
    window: StandupWindow,
    mention: StandupMention?,
    now: Date,
    calendar: Calendar
  ) -> (card: StandupCard, rank: Int)? {
    guard !task.completed else { return nil }

    let card = { (fact: String, source: StandupCardSource) in
      StandupCard(
        id: StandupCard.cardID(taskID: task.id, column: .blocked),
        taskID: task.id,
        column: .blocked,
        title: task.title,
        fact: fact,
        source: source,
        saidLast: mention?.fact
      )
    }

    if task.tags.contains(blockedTag) {
      return (card("You marked this blocked", .stated), 0)
    }

    let silentDays = daysSinceLastTouch(of: task, now: now, calendar: calendar)

    if mention?.column == .blocked {
      let noun = silentDays == 1 ? "day" : "days"
      return (card("Still stuck \u{00B7} \(silentDays) \(noun) without movement", .carried), 1)
    }

    // Something you never touched is backlog, not a blocker. A stall is only
    // worth raising when there is evidence you picked the work up and it then
    // went quiet, so an empty activity log disqualifies the guess outright.
    guard !task.activity.isEmpty else { return nil }

    let overdueDays = overdueDayCount(for: task, now: now, calendar: calendar)
    guard overdueDays > 0, silentDays >= staleBlockerDays else { return nil }

    let noun = silentDays == 1 ? "day" : "days"
    return (card("Nothing has moved in \(silentDays) \(noun), and it is overdue", .guessed), 2)
  }

  // MARK: - Shared arithmetic

  private static func inWindow(_ date: Date, _ window: StandupWindow) -> Bool {
    date >= window.start && date <= window.end
  }

  private static func lastTouch(of task: TaskEntity, window: StandupWindow) -> Date? {
    task.activity.filter { inWindow($0.createdAt, window) }.map(\.createdAt).max()
  }

  private static func overdueDayCount(for task: TaskEntity, now: Date, calendar: Calendar) -> Int {
    guard let dueDate = task.dueDate else { return 0 }
    let due = calendar.startOfDay(for: dueDate)
    let today = calendar.startOfDay(for: now)
    let days = calendar.dateComponents([.day], from: due, to: today).day ?? 0
    return max(days, 0)
  }

  /// Counts from the most recent thing that happened to the task, falling back
  /// to when it was last saved. A task with no activity log at all is judged by
  /// its update stamp rather than treated as fresh.
  private static func daysSinceLastTouch(of task: TaskEntity, now: Date, calendar: Calendar) -> Int {
    let latest = max(task.activity.map(\.createdAt).max() ?? task.updatedAt, task.updatedAt)
    let from = calendar.startOfDay(for: latest)
    let to = calendar.startOfDay(for: now)
    return max(calendar.dateComponents([.day], from: from, to: to).day ?? 0, 0)
  }
}

/// Date wording for the board. Near dates get their weekday because that is how
/// a stand-up is spoken; anything older gets a real date, so a line stored today
/// still reads correctly when the window is two weeks wide.
enum StandupDateText {
  static let weekdayHorizon = 6
  static let commentLimit = 60

  static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    if calendar.isDate(date, inSameDayAs: now) { return "today" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
       calendar.isDate(date, inSameDayAs: yesterday) {
      return "yesterday"
    }

    let days = calendar.dateComponents(
      [.day],
      from: calendar.startOfDay(for: date),
      to: calendar.startOfDay(for: now)
    ).day ?? 0

    if abs(days) <= weekdayHorizon {
      return date.formatted(.dateTime.weekday(.wide))
    }

    return date.formatted(.dateTime.day().month(.abbreviated))
  }

  static func dayAndTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    "\(day(date, now: now, calendar: calendar)) \(date.formatted(date: .omitted, time: .shortened))"
  }

  /// What a column header calls the start of the window.
  static func windowLabel(_ window: StandupWindow, now: Date = Date(), calendar: Calendar = .current) -> String {
    switch window.anchor {
    case .sameDay:
      return "Since this morning"
    case .capped:
      return "Last \(StandupPlanner.windowCapDays) days"
    case .lastStandup, .previousWorkingDay:
      return "Since \(day(window.start, now: now, calendar: calendar))"
    }
  }

  static func shorten(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n", with: " ")
    guard trimmed.count > commentLimit else { return trimmed }
    return trimmed.prefix(commentLimit).trimmingCharacters(in: .whitespaces) + "\u{2026}"
  }
}
