import Foundation

/// The material one link resolved to. Flattening both providers into one type
/// keeps the renderer, the duplicate check and the prompt free of per-provider
/// branching.
enum CaptureSource: Equatable, Sendable {
  case slack(SlackConversationExcerpt)
  case github(GitHubPullSnapshot)
}

enum CaptureDraftKind: String, Equatable, Sendable {
  case create
  case update
}

/// One task a command would produce. The payload is `SlackProposalPayload`
/// deliberately: it already means "the fields a draft would set, each optional
/// so an update writes only what changed", and the apply path already consumes
/// it — a parallel type would mean a parallel write path.
struct CaptureDraft: Equatable, Sendable, Identifiable {
  var id: String
  /// What the drafter decided. `chosenKind` overrides it when the user says the
  /// match is wrong; holding both means switching back and forth loses nothing.
  var kind: CaptureDraftKind
  var chosenKind: CaptureDraftKind?
  var targetTaskID: String?
  var payload: SlackProposalPayload
  /// The title a new task would take, kept apart from the payload because
  /// redirecting a draft onto the task it matched clears `payload.title` — a
  /// repeated link must not rename what it matched.
  var proposedTitle: String?
  var confidence: Double
  var reason: String?
  var sourceLabel: String
  var sourceLinks: [String]

  init(
    id: String = UUID().uuidString,
    kind: CaptureDraftKind,
    chosenKind: CaptureDraftKind? = nil,
    targetTaskID: String? = nil,
    payload: SlackProposalPayload,
    proposedTitle: String? = nil,
    confidence: Double,
    reason: String? = nil,
    sourceLabel: String,
    sourceLinks: [String] = []
  ) {
    self.id = id
    self.kind = kind
    self.chosenKind = chosenKind
    self.targetTaskID = targetTaskID
    self.payload = payload
    self.proposedTitle = proposedTitle ?? payload.title
    self.confidence = confidence
    self.reason = reason
    self.sourceLabel = sourceLabel
    self.sourceLinks = sourceLinks
  }

  /// What saving this draft would do now.
  var resolvedKind: CaptureDraftKind { chosenKind ?? kind }

  /// Only a draft that matched a task has two shapes to choose between.
  var matchesExistingTask: Bool { targetTaskID != nil }

  /// What saving would write. A new task always needs something to call it,
  /// even when the draft was only ever meant to amend a task that has a title.
  var resolvedPayload: SlackProposalPayload {
    guard resolvedKind == .create else { return payload }
    var resolved = payload
    resolved.title = payload.title ?? proposedTitle ?? fallbackTitle
    return resolved
  }

  private var fallbackTitle: String? {
    sourceLabel.isEmpty ? nil : "Follow up on \(sourceLabel)"
  }
}

/// Everything that turns fetched source material into a prompt and a response
/// back into drafts. No network and no credentials, so the judgement calls are
/// testable on their own.
enum CaptureCommandDrafter {
  static let maxSourceCharacters = 10_000
  static let candidateTaskLimit = 8
  /// A wider split means the model failed to find the common thread between the
  /// links, and one paste should not flood ActionHub.
  static let maxDrafts = 3

  // MARK: - Identifying a source

  /// The key the prompt and the response use to refer to a source. Stable and
  /// short, so a model cannot mangle it the way it can mangle a URL.
  static func key(for index: Int) -> String { "s\(index + 1)" }

  /// The tag that links a task back to where it came from. These match the tags
  /// the two background syncs already write, which is the whole basis of
  /// duplicate detection.
  static func originTag(for source: CaptureSource) -> String {
    switch source {
    case .slack(let excerpt):
      return SlackProposalPlanner.threadTag(
        channelID: excerpt.channelID,
        threadTS: SlackProposalPlanner.threadRoot(of: excerpt.anchor)
      )
    case .github(let snapshot):
      return snapshot.originTag
    }
  }

