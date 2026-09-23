import Foundation

/// One labelled part of the stand-up — a priority, a blocker, a heading the
/// person's own format asked for. Structure the model reports rather than
/// punctuation the app has to guess at, so the screen can draw it.
struct StandupSection: Equatable, Sendable {
  /// The short tag in front: "P0", "Blockers", "Since Friday". May be empty
  /// when a format wants a heading and nothing to file it under.
  var label: String
  var title: String
  var body: String

  init(label: String, title: String, body: String) {
    self.label = label
    self.title = title
    self.body = body
  }

  /// What this part looks like in a Slack thread.
  var markdown: String {
    let heading = [label.nilIfEmpty, title.nilIfEmpty]
      .compactMap { $0 }
      .joined(separator: " \u{00B7} ")
    guard let heading = heading.nilIfEmpty else { return body }
    return body.isEmpty ? "**\(heading)**" : "**\(heading)**\n\(body)"
  }
}

/// The finished stand-up in every shape it is needed in. Same facts three
/// ways: one to read out, one to paste into a thread, one the screen can lay
/// out as parts.
struct StandupScript: Equatable, Sendable {
  var spoken: String
  var paste: String
  /// Empty when the model gave no structure, or when an older stand-up was
  /// written before it did — the screen falls back to the plain text.
  var sections: [StandupSection]
  /// Specifics the spoken version compressed out, kept one glance away for the
  /// follow-up question.
  var folded: [String]

  init(spoken: String, paste: String, sections: [StandupSection] = [], folded: [String]) {
    self.spoken = spoken
    self.paste = paste
    self.sections = sections
    self.folded = folded
  }

  static func paste(from sections: [StandupSection]) -> String {
    sections.map(\.markdown).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var wordCount: Int {
    spoken.split { $0 == " " || $0.isNewline }.count
  }

  /// Spoken English runs about 130 words a minute.
  var spokenSeconds: Int {
    max(Int((Double(wordCount) / 130.0 * 60.0).rounded()), 1)
  }
}

/// A starting point for the format instruction. These are text you edit, not
/// modes you switch between — the whole point is that a team's stand-up drifts
/// and the instruction has to drift with it.
struct StandupFormatPreset: Identifiable, Equatable, Sendable {
  var id: String
  var title: String
  var instruction: String
}

/// Turns a confirmed board into a prompt, and a model response back into a
/// script. No network and no credentials, so the wording rules and the
/// no-key fallback are testable on their own.
enum StandupWriter {
  static let presets: [StandupFormatPreset] = [
    StandupFormatPreset(
      id: "classic",
      title: "Classic three-part",
      instruction: AISettingsEntity.defaultStandupFormat
    ),
    StandupFormatPreset(
      id: "projects",
      title: "Project by project",
      instruction: """
        Group everything by project rather than by time. Under each project say where it stands and what \
        happens next. Mention a blocker inside the project it belongs to, not in a separate section.
        """
    ),
    StandupFormatPreset(
      id: "async",
      title: "Async Slack post",
      instruction: """
        Write it as a short post rather than something spoken: three bold headings — Yesterday, Today, \
        Blockers — with one bullet per item. Keep bullets under fifteen words. Put any link on the item \
        it belongs to.
        """
    ),
    StandupFormatPreset(
      id: "blockers-first",
      title: "Blockers first",
      instruction: """
        Lead with what I need from the team, then what I'm on today, then what landed. If nothing is \
        blocked, say so in three words and move on.
        """
    ),
    StandupFormatPreset(
      id: "terse",
      title: "Terse",
      instruction: """
        As few words as will carry the facts. No preamble, no "just" or "quickly", no sign-off. Fragments \
        are fine. Keep every number and identifier.
        """
    ),
  ]

  /// The handful of changes people ask for most, one tap away. Deliberately
  /// short: a chip that needs reading is slower than typing the ask.
  static let reviseSuggestions = ["Shorter", "More detail", "No links", "Plainer words"]

  // MARK: - Prompt

