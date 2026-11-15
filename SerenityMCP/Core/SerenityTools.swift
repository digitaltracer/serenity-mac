import Foundation

/// One MCP tool and the bridge method it calls. Arguments pass straight through as the method's params.
public struct SerenityTool {
  public let name: String
  public let title: String
  public let description: String
  public let method: String
  public let properties: [String: Any]
  public let required: [String]
  public let readOnly: Bool
  public let idempotent: Bool
  /// The card Claude shows with this tool's result.
  public var uiResource: String?
  /// Who may call it: the model, the card, or both (the default).
  public var visibility: [String]?

  /// Handled by the connector itself rather than the app.
  public static let openAppMethod = "connector.openApp"

  var definition: [String: Any] {
    var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
    if !required.isEmpty { schema["required"] = required }
    var ui: [String: Any] = [:]
    if let uiResource { ui["resourceUri"] = uiResource }
    if let visibility { ui["visibility"] = visibility }
    var meta: [String: Any] = [:]
    if !ui.isEmpty { meta["ui"] = ui }
    // Older hosts read the flat key.
    if let uiResource { meta["ui/resourceUri"] = uiResource }
    var definition: [String: Any] = [
      "name": name,
      "title": title,
      "description": description,
      "inputSchema": schema,
      "annotations": [
        "title": title,
        "readOnlyHint": readOnly,
        // Nothing here deletes; the worst a write does is change a field you can change back.
        "destructiveHint": false,
        "idempotentHint": readOnly || idempotent,
        "openWorldHint": false,
      ] as [String: Any],
    ]
    if !meta.isEmpty { definition["_meta"] = meta }
    return definition
  }
}

private func string(_ description: String) -> [String: Any] {
  ["type": "string", "description": description]
}

private func nullableString(_ description: String) -> [String: Any] {
  ["type": ["string", "null"], "description": description]
}

private let dayOrMoment = "A local day (2026-11-20) or local time (2026-11-20T15:30)."