  static func providerTag(for source: CaptureSource) -> String {
    switch source {
    case .slack:
      return "slack"
    case .github:
      return snapshotProviderTag
    }
  }

  private static let snapshotProviderTag = "github"

  static func label(for source: CaptureSource) -> String {
    switch source {
    case .slack(let excerpt):
      return "#\(excerpt.channelName)"
    case .github(let snapshot):
      return snapshot.slug
    }
  }

  static func link(for source: CaptureSource) -> String? {
    switch source {
    case .slack(let excerpt):
      return excerpt.permalink
    case .github(let snapshot):
      return snapshot.htmlURL
    }
  }

  /// What the overlap scoring reads when no origin tag matched.
  static func searchText(for source: CaptureSource) -> String {
    switch source {
    case .slack(let excerpt):
      return excerpt.messages.map(\.text).joined(separator: " ")
    case .github(let snapshot):
      return [snapshot.title, snapshot.body ?? ""].joined(separator: " ")
    }
  }

  // MARK: - Finding a task this source already belongs to

  /// An exact origin-tag match wins outright — that task came from this very
  /// source, and a second one would be a duplicate. Word overlap is the weaker
  /// fallback for a task the user created by hand about the same work.
  static func candidates(
    for source: CaptureSource,
    tasks: [TaskEntity],
    limit: Int = candidateTaskLimit
  ) -> [TaskEntity] {
    let open = tasks.filter { !$0.completed }
    let tag = originTag(for: source)

    let linked = open.filter { $0.tags.contains(tag) }
    if !linked.isEmpty {
      return Array(linked.prefix(limit))
    }

    let sourceTokens = SlackProposalPlanner.tokens(in: searchText(for: source))
    guard !sourceTokens.isEmpty else { return [] }

    return open
      .compactMap { task -> (TaskEntity, Int)? in
        let overlap = SlackProposalPlanner.tokens(in: task.title)
          .union(SlackProposalPlanner.tokens(in: task.description ?? ""))
          .intersection(sourceTokens)
        return overlap.isEmpty ? nil : (task, overlap.count)
      }
      .sorted { ($0.1, $0.0.updatedAt) > ($1.1, $1.0.updatedAt) }
      .prefix(limit)
      .map(\.0)
  }

  /// True when this source is already tracked, which is what turns a repeated
  /// paste into an update rather than a second task.
  static func alreadyTracked(_ source: CaptureSource, in tasks: [TaskEntity]) -> TaskEntity? {
    let tag = originTag(for: source)
    return tasks.first { !$0.completed && $0.tags.contains(tag) }
  }

  // MARK: - Rendering the material

  static func render(source: CaptureSource, now: Date, budget: Int = maxSourceCharacters) -> String {
    switch source {
    case .slack(let excerpt):
      return renderSlack(excerpt, budget: budget)
    case .github(let snapshot):
      return renderGitHub(snapshot, budget: budget)
    }
  }

  private static func renderSlack(_ excerpt: SlackConversationExcerpt, budget: Int) -> String {
    var messages = excerpt.messages

    // Trim from the oldest end, never the anchor: the message the user linked
    // is the one thing the draft cannot be written without.
    while true {
      let text = slackText(excerpt, messages: messages)
      guard text.count > budget, messages.count > 1 else { return text }
      guard let oldest = messages.first(where: { $0.ts != excerpt.anchor.ts }) else { return text }
      messages.removeAll { $0.ts == oldest.ts }
    }
  }

  private static func slackText(_ excerpt: SlackConversationExcerpt, messages: [SlackMessage]) -> String {
    var lines = ["#\(excerpt.channelName) — \(messages.count) message\(messages.count == 1 ? "" : "s")"]

    for message in messages {
      let marker = message.ts == excerpt.anchor.ts ? ">" : " "
      let who = message.isOwn ? "\(message.authorName) (you)" : message.authorName
      let body = SlackProposalPlanner.clean(message.text, names: excerpt.names)
      lines.append("\(marker) \(who) (\(stamp(message.sentAt))): \(body)")
    }

    lines.append("The message marked > is the one the user linked.")
    return lines.joined(separator: "\n")
  }