  /// How much of a task's own material a prompt carries. A stand-up runs to a
  /// handful of tasks, so these are generous per item and still bounded in
  /// total; anything dropped is counted out loud rather than silently cut.
  static let descriptionLimit = 400
  static let subtaskTitleLimit = 120
  static let commentTextLimit = 280
  static let subtaskListLimit = 12
  static let commentListLimit = 5

  // MARK: - System

  static func systemPrompt() -> String {
    """
    You write one person's daily stand-up, from facts they have already confirmed.

    You are given three groups — what has happened since their last stand-up, what they are on today, and \
    what they are blocked on — and a format instruction written by the person whose stand-up this is.

    Rules that hold whatever the format says:
    - Use only the facts given. Never invent a task, a number, a name, a date or a reason.
    - Keep every number, identifier, PR reference, path and date in "sections". That written version is \
    what people scroll back to, and those are the parts they ask follow-up questions about.
    - An item marked "guessed" is Serenity's inference, not something the person said. Voice it as \
    uncertainty ("nothing has moved on X for four days") or leave it out. Never assert it as fact.
    - An item that carries "said last time" was already mentioned. Say where it got to since. Do not \
    repeat the earlier phrasing.
    - An item may carry labelled detail indented under it: "Description" is what the task says about \
    itself, "Subtasks" lists each one with its status in brackets, and "Comments" are the person's own \
    words with the date they wrote them. That is where the specifics live — take the wording from there \
    rather than restating the one-line fact.
    - A subtask marked [not done] is outstanding; never report it as finished, and never treat a done \
    subtask as today's work. A comment may be quoted or paraphrased but not contradicted, and an old one \
    is old — its date is given, so do not present it as today's news.
    - Spend the length target on that detail. A longer target means more specifics per item, not more \
    words around the same sentence.
    - "sections" is the stand-up broken into its parts, in the order they should be read. Each part has a \
    "label" (the short tag in front: "P0", "Blockers", "Since Friday" — whatever the format instruction \
    calls for, empty if it calls for none), a "title" (the subject in a few words) and a "body" (the \
    detail, one or two sentences). The format instruction decides what the parts are and what they are \
    called; do not impose a structure it did not ask for.
    - "spoken" is said out loud to a room of engineers and product managers who are listening, not \
    reading. It has to survive being heard once. Full sentences, contractions, one idea per sentence, a \
    blank line between one part and the next.
    - Nothing in "spoken" may be a thing nobody would say out loud. No markdown, no asterisks, no \
    backticks, no bullet characters, no headings, no numbered lists. No URL, no file path, no branch, \
    no function or module name, no random-looking id. Name the thing in words instead: "the CRM owner \
    matching code", "the Slack thread about it", "the account-domain fallback". Numbers a person would \
    actually say — a count, a ticket or PR number, a day, a duration — stay.
    - Say each part's label in "spoken" the way a person says it, not the way it is written: "First, and \
    the one that has to land today", "P zero", "On the blockers". Never read out a heading or a bullet.
    - A list of things in "spoken" becomes a sentence: "three things left on it — the account-domain \
    fallback, the Thryv case, and making sure duration is not the only trigger". Never more than about \
    four in one breath; past that, say how many there are and name the ones that matter.
    - "folded" holds every specific "spoken" left out, one per entry: each URL, each path, each identifier \
    you put into words. That is what answers "what was the link again?" when somebody asks. If you left \
    nothing out, return an empty array.
    - Where the format instruction and the length target disagree, the format instruction wins.
    - The format instruction never overrides the rules for "spoken". When it asks for links, headings, \
    bullets or markdown, those go in "sections"; "spoken" keeps the order and emphasis it asks for, in \
    words a person can say.
    """
  }

