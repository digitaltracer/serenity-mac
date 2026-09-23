import Foundation

public enum SlackDecisionAction: String, Codable, Sendable {
  case create
  case update
  case ignore
}

/// One model verdict about one Slack signal, already normalized. `ignore` is a
/// first-class answer, not a failure.
public struct SlackDecision: Equatable, Sendable {
  public var signalID: String
  public var action: SlackDecisionAction
  public var targetTaskID: String?
  public var payload: SlackProposalPayload
  public var confidence: Double
  public var reason: String?
}

/// Everything that turns Slack messages into a prompt and a prompt back into
/// proposals. Kept free of network and credentials so the judgement calls can
/// be tested on their own.
enum SlackProposalPlanner {
  static let maxSignalsPerBatch = 5
  static let maxPromptCharacters = 12_000
  static let candidateTaskLimit = 8

  /// The tag that links a task to the Slack thread it came from. Any later
  /// message in that thread resolves straight back to the task, which is what
  /// stops a long conversation spawning near-duplicate tasks.
  /// Lowercased because tags are normalized that way on the task. Producing it
  /// in any other case would break the very lookup it exists for.
  static func threadTag(channelID: String, threadTS: String) -> String {
    "slack-thread-\(channelID)-\(threadTS)".lowercased()
  }

  static func threadRoot(of message: SlackMessage) -> String {
    message.threadTS ?? message.ts
  }

  static func batches(of signals: [SlackSignal]) -> [[SlackSignal]] {
    var batches: [[SlackSignal]] = []
    var current: [SlackSignal] = []
    var currentCharacters = 0

    for signal in signals {
      let size = signal.anchor.text.count + signal.context.reduce(0) { $0 + $1.text.count }
      let wouldOverflow = current.count >= maxSignalsPerBatch
        || (!current.isEmpty && currentCharacters + size > maxPromptCharacters)

      if wouldOverflow {
        batches.append(current)
        current = []
        currentCharacters = 0
      }

      current.append(signal)
      currentCharacters += size
    }

    if !current.isEmpty {
      batches.append(current)
    }

    return batches
  }

  /// Narrows open tasks to the handful a signal could plausibly be about.
  /// Handing a model every open task is both expensive and worse — it starts
  /// matching on tone rather than subject.
  static func shortlist(tasks: [TaskEntity], for signal: SlackSignal, limit: Int = candidateTaskLimit) -> [TaskEntity] {
    let open = tasks.filter { !$0.completed }
    let tag = threadTag(
      channelID: signal.anchor.channelID,
      threadTS: threadRoot(of: signal.anchor)
    )

    let linked = open.filter { $0.tags.contains(tag) }
    if !linked.isEmpty {
      return Array(linked.prefix(limit))
    }

    let signalTokens = tokens(in: signal.anchor.text)
    guard !signalTokens.isEmpty else { return [] }

    let scored = open.compactMap { task -> (TaskEntity, Int)? in
      let overlap = tokens(in: task.title).union(tokens(in: task.description ?? "")).intersection(signalTokens)
      return overlap.isEmpty ? nil : (task, overlap.count)
    }

    return scored
      .sorted { ($0.1, $0.0.updatedAt) > ($1.1, $1.0.updatedAt) }
      .prefix(limit)
      .map(\.0)
  }

  /// Renders a signal the way a person would read it: display names instead of
  /// user IDs, absolute timestamps, and the anchor marked so the model knows
  /// which message it is being asked about.
  static func render(signal: SlackSignal, names: [String: String], now: Date) -> String {
    var lines = ["#\(signal.anchor.channelName)"]

    for message in signal.context {
      lines.append("  \(message.authorName): \(clean(message.text, names: names))")
    }

    lines.append(
      "> \(signal.anchor.authorName) (\(Self.stamp(signal.anchor.sentAt))): \(clean(signal.anchor.text, names: names))"
    )

    return lines.joined(separator: "\n")
  }