  private static func renderGitHub(_ snapshot: GitHubPullSnapshot, budget: Int) -> String {
    var comments = snapshot.comments
    var includeFiles = true

    // A long review thread is what overflows the budget; thirty filenames are
    // barely a kilobyte, so the comments are what there is to reclaim. Shed the
    // review bots before any person, whatever the order they posted in — a bot
    // walkthrough is long by habit, and letting length decide would drop a
    // human's one-line ask to keep an automated summary of the diff.
    while true {
      let text = githubText(snapshot, comments: comments, includeFiles: includeFiles)
      if text.count <= budget { return text }
      if let next = shedding(comments) {
        comments = next
        continue
      }
      if includeFiles {
        includeFiles = false
        continue
      }
      return String(text.prefix(budget))
    }
  }

  /// Drops the oldest bot comment, or the oldest human once no bot is left.
  /// Returns nil when only one comment remains to drop.
  private static func shedding(_ comments: [GitHubCommentSummary]) -> [GitHubCommentSummary]? {
    guard comments.count > 1 else { return nil }

    let index = comments.firstIndex(where: \.isBot) ?? comments.startIndex
    var remaining = comments
    remaining.remove(at: index)
    return remaining
  }

  private static func githubText(
    _ snapshot: GitHubPullSnapshot,
    comments: [GitHubCommentSummary],
    includeFiles: Bool
  ) -> String {
    var lines: [String] = []

    var headline = ["\(snapshot.slug) \"\(snapshot.title)\" — \(snapshot.state)"]
    if snapshot.isDraft { headline.append("draft") }
    if snapshot.isMerged { headline.append("merged") }
    if snapshot.isPullRequest, snapshot.changedFileCount > 0 {
      headline.append("\(snapshot.changedFileCount) file\(snapshot.changedFileCount == 1 ? "" : "s") changed")
    }
    lines.append(headline.joined(separator: ", "))

    if let milestone = snapshot.milestoneTitle {
      let due = snapshot.milestoneDueOn.map { " (due \(stamp($0)))" } ?? ""
      lines.append("Milestone: \(milestone)\(due)")
    }
    if !snapshot.labels.isEmpty {
      lines.append("Labels: \(snapshot.labels.joined(separator: ", "))")
    }
    if !snapshot.assignees.isEmpty {
      lines.append("Assigned to: \(snapshot.assignees.joined(separator: ", "))")
    }
    if !snapshot.requestedReviewers.isEmpty {
      lines.append("Review requested from: \(snapshot.requestedReviewers.joined(separator: ", "))")
    }
    if let body = snapshot.body {
      lines.append("Description:\n\(body)")
    }

    let reviews = snapshot.reviews.sorted { !$0.isBot && $1.isBot }
    if !reviews.isEmpty {
      lines.append("Reviews:")
      for review in reviews {
        // A verdict with no words still matters — "changes requested" is the
        // signal, so the line stays even when the body strips to nothing.
        let note = readable(review.body, isBot: review.isBot).map { ": \($0)" } ?? ""
        let who = review.isBot ? "\(review.reviewer) (automated)" : review.reviewer
        lines.append("  \(who) — \(review.state)\(note)")
      }
    }

    let readableComments = comments
      .sorted { !$0.isBot && $1.isBot }
      .compactMap { comment -> (String, String)? in
        guard let body = readable(comment.body, isBot: comment.isBot) else { return nil }
        return (comment.isBot ? "\(comment.author) (automated)" : comment.author, body)
      }
    if !readableComments.isEmpty {
      lines.append("Comments:")
      for (who, body) in readableComments {
        lines.append("  \(who): \(body)")
      }
    }

    if includeFiles, !snapshot.changedFileNames.isEmpty {
      lines.append("Files changed: \(snapshot.changedFileNames.joined(separator: ", "))")
    }

    return lines.joined(separator: "\n")
  }