  static func userPrompt(
    board: StandupBoard,
    instruction: String,
    length: StandupLength,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> String {
    var lines: [String] = []

    lines.append("Today is \(now.formatted(.dateTime.weekday(.wide).day().month(.wide).year())).")
    lines.append(
      "The window runs from \(stamp(board.window.start, calendar: calendar)) to now\(windowNote(board.window))."
    )
    lines.append("Aim for about \(length.wordTarget) words in \"spoken\".")
    lines.append("")
    lines.append("The person's format instruction:")
    lines.append("<<<FORMAT")
    lines.append(instruction.trimmingCharacters(in: .whitespacesAndNewlines))
    lines.append("FORMAT")
    lines.append("")

    for column in StandupColumn.spoken {
      let cards = board.cards(in: column)
      lines.append("\(heading(for: column, window: board.window, now: now, calendar: calendar)):")
      if cards.isEmpty {
        lines.append("- (nothing)")
      } else {
        for card in cards {
          lines.append("- \(describe(card))")
          lines.append(
            contentsOf: detailLines(for: card, now: now, calendar: calendar).map { "  \($0)" }
          )
        }
      }
      lines.append("")
    }

    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Revising is deliberately not a re-write: the model is given the same
  /// confirmed facts, the script it already produced, and the change asked
  /// for. Handing it only the ask would let each pass drift a little further
  /// from what the board actually says.
  static func reviseSystemPrompt() -> String {
    """
    \(systemPrompt())

    You are revising a stand-up you already wrote, because the person asked for a change.

    - Make the change they asked for and leave everything else alone. Same parts, same order, same wording, \
    except where the change requires otherwise.
    - The change cannot introduce a fact. If they ask for something the facts do not support, keep the \
    script truthful and leave that part as it was.
    - Return the whole stand-up in the same shape, not a description of what you changed.
    """
  }

  static func revisePrompt(
    board: StandupBoard,
    instruction: String,
    length: StandupLength,
    script: StandupScript,
    ask: String,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> String {
    """
    \(userPrompt(board: board, instruction: instruction, length: length, now: now, calendar: calendar))

    The stand-up you wrote:
    <<<CURRENT
    \(StandupScript.paste(from: script.sections).nilIfEmpty ?? script.paste)
    CURRENT

    What you wrote to be said out loud:
    <<<SPOKEN
    \(script.spoken.trimmingCharacters(in: .whitespacesAndNewlines))
    SPOKEN

    The specifics you folded out of it:
    \(script.folded.isEmpty ? "(none)" : script.folded.map { "- \($0)" }.joined(separator: "\n"))

    What they want changed:
    <<<CHANGE
    \(ask.trimmingCharacters(in: .whitespacesAndNewlines))
    CHANGE
    """
  }

  private static func heading(
    for column: StandupColumn,
    window: StandupWindow,
    now: Date,
    calendar: Calendar
  ) -> String {
    switch column {
    case .since:
      return StandupDateText.windowLabel(window, now: now, calendar: calendar)
    case .today:
      return "Today"
    case .blocked:
      return "Blocked on"
    case .leftOut:
      return "Leaving out"
    }
  }

  private static func describe(_ card: StandupCard) -> String {
    var parts = ["\(card.title) — \(card.fact)"]

    if card.source.isGuess {
      parts.append("[guessed]")
    }
    if card.source == .manual {
      parts.append("[they typed this]")
    }
    if let saidLast = card.saidLast {
      parts.append("[said last time: \(saidLast)]")
    }

    return parts.joined(separator: " ")
  }

  /// The task's own material, under labels. A model told which lines are
  /// subtasks and which are comments can name a specific one; the same text run
  /// together reads as a single vague sentence, which is how a detailed
  /// stand-up ends up sounding exactly like a short one.
  private static func detailLines(for card: StandupCard, now: Date, calendar: Calendar) -> [String] {
    guard !card.detail.isEmpty else { return [] }
    var lines: [String] = []

    if let description = card.detail.description {
      lines.append("Description: \(clip(description, to: descriptionLimit))")
    }

    let subtasks = card.detail.subtasks
    if !subtasks.isEmpty {
      let done = subtasks.filter(\.completed).count
      lines.append("Subtasks (\(done) of \(subtasks.count) done):")
      for subtask in subtasks.prefix(subtaskListLimit) {
        let status = subtask.completed ? "done" : "not done"
        lines.append("  - [\(status)] \(clip(subtask.title, to: subtaskTitleLimit))")
      }
      if subtasks.count > subtaskListLimit {
        lines.append("  - (\(subtasks.count - subtaskListLimit) more, not listed)")
      }
    }

    let comments = card.detail.comments
    if !comments.isEmpty {
      let shown = comments.suffix(commentListLimit)
      let older = comments.count - shown.count
      let note = older > 0 ? ", \(older) older not listed" : ""
      lines.append("Comments they wrote (oldest first\(note)):")
      for comment in shown {
        let stamp = StandupDateText.dayAndTime(comment.writtenAt, now: now, calendar: calendar)
        lines.append("  - \(stamp): \u{201C}\(clip(comment.text, to: commentTextLimit))\u{201D}")
      }
    }

    return lines
  }

  /// Newlines are flattened rather than kept: the block is read by line, and a
  /// wrapped description would otherwise look like a new label.
  private static func clip(_ text: String, to limit: Int) -> String {
    let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n", with: " ")
    guard flat.count > limit else { return flat }
    return flat.prefix(limit).trimmingCharacters(in: .whitespaces) + "\u{2026}"
  }

  private static func windowNote(_ window: StandupWindow) -> String {
    switch window.anchor {
    case .lastStandup, .sameDay:
      return " (their last stand-up)"
    case .previousWorkingDay:
      return " (their previous working day — this is their first stand-up here)"
    case .capped:
      return " (capped; their last stand-up was longer ago than that)"
    }
  }

  private static func stamp(_ date: Date, calendar: Calendar) -> String {
    date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).hour().minute())
  }

  // MARK: - Schema and decoding

  static func schema() -> [String: Any] {
    [
      "title": "standup_script",
      "type": "object",
      "additionalProperties": false,
      "required": ["spoken", "sections", "folded"],
      "properties": [
        "spoken": ["type": "string"],
        "sections": [
          "type": "array",
          "items": [
            "type": "object",
            "additionalProperties": false,
            "required": ["label", "title", "body"],
            "properties": [
              "label": ["type": "string"],
              "title": ["type": "string"],
              "body": ["type": "string"],
            ],
          ],
        ],
        "folded": ["type": "array", "items": ["type": "string"]],
      ],
    ]
  }

  private struct Payload: Decodable {
    struct Section: Decodable {
      let label: String?
      let title: String?
      let body: String?
    }

    let spoken: String
    let paste: String?
    let sections: [Section]?
    let folded: [String]?
  }

  static func decode(_ text: String) throws -> StandupScript {
    let json = extractJSONObject(from: text)
    guard let data = json.data(using: .utf8) else {
      throw AIWorkflowError.invalidStandupResponse("Stand-up response was not UTF-8.")
    }

    let payload = try JSONDecoder().decode(Payload.self, from: data)
    let spoken = payload.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !spoken.isEmpty else {
      throw AIWorkflowError.invalidStandupResponse("Stand-up response had no spoken text.")
    }

    let sections = (payload.sections ?? []).compactMap { section -> StandupSection? in
      let built = StandupSection(
        label: section.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        title: section.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        body: section.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      )
      return built.markdown.isEmpty ? nil : built
    }

    // The pasteable text is built here rather than asked for: it has to match
    // what the screen draws, and a model asked for the same content twice
    // eventually returns two different versions of it.
    let paste = sections.isEmpty
      ? payload.paste?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? spoken
      : StandupScript.paste(from: sections)

    return StandupScript(
      spoken: spoken,
      paste: paste,
      sections: sections,
      folded: (payload.folded ?? []).compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    )
  }

  // MARK: - Can it actually be said

  /// What in the spoken text could not be read to a room, in words the model
  /// can act on. Checked here rather than left to the prompt: "no links, no
  /// paths, no markdown" is the rule a model quietly drops when the person's
  /// own format instruction is a bulleted outline, and the cost of being
  /// wrong is somebody standing in front of their team reading out a URL.
  static func speechProblems(in spoken: String) -> [String] {
    var problems: [String] = []

    func matches(_ pattern: String, _ options: NSString.CompareOptions = [.regularExpression]) -> Bool {
      spoken.range(of: pattern, options: options) != nil
    }

    if spoken.contains("**") || spoken.contains("`") || spoken.contains("\u{2022}") {
      problems.append(
        "\"spoken\" still contains markdown or bullet characters. It is read aloud: plain sentences only."
      )
    }
    if matches("(?m)^\\s*([-*+]|\\d+\\.)\\s") {
      problems.append(
        "\"spoken\" is written as a list. Turn each part into sentences somebody can say in one breath."
      )
    }
    if matches("(?m)^#{1,6}\\s") {
      problems.append("\"spoken\" contains a heading. Say the label as a person would instead.")
    }
    if matches("https?://|www\\.", [.regularExpression, .caseInsensitive]) {
      problems.append(
        "\"spoken\" contains a link. Nobody can say a URL out loud: name it in words and put the URL in \"folded\"."
      )
    }
    if matches("[\\w.-]+/[\\w./-]*\\.\\w{1,4}\\b") {
      problems.append(
        "\"spoken\" contains a file path. Say what that code does instead and put the path in \"folded\"."
      )
    }
    // An id nobody would read out: six or more characters, upper case, with a
    // digit in it — a Slack message id, a channel id, a commit.
    if matches("\\b(?=[A-Z0-9]{6,}\\b)(?=[^\\s]*\\d)[A-Z0-9]+\\b") {
      problems.append(
        "\"spoken\" contains an identifier nobody would say out loud. Describe it in words and put the id in \"folded\"."
      )
    }

    return problems
  }

  /// Models occasionally wrap the object in prose or a fenced block. Same
  /// tolerance the capture path already applies.
  private static func extractJSONObject(from text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end else {
      return trimmed
    }
    return String(trimmed[start...end])
  }

  // MARK: - Without a key

  /// What the screen shows when no provider is configured. Not a good
  /// stand-up, but an honest one — every confirmed fact, in order, in a shape
  /// you can read out.
  static func fallback(
    board: StandupBoard,
    length: StandupLength,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> StandupScript {
    var spokenParts: [String] = []
    var sections: [StandupSection] = []
    var folded: [String] = []

    for column in StandupColumn.spoken {
      let cards = board.cards(in: column)
      guard !cards.isEmpty else { continue }

      let heading = heading(for: column, window: board.window, now: now, calendar: calendar)

      var titles: [String] = []
      var lines: [String] = []
      for card in cards {
        lines.append("- \(card.title) — \(card.fact)")
        titles.append(card.title)
        // Nothing here can rewrite a fact into a clause, so the detail that a
        // model would have folded in is surfaced rather than dropped.
        folded.append("\(card.title): \(card.fact)")
      }

      sections.append(StandupSection(label: heading, title: "", body: lines.joined(separator: "\n")))
      spokenParts.append("\(spokenLead(for: column, heading: heading)) \(sentenceList(titles)).")
    }

    let spoken = spokenParts.isEmpty
      ? "Nothing to report since the last stand-up."
      : spokenParts.joined(separator: "\n\n")

    return StandupScript(
      spoken: spoken,
      paste: StandupScript.paste(from: sections),
      sections: sections,
      folded: folded
    )
  }

  private static func spokenLead(for column: StandupColumn, heading: String) -> String {
    switch column {
    case .since:
      return "\(heading):"
    case .today:
      return "Today I'm on"
    case .blocked:
      return "I'm blocked on"
    case .leftOut:
      return heading
    }
  }

  private static func sentenceList(_ items: [String]) -> String {
    switch items.count {
    case 0:
      return ""
    case 1:
      return items[0]
    case 2:
      return "\(items[0]) and \(items[1])"
    default:
      return "\(items.dropLast().joined(separator: ", ")), and \(items[items.count - 1])"
    }
  }
}

/// A written stand-up plus what it cost and who wrote it, before it is stored.
struct StandupDraft: Equatable, Sendable {
  var script: StandupScript
  var writtenByModel: Bool
  var provider: AIProvider
  var promptTokens: Int
  var completionTokens: Int

  var totalTokens: Int { promptTokens + completionTokens }
}