  static func systemPrompt(ownName: String) -> String {
    """
    You read excerpts of Slack conversations and decide what they mean for \(ownName)'s personal task list.

    For each signal return exactly one decision:
    - "create" when the conversation asks \(ownName) to do something that is not already on the candidate list.
    - "update" when it changes something already on the candidate list — a new due date, a different priority, \
    extra detail, or work that has been finished or reopened.
    - "ignore" for anything else: discussion, FYIs, thanks, questions already answered, decisions with no action, \
    or work clearly assigned to somebody else.

    Rules:
    - Prefer "ignore". A wrong proposal costs the user more attention than a missed one.
    - Only use "update" with a targetTaskId taken from the candidate list for that signal. Never invent an id.
    - Every date must be absolute ISO-8601 (yyyy-MM-dd). Resolve "Friday", "tomorrow" and "next week" against \
    today's date, which is given below. Never return a relative phrase.
    - Titles are short and imperative: "Send the Q3 export to finance", not "@jane asked about the export".
    - statusChange is "completed" only when the message says the work is done, "reopened" when finished work is \
    reported broken, otherwise "none".
    - confidence is your own estimate from 0 to 1 that this decision is correct and would be accepted.
    - reason is one short sentence naming the evidence, shown to the user next to the proposal.
    """
  }

  static func userPrompt(
    signals: [SlackSignal],
    candidates: [String: [TaskEntity]],
    projects: [AIQuickCaptureProjectContext],
    availableTags: [String],
    names: [String: String],
    now: Date
  ) -> String {
    var sections: [String] = ["Today is \(Self.stamp(now))."]

    let allCandidates = signals
      .flatMap { candidates[$0.id] ?? [] }
      .reduce(into: [String: TaskEntity]()) { $0[$1.id] = $1 }

    if allCandidates.isEmpty {
      sections.append("Candidate tasks: none — every decision is create or ignore.")
    } else {
      let rendered = allCandidates.values
        .sorted { $0.updatedAt > $1.updatedAt }
        .map { task in
          var parts = ["[\(task.id)] \"\(task.title)\""]
          if let dueDate = task.dueDate {
            parts.append("due \(Self.stamp(dueDate))")
          }
          parts.append("priority \(task.priority.rawValue)")
          if let projectID = task.projectId,
             let project = projects.first(where: { $0.id == projectID }) {
            parts.append("project \(project.name)")
          }
          return "- " + parts.joined(separator: ", ")
        }
      sections.append((["Candidate tasks:"] + rendered).joined(separator: "\n"))
    }

    let activeProjects = projects.filter { !$0.archived }
    if !activeProjects.isEmpty {
      sections.append("Projects: " + activeProjects.map { "[\($0.id)] \($0.name)" }.joined(separator: ", "))
    }
    if !availableTags.isEmpty {
      sections.append("Existing tags: " + availableTags.joined(separator: ", "))
    }

    for signal in signals {
      var block = ["--- signal \(signal.id) ---", render(signal: signal, names: names, now: now)]
      let ids = (candidates[signal.id] ?? []).map(\.id)
      block.append(ids.isEmpty ? "Candidates for this signal: none" : "Candidates for this signal: \(ids.joined(separator: ", "))")
      sections.append(block.joined(separator: "\n"))
    }

    sections.append("Return one decision per signal, using the signal ids exactly as written above.")
    return sections.joined(separator: "\n\n")
  }

  static func schema() -> [String: Any] {
    [
      "title": "slack_decisions",
      "type": "object",
      "additionalProperties": false,
      "required": ["decisions"],
      "properties": [
        "decisions": [
          "type": "array",
          "items": [
            "type": "object",
            "additionalProperties": false,
            "required": [
              "signalId", "action", "targetTaskId", "title", "description", "priority",
              "dueDate", "projectId", "projectName", "tags", "subtasks", "statusChange",
              "confidence", "reason",
            ],
            "properties": [
              "signalId": ["type": "string"],
              "action": ["type": "string", "enum": ["create", "update", "ignore"]],
              "targetTaskId": ["type": ["string", "null"]],
              "title": ["type": ["string", "null"]],
              "description": ["type": ["string", "null"]],
              "priority": ["type": ["string", "null"], "enum": ["low", "medium", "high", NSNull()]],
              "dueDate": ["type": ["string", "null"]],
              "projectId": ["type": ["string", "null"]],
              "projectName": ["type": ["string", "null"]],
              "tags": ["type": "array", "items": ["type": "string"]],
              "subtasks": ["type": "array", "items": ["type": "string"]],
              "statusChange": ["type": "string", "enum": ["none", "completed", "reopened"]],
              "confidence": ["type": "number", "minimum": 0, "maximum": 1],
              "reason": ["type": ["string", "null"]],
            ],
          ],
        ],
      ],
    ]
  }