public enum SerenityTools {
  public static let all: [SerenityTool] = [
    SerenityTool(
      name: "get_today",
      title: "Today in Serenity",
      description: "The user's day: the focus session under way, today's top three, other tasks due today, overdue tasks, the timed plan (calendar, tasks, focus), routines with streaks, goals with pace, and how many captures wait in the inbox. Start here for anything about today.",
      method: "today", properties: [:], required: [], readOnly: true, idempotent: true,
      uiResource: TodayCard.uri
    ),
    SerenityTool(
      name: "get_week_review",
      title: "This week",
      description: "This week so far (Monday to Sunday): tasks completed, hours focused, routine counts and goal pace. Use for weekly reviews and retrospectives.",
      method: "review.week", properties: [:], required: [], readOnly: true, idempotent: true
    ),
    SerenityTool(
      name: "list_tasks",
      title: "List tasks",
      description: "Tasks in one scope, optionally filtered by text in the title or notes. Use the ids it returns with the other task tools.",
      method: "tasks.list",
      properties: [
        "scope": ["type": "string", "enum": ["today", "overdue", "upcoming", "inbox", "open", "completed"], "description": "today (default): due today. upcoming: the next 7 days. inbox: undated and unsorted. open: everything not done. completed: newest first."],
        "query": string("Text to look for in the title or notes."),
        "limit": ["type": "integer", "minimum": 1, "maximum": 200, "description": "At most this many. Default 50."],
      ],
      required: [], readOnly: true, idempotent: true
    ),
    SerenityTool(
      name: "add_task",
      title: "Add a task",
      description: "Adds a task. Without a due date it lands in the inbox for the user to sort.",
      method: "tasks.add",
      properties: [
        "title": string("What needs doing, short."),
        "due": string("When it's due. \(dayOrMoment)"),
        "priority": ["type": "string", "enum": ["low", "medium", "high"], "description": "Default medium."],
        "notes": string("Extra detail."),
        "projectId": string("A project id, if the user named one."),
      ],
      required: ["title"], readOnly: false, idempotent: false
    ),
    SerenityTool(
      name: "set_task_done",
      title: "Complete or reopen a task",
      description: "Marks a task done, or not done. Completing a repeating task schedules its next one.",
      method: "tasks.setDone",
      properties: ["id": string("The task id."), "done": ["type": "boolean"]],
      required: ["id", "done"], readOnly: false, idempotent: true
    ),
    SerenityTool(
      name: "reschedule_task",
      title: "Move a task",
      description: "Gives a task a new due date, or sends it back to the inbox with null.",
      method: "tasks.reschedule",
      properties: ["id": string("The task id."), "due": nullableString("\(dayOrMoment) Null clears the date.")],
      required: ["id", "due"], readOnly: false, idempotent: true
    ),
    SerenityTool(
      name: "get_focus",
      title: "Current focus session",
      description: "The focus session under way, running or paused, with time focused and time left; focus is null when none is.",
      method: "focus.status", properties: [:], required: [], readOnly: true, idempotent: true
    ),
    SerenityTool(
      name: "start_focus",
      title: "Start a focus session",
      description: "Starts a focus session now. Any session already under way is finished and logged first. Without minutes it runs the user's usual length.",
      method: "focus.start",
      properties: [
        "title": string("What the session is for. Defaults to the linked task's title."),
        "minutes": ["type": "integer", "minimum": 5, "maximum": 240, "description": "Length in minutes."],
        "openEnded": ["type": "boolean", "description": "True for a session with no set length."],
        "taskId": string("Link the session to this task."),
        "journalEntryId": string("Link the session to this journal entry."),
      ],
      required: [], readOnly: false, idempotent: false
    ),
    SerenityTool(
      name: "pause_focus",
      title: "Pause focus",
      description: "Pauses the running session. Paused time isn't counted.",
      method: "focus.pause", properties: [:], required: [], readOnly: false, idempotent: true
    ),
    SerenityTool(
      name: "resume_focus",
      title: "Resume focus",
      description: "Resumes a paused session.",
      method: "focus.resume", properties: [:], required: [], readOnly: false, idempotent: true
    ),
    SerenityTool(
      name: "extend_focus",
      title: "Change focus length",
      description: "Adds minutes to the session, or takes them off with a negative number. Never below 5 minutes in all.",
      method: "focus.extend",
      properties: ["minutes": ["type": "integer", "minimum": -235, "maximum": 235, "description": "Minutes to add; negative to shorten."]],
      required: ["minutes"], readOnly: false, idempotent: false
    ),
    SerenityTool(
      name: "finish_focus",
      title: "Finish focus",
      description: "Ends the session and logs the focused time, on its linked task too.",
      method: "focus.finish", properties: [:], required: [], readOnly: false, idempotent: false
    ),
    SerenityTool(
      name: "link_focus",
      title: "Link the focus session",
      description: "Links the session under way to a task or journal entry. Pass null to unlink; leave a key out to keep it.",
      method: "focus.link",
      properties: ["taskId": nullableString("A task id, or null."), "journalEntryId": nullableString("A journal entry id, or null.")],
      required: [], readOnly: false, idempotent: true
    ),
    SerenityTool(
      name: "list_routines",
      title: "Routines",
      description: "The user's routines: whether each is due today, whether today is done or skipped, and the streak.",
      method: "routines.list", properties: [:], required: [], readOnly: true, idempotent: true
    ),
    SerenityTool(
      name: "set_routine_done",
      title: "Tick a routine",
      description: "Marks today done for a routine, or clears it. Only today can change.",
      method: "routines.setDone",
      properties: ["id": string("The routine id."), "done": ["type": "boolean"]],
      required: ["id", "done"], readOnly: false, idempotent: true
    ),
    SerenityTool(
      name: "list_goals",
      title: "Goals",
      description: "Active goals with progress, pace against the deadline, and units.",
      method: "goals.list", properties: [:], required: [], readOnly: true, idempotent: true
    ),
    SerenityTool(
      name: "check_in_goal",
      title: "Check in on a goal",
      description: "Logs progress by hand, in the goal's unit (for example 5 for 5 km), with an optional note.",
      method: "goals.checkIn",
      properties: ["id": string("The goal id."), "amount": ["type": "number", "description": "Progress to add, in the goal's unit."], "note": string("What happened.")],
      required: ["id", "amount"], readOnly: false, idempotent: false
    ),
    SerenityTool(
      name: "search_journal",
      title: "Search the journal",
      description: "Journal entries, newest first, optionally only those containing some text. Works only if the user has turned on journal access in Serenity.",
      method: "journal.search",
      properties: ["query": string("Text to look for."), "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Default 10."]],
      required: [], readOnly: true, idempotent: true
    ),
    SerenityTool(
      name: "add_journal_entry",
      title: "Write a journal entry",
      description: "Adds a journal entry dated now. Without a title, Serenity names it. Works only if the user has turned on journal access in Serenity.",
      method: "journal.add",
      properties: ["content": string("The entry, in the user's words where possible."), "title": string("A short title.")],
      required: ["content"], readOnly: false, idempotent: false
    ),
    SerenityTool(
      name: "open_serenity",
      title: "Open Serenity",
      description: "Brings the Serenity app to the front on this Mac.",
      method: SerenityTool.openAppMethod, properties: [:], required: [], readOnly: true, idempotent: true,
      visibility: ["app"]
    ),
  ]

  public static let byName: [String: SerenityTool] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
}
