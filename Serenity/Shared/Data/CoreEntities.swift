import Foundation

public enum TaskPriority: String, Codable, CaseIterable, Sendable {
  case low
  case medium
  case high
}

public struct TaskSubtask: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public var completed: Bool
  public var order: Int

  public init(id: String, title: String, completed: Bool, order: Int) {
    self.id = id
    self.title = title
    self.completed = completed
    self.order = order
  }
}

public enum TaskActivityKind: String, Codable, Sendable {
  case comment
  case event
}

/// One line of a task's history — something you wrote, or something that
/// happened to the task. Event text is stored already rendered and in absolute
/// terms, so a stored line never drifts the way "tomorrow" would.
public struct TaskActivityEntry: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var kind: TaskActivityKind
  public var text: String
  public var createdAt: Date
  public var editedAt: Date?

  public init(
    id: String,
    kind: TaskActivityKind,
    text: String,
    createdAt: Date,
    editedAt: Date? = nil
  ) {
    self.id = id
    self.kind = kind
    self.text = text
    self.createdAt = createdAt
    self.editedAt = editedAt
  }
}

public enum RecurringType: String, Codable, Sendable {
  case daily
  case weekly
  case monthly
  case custom
}

public struct TaskRecurringPattern: Codable, Equatable, Sendable {
  public var type: RecurringType
  public var interval: Int
  public var endDate: Date?

  public init(type: RecurringType, interval: Int, endDate: Date?) {
    self.type = type
    self.interval = interval
    self.endDate = endDate
  }
}

public struct TaskEntity: Identifiable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var description: String?
  public var completed: Bool
  public var completedAt: Date?
  public var priority: TaskPriority
  public var dueDate: Date?
  public var projectId: String?
  public var tags: [String]
  public var createdAt: Date
  public var updatedAt: Date
  public var subtasks: [TaskSubtask]
  public var recurring: TaskRecurringPattern?
  public var userId: String?
  public var activity: [TaskActivityEntry]

  public init(
    id: String,
    title: String,
    description: String?,
    completed: Bool,
    completedAt: Date?,
    priority: TaskPriority,
    dueDate: Date?,
    projectId: String?,
    tags: [String],
    createdAt: Date,
    updatedAt: Date,
    subtasks: [TaskSubtask],
    recurring: TaskRecurringPattern?,
    userId: String?,
    activity: [TaskActivityEntry] = []
  ) {
    self.id = id
    self.title = title
    self.description = description
    self.completed = completed
    self.completedAt = completedAt
    self.priority = priority
    self.dueDate = dueDate
    self.projectId = projectId
    self.tags = tags
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.subtasks = subtasks
    self.recurring = recurring
    self.userId = userId
    self.activity = activity
  }
}

public struct ProjectEntity: Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var description: String?
  public var color: String
  public var icon: String?
  public var createdAt: Date
  public var updatedAt: Date
  public var archived: Bool
  public var userId: String?

  public init(
    id: String,
    name: String,
    description: String?,
    color: String,
    icon: String?,
    createdAt: Date,
    updatedAt: Date,
    archived: Bool,
    userId: String?
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.color = color
    self.icon = icon
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.archived = archived
    self.userId = userId
  }
}

public enum AttachmentType: String, Codable, Sendable {
  case image
  case video
  case audio
  case file
}

public struct JournalAttachmentEntity: Codable, Equatable, Sendable {
  public var id: String
  public var type: AttachmentType
  public var filename: String
  public var originalName: String
  public var path: String
  public var size: Int
  public var mimeType: String
  public var createdAt: Date

  public init(
    id: String,
    type: AttachmentType,
    filename: String,
    originalName: String,
    path: String,
    size: Int,
    mimeType: String,
    createdAt: Date
  ) {
    self.id = id
    self.type = type
    self.filename = filename
    self.originalName = originalName
    self.path = path
    self.size = size
    self.mimeType = mimeType
    self.createdAt = createdAt
  }
}

public enum JournalMood: String, Codable, Sendable {
  case happy
  case neutral
  case sad
  case excited
  case stressed
}

public struct JournalEntryEntity: Identifiable, Equatable, Sendable {
  public var id: String
  public var title: String?
  public var content: String
  public var date: Date
  public var tags: [String]
  public var createdAt: Date
  public var updatedAt: Date
  public var pinned: Bool
  public var mood: JournalMood?
  public var attachments: [JournalAttachmentEntity]
  public var userId: String?

  public init(
    id: String,
    title: String?,
    content: String,
    date: Date,
    tags: [String],
    createdAt: Date,
    updatedAt: Date,
    pinned: Bool,
    mood: JournalMood?,
    attachments: [JournalAttachmentEntity],
    userId: String?
  ) {
    self.id = id
    self.title = title
    self.content = content
    self.date = date
    self.tags = tags
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.pinned = pinned
    self.mood = mood
    self.attachments = attachments
    self.userId = userId
  }
}