  // MARK: - Prompt

  static func systemPrompt() -> String {
    """
    You read the source material behind a link the user pasted — a Slack conversation, or a GitHub pull \
    request — and draft the task they want from it.

    Return one task unless the sources describe work that would be tracked separately anyway: different \
    repositories, unconnected asks, or different people waiting on different things. When in doubt, return \
    one task and put the separate pieces in its subtasks. Never return more than \(maxDrafts) tasks.

    Each task is either:
    - "create" — new work, which is the normal case.
    - "update" — the source is already tracked by one of the candidate tasks. Set targetTaskId to that \
    task's id, taken from the candidate list, and fill in only the fields the source actually changes.

    Rules:
    - The user's own words outrank the source material on every field they touch. They wrote them because \
    the source does not say them.
    - Set dueDate only when there is evidence for one: a date in the user's words, a date stated in the \
    source, or a milestone due date. Otherwise return null. Never derive a deadline from how urgent the \
    work sounds, and never invent one because a review "should be quick".
    - Every date is absolute ISO-8601 (yyyy-MM-dd), resolved against today's date, which is given below. \
    Never return a relative phrase.
    - The title is short and imperative: "Handle the null case in the retry wrapper", not "PR 812 review".
    - The description carries what someone would need to act without opening the link: what is being \
    asked, by whom, and what is blocking. Include every source link verbatim.
    - Subtasks come from distinct asks that are actually present in the source — review comments to \
    address, questions to answer, files to change. Do not invent scaffolding like "write tests" unless \
    somebody asked for it.
    - statusChange is "completed" only when the source says the work is done, "reopened" when finished \
    work is reported broken, otherwise "none".
    - sourceKeys lists the source keys this task covers, using the keys exactly as written below.
    - confidence is your own estimate from 0 to 1 that this draft is right and would be accepted as-is.
    - reason is one short sentence naming the evidence, shown to the user next to the draft.
    """
  }

