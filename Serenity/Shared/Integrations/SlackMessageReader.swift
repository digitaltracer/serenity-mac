import Foundation

/// One Slack message, flattened into what the rest of the pipeline needs. Slack
/// timestamps stay strings because they double as message identifiers and any
/// round trip through `Double` risks losing the microsecond suffix.
struct SlackMessage: Equatable, Sendable, Identifiable {
  var channelID: String
  var channelName: String
  var ts: String
  var threadTS: String?
  var userID: String
  var authorName: String
  var text: String
  var isOwn: Bool
  var isBot: Bool
  var subtype: String?
  var permalink: String?

  var id: String { "\(channelID):\(ts)" }

  var sentAt: Date {
    Date(timeIntervalSince1970: Double(ts.split(separator: ".").first.map(String.init) ?? "") ?? 0)
  }
}

/// Slack timestamps are decimal strings. Comparing them lexicographically
/// happens to work while the epoch stays ten digits wide, which is exactly the
/// kind of assumption that breaks quietly.
enum SlackTimestamp {
  static func isAfter(_ lhs: String, _ rhs: String) -> Bool {
    value(lhs) > value(rhs)
  }

  static func newer(_ lhs: String, _ rhs: String) -> String {
    isAfter(lhs, rhs) ? lhs : rhs
  }

  static func value(_ ts: String) -> Double {
    Double(ts) ?? 0
  }
}

struct SlackChannelCursor: Equatable, Sendable {
  var channelID: String
  var channelName: String
  var lastTS: String?
  var participatedThreadTS: [String]
  var updatedAt: Date

  init(
    channelID: String,
    channelName: String,
    lastTS: String? = nil,
    participatedThreadTS: [String] = [],
    updatedAt: Date = Date()
  ) {
    self.channelID = channelID
    self.channelName = channelName
    self.lastTS = lastTS
    self.participatedThreadTS = participatedThreadTS
    self.updatedAt = updatedAt
  }
}

struct SlackActivityBatch: Sendable {
  var messages: [SlackMessage]
  var cursors: [SlackChannelCursor]
  var channelsScanned: Int
  var reachedDeadline: Bool
}

