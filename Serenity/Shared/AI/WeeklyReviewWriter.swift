import Foundation

/// Lets the AI provider rephrase the week's findings and add its own, from records it can only cite.
/// Serenity counts everything first; whatever comes back is checked against what was sent.
enum WeeklyReviewWriter {
  struct Input: Encodable {
    struct Metrics: Encodable {
      var tasksDone: Int
      var tasksUsual: Double?
      var focusHours: Double
      var focusUsual: Double?
      var focusTarget: Double?
      var routines: [Routine]
    }

    struct Routine: Encodable {
      var id: String
      var title: String
      var done: Int
      var expected: Int
    }

    struct Task: Encodable {
      var id: String
      var title: String
      var project: String?
      var done: String?
      var due: String?
      var created: String
      var dueChanges: [String]
    }

    struct Session: Encodable {
      var id: String
      var title: String
      var day: String
      var hours: Double
      var project: String?
    }

    struct Check: Encodable {
      var id: String
      var routineId: String
      var routine: String
      var day: String
      var status: String
    }

    struct Goal: Encodable {
      var id: String
      var title: String
      var lastMonday: Double
      var thisMonday: Double
      var target: Double
      var status: String
      var paused: Bool
    }

    struct Event: Encodable {
      var id: String
      var title: String
      var start: String
    }

    struct Entry: Encodable {
      var id: String
      var day: String
      var mood: Int?
      var title: String?
      var tags: [String]
      var text: String
    }

    struct Finding: Encodable {
      var id: String
      var kind: String
      var title: String
      var body: String
      var evidence: [String]
    }

    var week: String
    var weekStart: String
    var history: String
    var usesJournal: Bool
    var metrics: Metrics
    var tasks: [Task]
    var sessions: [Session]
    var routineChecks: [Check]
    var goals: [Goal]
    var calendar: [Event]
    var journal: [Entry]?
    var findings: [Finding]

    /// Every record id the model may cite.
    var recordIDs: Set<String> {
      var ids = Set(tasks.map(\.id))
      ids.formUnion(sessions.map(\.id))
      ids.formUnion(routineChecks.map(\.id))
      ids.formUnion(goals.map(\.id))
      ids.formUnion(calendar.map(\.id))
      ids.formUnion((journal ?? []).map(\.id))
      return ids
    }
  }

  static let taskLimit = 60
  static let sessionLimit = 80
  static let checkLimit = 120
  static let eventLimit = 80
  static let journalTextLimit = 500