public enum GoalType: String, Codable, Sendable {
  case weeklyTasks = "weekly_tasks"
  case projectTasks = "project_tasks"
  case priorityTasks = "priority_tasks"
  case dailyStreak = "daily_streak"
  case journalWeekly = "journal_weekly"
  case completionRate = "completion_rate"
}

public enum GoalTimeframe: String, Codable, Sendable {
  case daily
  case weekly
  case monthly
}

/// Outcomes have a finish line, targets reset every week or month, areas have no end and only
/// ask to be kept alive.
public enum GoalKind: String, Codable, Sendable, CaseIterable {
  case outcome
  case target
  case area
}

/// Where a goal's progress comes from. Everything but `manual` fills itself in.
public enum GoalSource: String, Codable, Sendable, CaseIterable {
  case manual
  case projectTasks = "project_tasks"
  case completedTasks = "completed_tasks"
  case routine
  case journalEntries = "journal_entries"
  case focusTime = "focus_time"
}

public struct GoalCheckIn: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var date: Date
  public var amount: Double
  public var note: String?

  public init(id: String = UUID().uuidString, date: Date, amount: Double, note: String?) {
    self.id = id
    self.date = date
    self.amount = amount
    self.note = note
  }
}

public struct GoalConfig: Codable, Equatable, Sendable {
  public var targetCount: Double?
  public var projectId: String?
  public var priority: TaskPriority?
  public var streakDays: Int?
  public var targetRate: Double?
  public var timeframe: GoalTimeframe
  // Absent on goals made before kinds existed; those read as manual counts with no deadline.
  public var kind: GoalKind?
  public var source: GoalSource?
  public var startDate: Date?
  public var dueDate: Date?
  public var unit: String?
  public var routineId: String?
  public var areaTag: String?
  public var quietDays: Int?
  public var checkIns: [GoalCheckIn]?

  public init(
    targetCount: Double?,
    projectId: String?,
    priority: TaskPriority?,
    streakDays: Int?,
    targetRate: Double?,
    timeframe: GoalTimeframe,
    kind: GoalKind? = nil,
    source: GoalSource? = nil,
    startDate: Date? = nil,
    dueDate: Date? = nil,
    unit: String? = nil,
    routineId: String? = nil,
    areaTag: String? = nil,
    quietDays: Int? = nil,
    checkIns: [GoalCheckIn]? = nil
  ) {
    self.targetCount = targetCount
    self.projectId = projectId
    self.priority = priority
    self.streakDays = streakDays
    self.targetRate = targetRate
    self.timeframe = timeframe
    self.kind = kind
    self.source = source
    self.startDate = startDate
    self.dueDate = dueDate
    self.unit = unit
    self.routineId = routineId
    self.areaTag = areaTag
    self.quietDays = quietDays
    self.checkIns = checkIns
  }
}

public struct GoalProgress: Codable, Equatable, Sendable {
  public var current: Double
  public var target: Double
  public var percentage: Double
  public var isCompleted: Bool
  public var periodStart: Date
  public var periodEnd: Date

  public init(
    current: Double,
    target: Double,
    percentage: Double,
    isCompleted: Bool,
    periodStart: Date,
    periodEnd: Date
  ) {
    self.current = current
    self.target = target
    self.percentage = percentage
    self.isCompleted = isCompleted
    self.periodStart = periodStart
    self.periodEnd = periodEnd
  }
}

public enum GoalStatus: String, Codable, Sendable {
  case active
  case completed
  case paused
  case failed
}

public enum GoalPriority: String, Codable, Sendable {
  case low
  case medium
  case high
}

public enum ReminderType: String, Codable, Sendable {
  case goalCheck = "goal_check"
  case taskDue = "task_due"
  case habitReminder = "habit_reminder"
  case custom
}

public enum ReminderStatus: String, Codable, Sendable {
  case pending
  case sent
  case dismissed
  case snoozed
}

public enum ReminderRepeatType: String, Codable, Sendable {
  case daily
  case weekly
  case monthly
  case custom
}

public struct ReminderRepeatPattern: Codable, Equatable, Sendable {
  public var type: ReminderRepeatType
  public var interval: Int
  public var endDate: Date?

  public init(type: ReminderRepeatType, interval: Int, endDate: Date?) {
    self.type = type
    self.interval = interval
    self.endDate = endDate
  }
}

public struct ReminderNotificationSettings: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var sound: Bool
  public var popup: Bool
  public var beforeMinutes: Int

  public init(enabled: Bool, sound: Bool, popup: Bool, beforeMinutes: Int) {
    self.enabled = enabled
    self.sound = sound
    self.popup = popup
    self.beforeMinutes = beforeMinutes
  }
}

public struct GoalReminder: Codable, Equatable, Sendable {
  public var id: String
  public var goalId: String?
  public var taskId: String?
  public var title: String
  public var description: String?
  public var reminderDate: Date
  public var type: ReminderType
  public var status: ReminderStatus
  public var repeatPattern: ReminderRepeatPattern?
  public var notificationSettings: ReminderNotificationSettings
  public var createdAt: Date
  public var updatedAt: Date
  public var userId: String?