/// Reads forward from a per-channel cursor. Nothing here decides what matters —
/// it returns everything new in the channels the user belongs to, and the
/// relevance filter narrows it before any of it costs an AI token.
actor SlackMessageReader {
  private let client: SlackAPIClient
  private var userNames: [String: String] = [:]
  private var userNamesFetchedAt: Date?
  private var ownGroupIDs: Set<String> = []
  private var ownGroupsFetchedAt: Date?

  init(client: SlackAPIClient) {
    self.client = client
  }

  func fetchNewActivity(
    session: SlackIntegrationSession,
    cursors: [SlackChannelCursor],
    now: Date = Date(),
    backfillDays: Int = 7,
    deadline: Date? = nil
  ) async throws -> SlackActivityBatch {
    let token = session.accessToken
    let ownUserID = session.userID
    try await refreshUserNamesIfStale(token: token, now: now)

    let channels = try await listChannels(token: token)
    var cursorsByChannel = Dictionary(uniqueKeysWithValues: cursors.map { ($0.channelID, $0) })
    var collected: [SlackMessage] = []
    var scanned = 0
    var reachedDeadline = false

    let backfillFloor = String(
      format: "%.6f",
      now.addingTimeInterval(-Double(max(1, backfillDays)) * 86_400).timeIntervalSince1970
    )

    for channel in channels {
      if let deadline, Date() >= deadline {
        reachedDeadline = true
        break
      }

      var cursor = cursorsByChannel[channel.id]
        ?? SlackChannelCursor(channelID: channel.id, channelName: channel.name, updatedAt: now)
      cursor.channelName = channel.name

      let oldest = cursor.lastTS ?? backfillFloor
      let history = try await fetchHistory(
        channel: channel,
        token: token,
        oldest: oldest,
        ownUserID: ownUserID
      )
      scanned += 1

      var messages = history.messages
      var participated = Set(cursor.participatedThreadTS)

      // A thread the user has spoken in stays interesting even when later
      // replies never mention them again.
      for message in messages where message.isOwn {
        if let threadTS = message.threadTS {
          participated.insert(threadTS)
        }
      }

      for parent in history.threadParents {
        let isParticipated = participated.contains(parent.ts)
        let mentionsUser = parent.text.contains("<@\(session.userID)>")
        guard isParticipated || mentionsUser else { continue }
        guard parent.latestReply.map({ SlackTimestamp.isAfter($0, oldest) }) ?? false else { continue }

        let replies = try await fetchReplies(
          channel: channel,
          threadTS: parent.ts,
          token: token,
          oldest: oldest,
          ownUserID: ownUserID
        )
        if replies.contains(where: \.isOwn) {
          participated.insert(parent.ts)
        }
        messages.append(contentsOf: replies)
      }

      // Only advance once the whole channel pass succeeded — a throw above
      // leaves the old cursor in place so the next sync re-reads rather than
      // skipping the window.
      if let newest = messages.map(\.ts).max(by: { SlackTimestamp.isAfter($1, $0) }) {
        cursor.lastTS = SlackTimestamp.newer(newest, cursor.lastTS ?? newest)
      } else if cursor.lastTS == nil {
        cursor.lastTS = backfillFloor
      }
      cursor.participatedThreadTS = participated.sorted()
      cursor.updatedAt = now
      cursorsByChannel[channel.id] = cursor

      collected.append(contentsOf: messages)
    }

    let deduplicated = Dictionary(collected.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    return SlackActivityBatch(
      messages: deduplicated.values.sorted { SlackTimestamp.isAfter($1.ts, $0.ts) },
      cursors: Array(cursorsByChannel.values),
      channelsScanned: scanned,
      reachedDeadline: reachedDeadline
    )
  }

  func displayName(for userID: String) -> String? {
    userNames[userID]
  }

  func userNameMap() -> [String: String] {
    userNames
  }

  /// The user groups you belong to, so `@platform` counts as a mention of you.
  /// Refreshed daily — membership changes far more slowly than messages arrive.
  func ownGroups(session: SlackIntegrationSession, now: Date = Date()) async -> Set<String> {
    if let fetchedAt = ownGroupsFetchedAt, now.timeIntervalSince(fetchedAt) < 86_400 {
      return ownGroupIDs
    }

    do {
      let response: SlackUserGroupsResponse = try await client.get(
        "usergroups.list",
        token: session.accessToken,
        query: ["include_users": "true", "include_disabled": "false"]
      )
      ownGroupIDs = Set(
        response.usergroups
          .filter { $0.users?.contains(session.userID) ?? false }
          .map(\.id)
      )
      ownGroupsFetchedAt = now
    } catch {
      // A workspace can withhold this scope. Mentions of you still work; only
      // group mentions go quiet, which is better than failing the whole sync.
      AppLogger.error("Slack usergroups.list failed: \(error.localizedDescription)")
      ownGroupsFetchedAt = now
    }

    return ownGroupIDs
  }

  private func listChannels(token: String) async throws -> [SlackChannel] {
    var channels: [SlackChannel] = []
    var cursor: String?

    repeat {
      var query = [
        "types": "public_channel,private_channel",
        "exclude_archived": "true",
        "limit": "200",
      ]
      query["cursor"] = cursor

      let page: SlackConversationsListResponse = try await client.get(
        "users.conversations",
        token: token,
        query: query
      )
      channels.append(contentsOf: page.channels)
      cursor = page.responseMetadata?.nextCursor.nilIfEmpty
    } while cursor != nil

    return channels
  }

  private func fetchHistory(
    channel: SlackChannel,
    token: String,
    oldest: String,
    ownUserID: String
  ) async throws -> (messages: [SlackMessage], threadParents: [SlackThreadParent]) {
    var messages: [SlackMessage] = []
    var parents: [SlackThreadParent] = []
    var cursor: String?

    repeat {
      var query = [
        "channel": channel.id,
        "oldest": oldest,
        "limit": "200",
      ]
      query["cursor"] = cursor

      let page: SlackHistoryResponse = try await client.get(
        "conversations.history",
        token: token,
        query: query
      )

      for raw in page.messages {
        if (raw.replyCount ?? 0) > 0, let ts = raw.ts {
          parents.append(SlackThreadParent(ts: ts, text: raw.text ?? "", latestReply: raw.latestReply))
        }
        if let message = message(from: raw, channel: channel, ownUserID: ownUserID) {
          messages.append(message)
        }
      }

      cursor = page.responseMetadata?.nextCursor.nilIfEmpty
    } while cursor != nil

    return (messages, parents)
  }

  private func fetchReplies(
    channel: SlackChannel,
    threadTS: String,
    token: String,
    oldest: String,
    ownUserID: String
  ) async throws -> [SlackMessage] {
    var replies: [SlackMessage] = []
    var cursor: String?

    repeat {
      var query = [
        "channel": channel.id,
        "ts": threadTS,
        "oldest": oldest,
        "limit": "200",
      ]
      query["cursor"] = cursor

      let page: SlackHistoryResponse = try await client.get(
        "conversations.replies",
        token: token,
        query: query
      )
      replies.append(contentsOf: page.messages.compactMap { message(from: $0, channel: channel, ownUserID: ownUserID) })
      cursor = page.responseMetadata?.nextCursor.nilIfEmpty
    } while cursor != nil

    return replies
  }

  private func message(from raw: SlackRawMessage, channel: SlackChannel, ownUserID: String) -> SlackMessage? {
    guard let ts = raw.ts else { return nil }
    let userID = raw.user ?? raw.botID ?? ""

    return SlackMessage(
      channelID: channel.id,
      channelName: channel.name,
      ts: ts,
      threadTS: raw.threadTS,
      userID: userID,
      authorName: userNames[userID] ?? raw.username ?? userID,
      text: raw.text ?? "",
      isOwn: !userID.isEmpty && userID == ownUserID,
      isBot: raw.botID != nil || raw.subtype == "bot_message",
      subtype: raw.subtype,
      permalink: nil
    )
  }

  /// Rendering a raw `U024BE7LH` in a proposal makes it unreadable, and calling
  /// `users.info` per message is a rate-limit own goal.
  private func refreshUserNamesIfStale(token: String, now: Date) async throws {
    if let fetchedAt = userNamesFetchedAt, now.timeIntervalSince(fetchedAt) < 86_400 {
      return
    }

    var names: [String: String] = [:]
    var cursor: String?

    repeat {
      var query = ["limit": "200"]
      query["cursor"] = cursor

      let page: SlackUsersListResponse = try await client.get("users.list", token: token, query: query)
      for member in page.members {
        names[member.id] = member.profile?.displayName?.nilIfEmpty
          ?? member.profile?.realName?.nilIfEmpty
          ?? member.name
      }
      cursor = page.responseMetadata?.nextCursor.nilIfEmpty
    } while cursor != nil

    userNames = names
    userNamesFetchedAt = now
  }
}

extension SlackMessage {
  /// Slack permalinks are derivable from the workspace URL, which saves a
  /// `chat.getPermalink` call for every single message.
  static func permalink(workspaceURL: String?, channelID: String, ts: String) -> String? {
    guard let workspaceURL, let base = URL(string: workspaceURL) else { return nil }
    let compact = "p" + ts.replacingOccurrences(of: ".", with: "")
    return base
      .appendingPathComponent("archives")
      .appendingPathComponent(channelID)
      .appendingPathComponent(compact)
      .absoluteString
  }
}

struct SlackChannel: Decodable, Equatable, Sendable {
  let id: String
  let name: String
}

struct SlackThreadParent: Equatable, Sendable {
  let ts: String
  let text: String
  let latestReply: String?
}

private struct SlackConversationsListResponse: Decodable, SlackAPIResponse {
  let ok: Bool
  let error: String?
  let channels: [SlackChannel]
  let responseMetadata: SlackResponseMetadata?

  enum CodingKeys: String, CodingKey {
    case ok
    case error
    case channels
    case responseMetadata = "response_metadata"
  }
}

private struct SlackHistoryResponse: Decodable, SlackAPIResponse {
  let ok: Bool
  let error: String?
  let messages: [SlackRawMessage]
  let responseMetadata: SlackResponseMetadata?

  enum CodingKeys: String, CodingKey {
    case ok
    case error
    case messages
    case responseMetadata = "response_metadata"
  }
}

struct SlackRawMessage: Decodable, Equatable, Sendable {
  let ts: String?
  let threadTS: String?
  let user: String?
  let botID: String?
  let username: String?
  let text: String?
  let subtype: String?
  let replyCount: Int?
  let latestReply: String?

  enum CodingKeys: String, CodingKey {
    case ts
    case threadTS = "thread_ts"
    case user
    case botID = "bot_id"
    case username
    case text
    case subtype
    case replyCount = "reply_count"
    case latestReply = "latest_reply"
  }
}

private struct SlackUsersListResponse: Decodable, SlackAPIResponse {
  struct Member: Decodable {
    struct Profile: Decodable {
      let displayName: String?
      let realName: String?

      enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case realName = "real_name"
      }
    }

    let id: String
    let name: String
    let profile: Profile?
  }

  let ok: Bool
  let error: String?
  let members: [Member]
  let responseMetadata: SlackResponseMetadata?

  enum CodingKeys: String, CodingKey {
    case ok
    case error
    case members
    case responseMetadata = "response_metadata"
  }
}

private struct SlackUserGroupsResponse: Decodable, SlackAPIResponse {
  struct UserGroup: Decodable {
    let id: String
    let users: [String]?
  }

  let ok: Bool
  let error: String?
  let usergroups: [UserGroup]
}

struct SlackResponseMetadata: Decodable, Sendable {
  let nextCursor: String?

  enum CodingKeys: String, CodingKey {
    case nextCursor = "next_cursor"
  }
}

extension Optional where Wrapped == String {
  var nilIfEmpty: String? {
    guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return self
  }
}

extension String {
  var nilIfEmpty: String? {
    trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
  }
}