  static func input(recap: WeeklyRecap, inputs: WeeklyRecapInputs, now: Date, calendar: Calendar = WeeklyReview.calendar) -> Input {
    let day = DayStamp(calendar: calendar)
    let windowStart = calendar.date(byAdding: .day, value: -7 * WeeklyRecap.historyWeeks, to: recap.weekStart) ?? recap.weekStart
    let inWindow: (Date) -> Bool = { $0 >= windowStart && $0 < recap.weekEnd }
    let inWeek: (Date) -> Bool = { $0 >= recap.weekStart && $0 < recap.weekEnd }
    let projectNames = Dictionary(inputs.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let carried = Set(recap.carryOver.map(\.taskId))

    let tasks = inputs.tasks
      .filter { task in
        guard !WeeklyRecap.isCalendarEvent(task) else { return false }
        if let completedAt = task.completedAt, task.completed { return inWeek(completedAt) }
        return carried.contains(task.id) || WeeklyRecap.dueMoves(task).contains(where: inWeek)
      }
      .prefix(taskLimit)
      .map { task in
        Input.Task(
          id: task.id,
          title: task.title,
          project: task.projectId.flatMap { projectNames[$0] },
          done: task.completed ? task.completedAt.map(day.string) : nil,
          due: task.dueDate.map(day.string),
          created: day.string(task.createdAt),
          dueChanges: WeeklyRecap.dueMoves(task).map(day.string)
        )
      }

    let sessions = inputs.focusBlocks
      .filter { $0.status == .done && $0.loggedMinutes > 0 && inWindow($0.startedAt ?? $0.start) }
      .sorted { ($0.startedAt ?? $0.start) > ($1.startedAt ?? $1.start) }
      .prefix(sessionLimit)
      .map { block -> Input.Session in
        let session = recap.days.flatMap(\.sessions).first { $0.id == block.id }
        return Input.Session(
          id: block.id,
          title: block.title,
          day: day.string(block.startedAt ?? block.start),
          hours: (block.loggedMinutes / 6).rounded() / 10,
          project: session?.projectName
        )
      }

    let routineTitles = Dictionary(inputs.routines.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    let checks = inputs.routineChecks
      .filter { check in GoalReports.date(fromDayKey: check.day, calendar: calendar).map(inWindow) ?? false }
      .sorted { $0.day > $1.day }
      .prefix(checkLimit)
      .map { Input.Check(id: $0.id, routineId: $0.routineId, routine: routineTitles[$0.routineId] ?? "", day: $0.day, status: $0.status.rawValue) }

    let events = inputs.tasks
      .filter { WeeklyRecap.isCalendarEvent($0) && !$0.completed && ($0.dueDate.map(inWindow) ?? false) }
      .sorted { $0.dueDate! > $1.dueDate! }
      .prefix(eventLimit)
      .map { Input.Event(id: $0.id, title: $0.title, start: day.stamp($0.dueDate!)) }

    let journal: [Input.Entry]? = inputs.useJournal
      ? inputs.journalEntries.filter { inWeek($0.date) }.sorted { $0.date < $1.date }.map { entry in
        Input.Entry(
          id: entry.id,
          day: day.string(entry.date),
          mood: entry.mood.map(WeeklyRecap.moodScore),
          title: entry.title,
          tags: entry.tags,
          text: String(entry.content.prefix(journalTextLimit))
        )
      }
      : nil

    return Input(
      week: "\(day.string(recap.weekStart)) to \(day.string(recap.weekEnd.addingTimeInterval(-1)))",
      weekStart: day.string(recap.weekStart),
      history: recap.hasPatterns ? "\(recap.weeksOfHistory) weeks" : "under \(WeeklyRecap.historyWeeks) weeks; do not describe patterns or compare with a usual week",
      usesJournal: inputs.useJournal,
      metrics: Input.Metrics(
        tasksDone: recap.tasks.done,
        tasksUsual: recap.tasks.baseline.map { ($0 * 10).rounded() / 10 },
        focusHours: (recap.focus.hours * 10).rounded() / 10,
        focusUsual: recap.focus.baseline.map { ($0 * 10).rounded() / 10 },
        focusTarget: recap.focus.target,
        routines: recap.routines.map { Input.Routine(id: $0.routineId, title: $0.title, done: $0.done, expected: $0.expected) }
      ),
      tasks: Array(tasks),
      sessions: Array(sessions),
      routineChecks: Array(checks),
      goals: recap.goals.map { change in
        Input.Goal(
          id: change.goalId,
          title: change.title,
          lastMonday: change.before.current,
          thisMonday: change.after.current,
          target: change.after.target,
          status: change.after.statusLabel,
          paused: change.isPaused
        )
      },
      calendar: Array(events),
      journal: journal,
      findings: recap.findings.map { finding in
        Input.Finding(id: finding.id, kind: finding.kind.rawValue, title: finding.title, body: finding.body, evidence: finding.evidence.map(\.ref))
      }
    )
  }

  static func systemPrompt() -> String {
    """
    You help one person look back at their last week in a productivity app. The app has already counted \
    everything and drafted up to three findings. You get the records and those drafts as JSON.

    Return at most three findings, best first. Each one either rewrites a draft (set "basedOn" to the \
    draft's id) or is a new one you found by joining records (set "basedOn" to "").

    Rules:
    - Use only the records given. Never invent a task, number, name, date or reason.
    - Every number you write must appear in the records. Say "4 of 5 times", not "most times".
    - "evidence" lists the ids of the records the finding rests on, at least one. Only ids from the input.
    - Compare with the person's own usual week, never with general norms. If "history" says under four \
    weeks, describe this week only.
    - A title is one plain sentence, under twelve words. A body is two or three short sentences.
    - Speak to the person as "you". No praise, no pep talk, no advice beyond the one action.
    - "action" may only be: "firstOnToday" or "scheduleTask" with the id of an open task, "pauseGoal" with \
    a goal id, or "none". Rewritten drafts keep their own action, so use "none" for them.
    - If nothing stands out, return an empty list.
    """
  }

  static func userPrompt(_ input: Input) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(input), as: UTF8.self)
  }

