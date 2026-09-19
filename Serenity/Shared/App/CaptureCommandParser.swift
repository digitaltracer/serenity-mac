import Foundation

enum CaptureCommandKind: String, Equatable, Sendable, CaseIterable {
  case slack
  case github

  var token: String { "/\(rawValue)" }
}

/// A Slack conversation named by a permalink. `threadRootTS` is what gets
/// fetched; `linkedTS` remembers which message the user actually pointed at, so
/// a draft can say which reply it came from.
struct SlackConversationReference: Equatable, Sendable {
  var channelID: String
  var threadRootTS: String
  var linkedTS: String
  var workspaceHost: String
}

struct GitHubPullReference: Equatable, Sendable {
  var owner: String
  var repo: String
  var number: Int
  var isPullRequest: Bool

  var slug: String { "\(owner)/\(repo)#\(number)" }
}

enum CaptureReference: Equatable, Sendable {
  case slack(SlackConversationReference)
  case github(GitHubPullReference)
}

/// One `/slack` or `/github` line, split into what to fetch and what the user
/// said about it. The user's own words outrank the fetched material on every
/// field they touch, so they travel separately rather than folded into a prompt.
struct CaptureCommand: Equatable, Sendable {
  var kind: CaptureCommandKind
  var references: [CaptureReference]
  var context: String
}

enum CaptureCommandParseError: Error, Equatable {
  case noLinks(CaptureCommandKind)
  case directMessage
  case channelWithoutMessage
  case enterpriseHost(String)
  case wrongProvider(expected: CaptureCommandKind)
  case tooManyLinks(limit: Int)
  case malformedLink(String)
}

extension CaptureCommandParseError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .noLinks(.slack):
      return "Add a Slack message link after /slack — use \"Copy link\" on the message."
    case .noLinks(.github):
      return "Add a pull request link after /github."
    case .directMessage:
      return "Serenity cannot read Slack DMs — it never asks Slack for access to them. Point it at a channel message instead."
    case .channelWithoutMessage:
      return "That link points at a channel, not a message. Open the message and use \"Copy link\"."
    case .enterpriseHost(let host):
      return "Serenity reads pull requests from github.com only, not \(host)."
    case .wrongProvider(.slack):
      return "/slack expects a Slack message link. Use /github for pull requests."
    case .wrongProvider(.github):
      return "/github expects a pull request link. Use /slack for a Slack conversation."
    case .tooManyLinks(let limit):
      return "One command can carry up to \(limit) links."
    case .malformedLink(let link):
      return "Could not read that link: \(link)"
    }
  }
}

/// Turns a Home-input line into something fetchable, before anything touches
/// the network. Everything here is pure, which makes it the cheapest place in
/// the feature to buy confidence — and the only place that can refuse a link
/// for free.
enum CaptureCommandParser {
  static let referenceLimit = 5

  /// Returns `nil` for any line that is not a command, so plain text and the
  /// existing `journal:` prefix fall through to their own handling untouched.
  /// Throws only when the line *was* a command and could not be honoured.
  static func parse(_ text: String) throws -> CaptureCommand? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let (kind, remainder) = splitCommandWord(trimmed) else { return nil }

    var references: [CaptureReference] = []
    var contextWords: [String] = []
    var foreignLinks = 0

    for token in remainder.split(whereSeparator: \.isWhitespace).map(String.init) {
      guard let url = url(from: token) else {
        contextWords.append(token)
        continue
      }

      let detected = provider(of: url)
      if detected == kind {
        references.append(try reference(from: url, kind: kind))
      } else {
        // A link to the other provider is only a mistake when it is the only
        // link on the line. Mid-sentence it is far likelier to be something the
        // user wants the draft to mention, so it stays in the context.
        if detected != nil { foreignLinks += 1 }
        contextWords.append(token)
      }
    }

    guard !references.isEmpty else {
      throw foreignLinks > 0
        ? CaptureCommandParseError.wrongProvider(expected: kind)
        : CaptureCommandParseError.noLinks(kind)
    }
    guard references.count <= referenceLimit else {
      throw CaptureCommandParseError.tooManyLinks(limit: referenceLimit)
    }