  public init(
    id: String,
    goalId: String?,
    taskId: String?,
    title: String,
    description: String?,
    reminderDate: Date,
    type: ReminderType,
    status: ReminderStatus,
    repeatPattern: ReminderRepeatPattern?,
    notificationSettings: ReminderNotificationSettings,
    createdAt: Date,
    updatedAt: Date,
    userId: String?
  ) {
    self.id = id
    self.goalId = goalId
    self.taskId = taskId
    self.title = title
    self.description = description
    self.reminderDate = reminderDate
    self.type = type
    self.status = status
    self.repeatPattern = repeatPattern
    self.notificationSettings = notificationSettings
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.userId = userId
  }
}

public struct GoalEntity: Identifiable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var description: String?
  public var type: GoalType
  public var config: GoalConfig
  public var progress: GoalProgress
  public var status: GoalStatus
  public var priority: GoalPriority
  public var reminders: [GoalReminder]
  public var createdAt: Date
  public var updatedAt: Date
  public var userId: String?

  public init(
    id: String,
    title: String,
    description: String?,
    type: GoalType,
    config: GoalConfig,
    progress: GoalProgress,
    status: GoalStatus,
    priority: GoalPriority,
    reminders: [GoalReminder],
    createdAt: Date,
    updatedAt: Date,
    userId: String?
  ) {
    self.id = id
    self.title = title
    self.description = description
    self.type = type
    self.config = config
    self.progress = progress
    self.status = status
    self.priority = priority
    self.reminders = reminders
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.userId = userId
  }
}

public enum RoutineTimeOfDay: String, Codable, Sendable, CaseIterable {
  case morning
  case afternoon
  case evening
  case anytime
}

public enum RoutineSchedule: Codable, Equatable, Sendable {
  case daily
  case timesPerWeek(Int)
  /// `Calendar` weekday numbers, 1 = Sunday.
  case weekdays([Int])
}

public struct RoutineEntity: Identifiable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var schedule: RoutineSchedule
  public var timeOfDay: RoutineTimeOfDay
  public var archived: Bool
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: String,
    title: String,
    schedule: RoutineSchedule,
    timeOfDay: RoutineTimeOfDay,
    archived: Bool,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.title = title
    self.schedule = schedule
    self.timeOfDay = timeOfDay
    self.archived = archived
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum RoutineCheckStatus: String, Codable, Sendable {
  case done
  case skipped
}

/// One routine's mark for one day. The id is derived from both, so two devices ticking the same
/// day write the same record instead of two.
public struct RoutineCheckEntity: Identifiable, Equatable, Sendable {
  public var id: String
  public var routineId: String
  /// `yyyy-MM-dd` in the user's calendar.
  public var day: String
  public var status: RoutineCheckStatus
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    routineId: String,
    day: String,
    status: RoutineCheckStatus,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = Self.id(routineId: routineId, day: day)
    self.routineId = routineId
    self.day = day
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public static func id(routineId: String, day: String) -> String {
    "\(routineId):\(day)"
  }
}

public enum FocusBlockStatus: String, Codable, Sendable {
  case planned
  case running
  case paused
  case done
}

/// A stretch of time set aside for focused work. Finished blocks log their minutes, which feed
/// focus-time goals.
public struct FocusBlockEntity: Identifiable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var start: Date
  public var end: Date
  public var goalId: String?
  public var taskIds: [String]
  public var status: FocusBlockStatus
  public var startedAt: Date?
  public var finishedAt: Date?
  public var loggedMinutes: Double
  public var createdAt: Date
  public var updatedAt: Date
  /// Set while paused; the time since then is not focus time.
  public var pausedAt: Date?
  /// Total time spent in earlier pauses.
  public var pausedSeconds: Double

  public init(
    id: String,
    title: String,
    start: Date,
    end: Date,
    goalId: String?,
    taskIds: [String],
    status: FocusBlockStatus,
    startedAt: Date?,
    finishedAt: Date?,
    loggedMinutes: Double,
    createdAt: Date,
    updatedAt: Date,
    pausedAt: Date? = nil,
    pausedSeconds: Double = 0
  ) {
    self.pausedAt = pausedAt
    self.pausedSeconds = pausedSeconds
    self.id = id
    self.title = title
    self.start = start
    self.end = end
    self.goalId = goalId
    self.taskIds = taskIds
    self.status = status
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.loggedMinutes = loggedMinutes
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var plannedMinutes: Double {
    max(end.timeIntervalSince(start) / 60, 0)
  }

  /// Focused time so far, leaving out pauses.
  public func activeSeconds(at now: Date) -> Double {
    guard let startedAt else { return 0 }
    return max((pausedAt ?? now).timeIntervalSince(startedAt) - pausedSeconds, 0)
  }

  public var isActive: Bool {
    status == .running || status == .paused
  }
}