  /// Slack wraps mentions, channels and links in its own markup. Left in, a
  /// model happily copies `<@U024BE7LH>` into a task title.
  static func clean(_ text: String, names: [String: String]) -> String {
    var result = text

    for (id, name) in names {
      result = result.replacingOccurrences(of: "<@\(id)>", with: "@\(name)")
    }

    result = result.replacingOccurrences(
      of: "<@[A-Za-z0-9_]+(\\|[^>]*)?>",
      with: "@someone",
      options: .regularExpression
    )
    result = result.replacingOccurrences(
      of: "<#[A-Za-z0-9_]+\\|([^>]*)>",
      with: "#$1",
      options: .regularExpression
    )
    result = result.replacingOccurrences(
      of: "<((?:https?|mailto):[^>|]+)\\|([^>]*)>",
      with: "$2",
      options: .regularExpression
    )
    result = result.replacingOccurrences(
      of: "<((?:https?|mailto):[^>|]+)>",
      with: "$1",
      options: .regularExpression
    )
    result = result.replacingOccurrences(of: "<!here>", with: "@here")
    result = result.replacingOccurrences(of: "<!channel>", with: "@channel")
    result = result.replacingOccurrences(
      of: "<!subteam\\^[A-Za-z0-9_]+(\\|([^>]*))?>",
      with: "$2",
      options: .regularExpression
    )

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static let stopWords: Set<String> = [
    "the", "and", "for", "with", "that", "this", "from", "have", "has", "was", "are",
    "you", "your", "our", "can", "will", "would", "should", "could", "about", "into",
    "please", "thanks", "hey", "any", "all", "not", "but", "its", "it's", "get", "got",
    "need", "needs", "make", "made", "just", "now", "let", "lets", "one", "out", "who",
  ]

  static func tokens(in text: String) -> Set<String> {
    let stripped = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    let pieces = stripped
      .lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { $0.count > 3 && !stopWords.contains($0) }
    return Set(pieces)
  }

  private static func stamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE d MMM yyyy"
    return formatter.string(from: date)
  }
}

enum SlackProposalMapper {
  /// Turns a decision into something the review inbox can show. `ignore` and
  /// anything missing its essentials return nil — the caller still records the
  /// message as seen so it is never re-read.
  static func proposal(
    from decision: SlackDecision,
    signal: SlackSignal,
    workspaceURL: String?,
    names: [String: String],
    now: Date = Date()
  ) -> SlackProposal? {
    guard decision.action != .ignore else { return nil }

    var payload = decision.payload
    let threadRoot = SlackProposalPlanner.threadRoot(of: signal.anchor)

    if decision.action == .create {
      guard let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
        return nil
      }
      payload.title = title
      payload.tags = normalizedTags(
        payload.tags + ["slack", SlackProposalPlanner.threadTag(channelID: signal.anchor.channelID, threadTS: threadRoot)]
      )
    } else {
      guard decision.targetTaskID?.isEmpty == false else { return nil }
      payload.tags = normalizedTags(payload.tags)
    }

    let excerpt = SlackProposalPlanner.clean(signal.anchor.text, names: names)

    return SlackProposal(
      kind: decision.action == .create ? .create : .update,
      targetTaskID: decision.action == .update ? decision.targetTaskID : nil,
      payload: payload,
      confidence: min(1, max(0, decision.confidence)),
      reason: decision.reason?.nilIfEmpty,
      source: SlackProposalSource(
        channelID: signal.anchor.channelID,
        channelName: signal.anchor.channelName,
        messageTS: signal.anchor.ts,
        threadTS: threadRoot,
        author: signal.anchor.authorName,
        excerpt: String(excerpt.prefix(500)),
        permalink: SlackMessage.permalink(
          workspaceURL: workspaceURL,
          channelID: signal.anchor.channelID,
          ts: signal.anchor.ts
        )
      ),
      createdAt: now
    )
  }

  private static func normalizedTags(_ tags: [String]) -> [String] {
    var seen: Set<String> = []
    return tags
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
  }
}

struct SlackDecisionOutcome: Sendable {
  var decisions: [SlackDecision]
  /// Signals whose batch threw. Recorded as retryable rather than silently
  /// dropped — and never marked as processed, or they would be lost.
  var failedSignalIDs: [String]
  var lastError: String?
}