    return CaptureCommand(
      kind: kind,
      references: references,
      context: contextWords.joined(separator: " ")
    )
  }

  private static func splitCommandWord(_ text: String) -> (CaptureCommandKind, Substring)? {
    for kind in CaptureCommandKind.allCases {
      let token = kind.token
      guard text.count >= token.count, text.prefix(token.count).lowercased() == token else { continue }

      let remainder = text.dropFirst(token.count)
      guard let next = remainder.first else { return (kind, remainder) }
      guard next.isWhitespace else { continue }
      return (kind, remainder)
    }
    return nil
  }

  private static let wrappers: [(open: Character, close: Character)] = [
    ("<", ">"), ("(", ")"), ("[", "]"),
  ]

  /// A link pasted mid-sentence picks up the sentence's punctuation, and Slack
  /// wraps copied URLs in angle brackets. Both would otherwise make the whole
  /// token fail to parse as a URL and silently become context.
  private static func url(from token: String) -> URL? {
    var candidate = token
    for wrapper in wrappers
    where candidate.first == wrapper.open && candidate.last == wrapper.close && candidate.count > 2 {
      candidate = String(candidate.dropFirst().dropLast())
    }
    while let last = candidate.last,
          ".,;:!?".contains(last) || (last == ")" && !candidate.contains("(")) {
      candidate = String(candidate.dropLast())
    }

    guard
      let url = URL(string: candidate),
      let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http",
      url.host != nil
    else {
      return nil
    }
    return url
  }

  private static func provider(of url: URL) -> CaptureCommandKind? {
    guard let host = url.host?.lowercased() else { return nil }
    if host == "slack.com" || host.hasSuffix(".slack.com") { return .slack }
    if host == "github.com" || host == "www.github.com" { return .github }
    // An Enterprise host is claimed as GitHub deliberately: it is what lets the
    // refusal name the limitation instead of saying "that is not a link".
    if host.contains("github") { return .github }
    return nil
  }

  private static func reference(from url: URL, kind: CaptureCommandKind) throws -> CaptureReference {
    switch kind {
    case .slack:
      return try slackReference(from: url)
    case .github:
      return try githubReference(from: url)
    }
  }

  private static func slackReference(from url: URL) throws -> CaptureReference {
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count >= 2, parts[0].lowercased() == "archives", let kindLetter = parts[1].first else {
      throw CaptureCommandParseError.malformedLink(url.absoluteString)
    }

    // The token never requests `im:history`, so a DM could only ever come back
    // as `missing_scope` — which reads as a bug in the app rather than a
    // deliberate limit.
    guard kindLetter != "D" else { throw CaptureCommandParseError.directMessage }
    guard parts.count >= 3 else { throw CaptureCommandParseError.channelWithoutMessage }

    let compact = parts[2]
    guard compact.hasPrefix("p"), let linkedTS = timestamp(fromCompact: String(compact.dropFirst())) else {
      throw CaptureCommandParseError.malformedLink(url.absoluteString)
    }

    let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    let threadTS = queryItems?
      .first { $0.name == "thread_ts" }
      .flatMap(\.value)
      .flatMap(normalizedTimestamp)

    return .slack(
      SlackConversationReference(
        channelID: parts[1],
        // A link carrying `thread_ts` points at a *reply*. Rooting the fetch at
        // the path's own timestamp instead returns a thread of one message.
        threadRootTS: threadTS ?? linkedTS,
        linkedTS: linkedTS,
        workspaceHost: url.host ?? ""
      )
    )
  }

  private static func githubReference(from url: URL) throws -> CaptureReference {
    guard let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else {
      throw CaptureCommandParseError.enterpriseHost(url.host ?? "that host")
    }

    // Everything past the number — `/files`, `#discussion_r…`, a review query —
    // names a place inside the pull request, not a different one.
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count >= 4 else {
      throw CaptureCommandParseError.malformedLink(url.absoluteString)
    }

    let segment = parts[2].lowercased()
    guard segment == "pull" || segment == "pulls" || segment == "issues",
          let number = Int(parts[3]), number > 0
    else {
      throw CaptureCommandParseError.malformedLink(url.absoluteString)
    }

    return .github(
      GitHubPullReference(
        owner: parts[0],
        repo: parts[1],
        number: number,
        isPullRequest: segment != "issues"
      )
    )
  }

  /// `p1726742400123456` is a Slack timestamp with its decimal point removed,
  /// so recovering it means putting the point back six digits from the right.
  /// This is the inverse of `SlackMessage.permalink`.
  private static func timestamp(fromCompact digits: String) -> String? {
    guard digits.count > 6, digits.allSatisfy(\.isNumber) else { return nil }
    let split = digits.index(digits.endIndex, offsetBy: -6)
    return "\(digits[..<split]).\(digits[split...])"
  }

  /// `thread_ts` arrives already dotted. Validating it matters because it is
  /// fed straight back to Slack as the thread to read.
  private static func normalizedTimestamp(_ raw: String) -> String? {
    let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2,
          !parts[0].isEmpty,
          !parts[1].isEmpty,
          parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
    else {
      return nil
    }
    return raw
  }
}

/// What the Home card shows while a command is in flight. These take seconds,
/// not milliseconds, and a silent pause after a paste reads as a hang.
enum CaptureCommandProgress: Equatable, Sendable {
  case reading(String)
  case drafting

  var message: String {
    switch self {
    case .reading(let label):
      return "Reading \(label)…"
    case .drafting:
      return "Drafting the task…"
    }
  }
}

/// Failures that belong to the command rather than to the provider — the user
/// has not connected the thing they just asked Serenity to read.
enum CaptureCommandError: Error, Equatable, LocalizedError {
  case slackNotConnected
  case githubNotConnected

  var errorDescription: String? {
    switch self {
    case .slackNotConnected:
      return "Connect Slack in Integrations first."
    case .githubNotConnected:
      return "Add a GitHub token in Integrations first."
    }
  }
}