  static func userPrompt(
    sources: [CaptureSource],
    context: String,
    candidates: [String: [TaskEntity]],
    projects: [AIQuickCaptureProjectContext],
    availableTags: [String],
    now: Date
  ) -> String {
    var sections = ["Today is \(stamp(now))."]

    let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
    sections.append(
      trimmedContext.isEmpty
        ? "The user added no words of their own — the source material is all there is."
        : "The user's own words, which outrank the source material:\n\(trimmedContext)"
    )

    let allCandidates = sources.indices
      .flatMap { candidates[key(for: $0)] ?? [] }
      .reduce(into: [String: TaskEntity]()) { $0[$1.id] = $1 }

    if allCandidates.isEmpty {
      sections.append("Candidate tasks: none — every task here is a create.")
    } else {
      let rendered = allCandidates.values
        .sorted { $0.updatedAt > $1.updatedAt }
        .map { task in
          var parts = ["[\(task.id)] \"\(task.title)\""]
          if let dueDate = task.dueDate {
            parts.append("due \(stamp(dueDate))")
          }
          parts.append("priority \(task.priority.rawValue)")
          if let projectID = task.projectId,
             let project = projects.first(where: { $0.id == projectID }) {
            parts.append("project \(project.name)")
          }
          if !task.subtasks.isEmpty {
            parts.append("\(task.subtasks.count) subtask\(task.subtasks.count == 1 ? "" : "s")")
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

    for (index, source) in sources.enumerated() {
      var block = ["--- source \(key(for: index)) (\(label(for: source))) ---"]
      block.append(render(source: source, now: now))
      if let link = link(for: source) {
        block.append("Link: \(link)")
      }
      let ids = (candidates[key(for: index)] ?? []).map(\.id)
      block.append(
        ids.isEmpty
          ? "Already tracked by: nothing"
          : "Candidate tasks for this source: \(ids.joined(separator: ", "))"
      )
      sections.append(block.joined(separator: "\n"))
    }

    return sections.joined(separator: "\n\n")
  }

  static func schema() -> [String: Any] {
    [
      "title": "capture_drafts",
      "type": "object",
      "additionalProperties": false,
      "required": ["tasks"],
      "properties": [
        "tasks": [
          "type": "array",
          "items": [
            "type": "object",
            "additionalProperties": false,
            "required": [
              "sourceKeys", "action", "targetTaskId", "title", "description", "priority",
              "dueDate", "projectId", "projectName", "tags", "subtasks", "statusChange",
              "confidence", "reason",
            ],
            "properties": [
              "sourceKeys": ["type": "array", "items": ["type": "string"]],
              "action": ["type": "string", "enum": ["create", "update"]],
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

  // MARK: - Tagging what comes back

  /// Applies the origin tags for whichever sources a draft covers. Without
  /// these a repeated paste has nothing to match against and duplicates.
  static func tagged(
    _ draft: CaptureDraft,
    sources: [CaptureSource],
    coveringKeys keys: [String]
  ) -> CaptureDraft {
    var draft = draft
    let covered = sources.indices.filter { keys.contains(key(for: $0)) }
    let indices = covered.isEmpty ? Array(sources.indices) : covered

    var tags = draft.payload.tags
    var links: [String] = []
    for index in indices {
      let source = sources[index]
      for tag in [providerTag(for: source), originTag(for: source)] where !tags.contains(tag) {
        tags.append(tag)
      }
      if let link = link(for: source) {
        links.append(link)
      }
    }

    draft.payload.tags = tags
    draft.sourceLabel = indices.map { label(for: sources[$0]) }.joined(separator: ", ")
    draft.sourceLinks = links
    return draft
  }

  /// One source that already has a task, drafted as a create anyway, is the
  /// duplicate this feature exists to avoid. Redirect it at the task it belongs
  /// to rather than writing a second one.
  static func redirectingDuplicates(
    _ drafts: [CaptureDraft],
    sources: [CaptureSource],
    tasks: [TaskEntity]
  ) -> [CaptureDraft] {
    let trackedByTag = sources.reduce(into: [String: TaskEntity]()) { result, source in
      if let task = alreadyTracked(source, in: tasks) {
        result[originTag(for: source)] = task
      }
    }
    guard !trackedByTag.isEmpty else { return drafts }

    return drafts.map { draft in
      guard draft.kind == .create else { return draft }
      guard let existing = draft.payload.tags.compactMap({ trackedByTag[$0] }).first else { return draft }

      var redirected = draft
      redirected.kind = .update
      redirected.targetTaskID = existing.id
      // A create's title describes the work; retitling a task the user already
      // has is not what they asked for by pasting the link again. The title
      // stays on `proposedTitle` in case the match turns out to be wrong.
      redirected.payload.title = nil
      return redirected
    }
  }

  /// Review bots bracket their output with HTML markers the reader never sees
  /// on GitHub — `<!-- ENTELLIGENCE_WALKTHROUGH -->` and the like — which
  /// otherwise arrive as prompt text. Applied to bots only: an HTML comment a
  /// person wrote, in a body or a review, they wrote on purpose.
  static func readable(_ text: String?, isBot: Bool) -> String? {
    guard let text else { return nil }
    guard isBot else { return text.nilIfEmpty }

    return text
      .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty
  }

  static func stamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE d MMM yyyy"
    return formatter.string(from: date)
  }
}

/// The drafts a command produced, held until the user saves or discards them.
/// The typed line travels with them so a near-miss can be re-run with one word
/// changed instead of re-pasted.
struct CaptureDraftPreview: Equatable, Sendable {
  var typedText: String
  var kind: CaptureCommandKind
  var drafts: [CaptureDraft]
  var draftedByModel: Bool
}