  static func schema() -> [String: Any] {
    [
      "title": "weekly_review_findings",
      "type": "object",
      "additionalProperties": false,
      "required": ["findings"],
      "properties": [
        "findings": [
          "type": "array",
          "items": [
            "type": "object",
            "additionalProperties": false,
            "required": ["basedOn", "title", "body", "evidence", "action"],
            "properties": [
              "basedOn": ["type": "string"],
              "title": ["type": "string"],
              "body": ["type": "string"],
              "evidence": ["type": "array", "items": ["type": "string"]],
              "action": [
                "type": "object",
                "additionalProperties": false,
                "required": ["type", "id"],
                "properties": [
                  "type": ["type": "string", "enum": ["none", "firstOnToday", "scheduleTask", "pauseGoal"]],
                  "id": ["type": "string"],
                ],
              ],
            ],
          ],
        ],
      ],
    ]
  }

  private struct Payload: Decodable {
    struct Action: Decodable {
      let type: String
      let id: String?
    }

    struct Item: Decodable {
      let basedOn: String?
      let title: String
      let body: String
      let evidence: [String]?
      let action: Action?
    }

    let findings: [Item]
  }

  struct Result: Equatable {
    var findings: [WeeklyFinding]
    var rewritten = 0
    var added = 0
    /// What was thrown away and why, for the log.
    var rejected: [String] = []
  }

  /// Checks the reply against the input and merges it with Serenity's own findings. A rewrite that
  /// fails a check keeps Serenity's wording; a new finding that fails is dropped.
  static func merge(
    responseText: String,
    input: Input,
    userPrompt: String,
    deterministic: [WeeklyFinding],
    feedback: [WeeklyFindingFeedback],
    hasHistory: Bool,
    weekStart: Date,
    nextWeekday: Date,
    calendar: Calendar = WeeklyReview.calendar
  ) throws -> Result {
    let json = extractJSONObject(from: responseText)
    guard let data = json.data(using: .utf8) else { throw AIProviderAPIError.decoding }
    let payload = try JSONDecoder().decode(Payload.self, from: data)

    let ids = input.recordIDs
    let allowedNumbers = numbers(in: userPrompt)
    let openTasks = Set(input.tasks.filter { $0.done == nil }.map(\.id))
    let goals = Set(input.goals.map(\.id))
    let titles = titleIndex(input)

    var result = Result(findings: deterministic)
    var added: [WeeklyFinding] = []

    for item in payload.findings.prefix(WeeklyRecap.maxFindings) {
      let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
      let cited = item.evidence ?? []
      var problems: [String] = []
      if title.isEmpty || body.isEmpty { problems.append("empty text") }
      if cited.isEmpty { problems.append("no evidence") }
      let unknown = cited.filter { !ids.contains($0) }
      if !unknown.isEmpty { problems.append("unknown ids \(unknown.joined(separator: ", "))") }
      let invented = numbers(in: "\(title) \(body)").subtracting(allowedNumbers)
      if !invented.isEmpty { problems.append("numbers not in the input: \(invented.sorted().map { GoalReport.format($0) }.joined(separator: ", "))") }

      let basedOn = item.basedOn?.trimmingCharacters(in: .whitespaces) ?? ""
      if !basedOn.isEmpty {
        guard let index = result.findings.firstIndex(where: { $0.id == basedOn }) else {
          result.rejected.append("rewrite of unknown finding \(basedOn)")
          continue
        }
        guard problems.isEmpty else {
          result.rejected.append("rewrite of \(basedOn): \(problems.joined(separator: "; "))")
          continue
        }
        result.findings[index].title = title
        result.findings[index].body = body
        result.rewritten += 1
        continue
      }

      var action: WeeklyAction?
      var actionTitle: String?
      if let raw = item.action, raw.type != "none", let id = raw.id {
        switch raw.type {
        case "firstOnToday" where openTasks.contains(id):
          action = .firstOnToday(taskId: id)
          actionTitle = "Make it first on Today"
        case "scheduleTask" where openTasks.contains(id):
          action = .scheduleTask(taskId: id, day: nextWeekday)
          actionTitle = "Plan it for \(nextWeekday.formatted(.dateTime.weekday(.wide)))"
        case "pauseGoal" where goals.contains(id):
          action = .pauseGoal(goalId: id)
          actionTitle = "Pause it next week"
        default:
          problems.append("action \(raw.type) on \(id) not allowed")
        }
      }
      guard problems.isEmpty else {
        result.rejected.append("new finding “\(title)”: \(problems.joined(separator: "; "))")
        continue
      }
      let subject = cited.sorted().joined(separator: "+")
      added.append(WeeklyFinding(
        id: "\(WeeklyFinding.Kind.observation.rawValue):\(subject)",
        kind: .observation,
        subjectId: subject,
        linked: "",
        title: title,
        body: body,
        evidenceLabel: "Evidence: \(cited.count) record\(cited.count == 1 ? "" : "s")",
        evidence: cited.map { id in
          WeeklyEvidence(source: titles[id]?.source ?? .task, ref: id, date: nil, when: titles[id]?.when ?? "", what: titles[id]?.what ?? id, meta: titles[id]?.meta ?? "")
        },
        action: action,
        actionTitle: actionTitle,
        score: 2
      ))
    }

    result.added = added.count
    result.findings = WeeklyRecap.rank(result.findings + added, feedback: feedback, hasHistory: hasHistory, weekStart: weekStart, calendar: calendar)
    return result
  }

  /// Numeric values in a text, so "4.5 h" and "4,5" both read as 4.5.
  static func numbers(in text: String) -> Set<Double> {
    let pattern = try! NSRegularExpression(pattern: #"\d+(?:[.,]\d+)?"#)
    let range = NSRange(text.startIndex..., in: text)
    return Set(pattern.matches(in: text, range: range).compactMap { match in
      Range(match.range, in: text).flatMap { Double(text[$0].replacingOccurrences(of: ",", with: ".")) }
    })
  }

  private static func titleIndex(_ input: Input) -> [String: (source: WeeklyEvidence.Source, when: String, what: String, meta: String)] {
    var index: [String: (WeeklyEvidence.Source, String, String, String)] = [:]
    for task in input.tasks { index[task.id] = (.task, task.done ?? task.due ?? task.created, task.title, task.project ?? "task") }
    for session in input.sessions { index[session.id] = (.focus, session.day, session.title, "\(GoalReport.format(session.hours)) h") }
    for check in input.routineChecks { index[check.id] = (.routine, check.day, check.routine, check.status) }
    for goal in input.goals { index[goal.id] = (.goal, "Goal", goal.title, goal.status) }
    for event in input.calendar { index[event.id] = (.calendar, event.start, event.title, "calendar") }
    for entry in input.journal ?? [] { index[entry.id] = (.journal, entry.day, entry.title ?? String(entry.text.prefix(60)), "journal") }
    return index.mapValues { (source: $0.0, when: $0.1, what: $0.2, meta: $0.3) }
  }

  private static func extractJSONObject(from text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end else {
      return trimmed
    }
    return String(trimmed[start...end])
  }

  /// "2026-11-09" and "2026-11-09 19:30", in the review's calendar.
  private struct DayStamp {
    let calendar: Calendar

    func string(_ date: Date) -> String {
      let parts = calendar.dateComponents([.year, .month, .day], from: date)
      return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func stamp(_ date: Date) -> String {
      let parts = calendar.dateComponents([.hour, .minute], from: date)
      return "\(string(date)) \(String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0))"
    }
  }
}
