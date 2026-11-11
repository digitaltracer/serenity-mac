import AVFoundation
import Foundation

// MARK: - Settings

enum VoiceTranscriptionModel: String, CaseIterable, Identifiable {
  case gpt4oTranscribe = "gpt-4o-transcribe"
  case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"
  case whisper = "whisper-1"

  var id: String { rawValue }

  var detail: String {
    switch self {
    case .gpt4oTranscribe:
      return "Most accurate"
    case .gpt4oMiniTranscribe:
      return "Faster and cheaper for short captures"
    case .whisper:
      return "The original Whisper model"
    }
  }
}

enum VoiceTranscriptionSettings {
  static let modelKey = "serenity.voice.transcriptionModel"
  static let vocabularyKey = "serenity.voice.vocabulary"

  static var model: VoiceTranscriptionModel {
    get { UserDefaults.standard.string(forKey: modelKey).flatMap(VoiceTranscriptionModel.init(rawValue:)) ?? .gpt4oTranscribe }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: modelKey) }
  }

  /// Names and jargon passed to the model as a prompt, so "CloudKit" does not come back as "cloud kit".
  static var vocabulary: String {
    get { UserDefaults.standard.string(forKey: vocabularyKey) ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: vocabularyKey) }
  }
}

// MARK: - Transcription

enum VoiceTranscriptionError: Error, LocalizedError, Equatable {
  case noOpenAIKey
  case emptyRecording
  case nothingHeard

  var errorDescription: String? {
    switch self {
    case .noOpenAIKey:
      return "Voice capture uses OpenAI for transcription. Add an OpenAI key in Settings > AI Provider."
    case .emptyRecording:
      return "The recording was empty."
    case .nothingHeard:
      return "No speech was picked up. Try again a little closer to the microphone."
    }
  }
}

enum VoiceTranscriptionClient {
  static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

  static func transcribe(
    fileURL: URL,
    apiKey: String,
    model: VoiceTranscriptionModel,
    vocabulary: String
  ) async throws -> String {
    let audio = try Data(contentsOf: fileURL)
    guard !audio.isEmpty else { throw VoiceTranscriptionError.emptyRecording }

    let boundary = "Serenity-\(UUID().uuidString)"
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = multipartBody(
      boundary: boundary,
      fields: ["model": model.rawValue, "response_format": "json", "prompt": vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)],
      fileName: fileURL.lastPathComponent,
      fileData: audio
    )

    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw AIProviderAPIError.network(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else { throw AIProviderAPIError.decoding }
    switch http.statusCode {
    case 200...299:
      break
    case 401:
      throw AIProviderAPIError.invalidKey
    case 403:
      throw AIProviderAPIError.permissionDenied(errorMessage(in: data))
    case 429:
      throw AIProviderAPIError.rateLimited
    default:
      throw AIProviderAPIError.unexpected(http.statusCode, errorMessage(in: data))
    }

    struct Payload: Decodable { let text: String }
    guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
      throw AIProviderAPIError.decoding
    }
    let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw VoiceTranscriptionError.nothingHeard }
    return text
  }

  static func multipartBody(boundary: String, fields: [String: String], fileName: String, fileData: Data) -> Data {
    var body = Data()
    func append(_ string: String) { body.append(Data(string.utf8)) }

    for (name, value) in fields.sorted(by: { $0.key < $1.key }) where !value.isEmpty {
      append("--\(boundary)\r\n")
      append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
      append("\(value)\r\n")
    }
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
    append("Content-Type: audio/mp4\r\n\r\n")
    body.append(fileData)
    append("\r\n--\(boundary)--\r\n")
    return body
  }

  private static func errorMessage(in data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = object["error"] as? [String: Any]
    else { return nil }
    return error["message"] as? String
  }
}

// MARK: - Splitting a recording into items

struct VoiceCaptureItem: Identifiable, Equatable {
  enum Kind: String, CaseIterable {
    case task
    case journal
    case goalCheckIn = "goal_check_in"
    case routineDone = "routine_done"
  }

  var id = UUID().uuidString
  var kind: Kind
  var text: String
  var dueDate: Date?
  var hasTime = false
  var projectId: String?
  var goalId: String?
  var amount: Double?
  var routineId: String?
  var include = true
}

struct VoiceCaptureContext {
  struct Goal { let id: String; let title: String; let unit: String }
  struct Routine { let id: String; let title: String }
  struct Project { let id: String; let name: String }

  var goals: [Goal] = []
  var routines: [Routine] = []
  var projects: [Project] = []
}

enum VoiceCaptureParser {
  static func schema() -> [String: Any] {
    [
      "title": "voice_capture_items",
      "type": "object",
      "additionalProperties": false,
      "required": ["items"],
      "properties": [
        "items": [
          "type": "array",
          "items": [
            "type": "object",
            "additionalProperties": false,
            "required": ["kind", "text", "due", "hasTime", "projectId", "goalId", "amount", "routineId"],
            "properties": [
              "kind": ["type": "string", "enum": VoiceCaptureItem.Kind.allCases.map(\.rawValue)],
              "text": ["type": "string"],
              "due": ["type": ["string", "null"]],
              "hasTime": ["type": "boolean"],
              "projectId": ["type": ["string", "null"]],
              "goalId": ["type": ["string", "null"]],
              "amount": ["type": ["number", "null"]],
              "routineId": ["type": ["string", "null"]],
            ],
          ],
        ],
      ],
    ]
  }

  static func systemPrompt() -> String {
    """
    You turn a spoken note into separate items for a personal productivity app. One note often holds \
    several things; return one item per thing, in the order they were said.

    Kinds:
    - task: something to do. "text" is a short imperative title. Set "due" when a day or time is said.
    - journal: a feeling, reflection or observation. "text" is the person's words, lightly cleaned up.
    - goal_check_in: progress toward one of the listed goals, such as distance run. Set "goalId" to a \
    listed id and "amount" in the goal's unit. Put any remark in "text", or "" when there is none.
    - routine_done: the person did one of the listed routines today. Set "routineId" to a listed id.

    Only use ids from the lists. When nothing listed fits, make it a task or a journal entry instead. \
    "due" is local time as yyyy-MM-dd or yyyy-MM-ddTHH:mm; set "hasTime" when a time of day was said. \
    "projectId" is set only when the person names a listed project. Unused fields are null.
    """
  }

  static func userPrompt(transcript: String, context: VoiceCaptureContext, now: Date, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "EEEE yyyy-MM-dd HH:mm"

    func list(_ lines: [String]) -> String { lines.isEmpty ? "(none)" : lines.joined(separator: "\n") }

    return """
    Now: \(formatter.string(from: now)) (\(timeZone.identifier))

    Goals:
    \(list(context.goals.map { "- \($0.id): \($0.title)\($0.unit.isEmpty ? "" : " [\($0.unit)]")" }))

    Routines:
    \(list(context.routines.map { "- \($0.id): \($0.title)" }))

    Projects:
    \(list(context.projects.map { "- \($0.id): \($0.name)" }))

    Note:
    \(transcript)
    """
  }

  static func decode(_ text: String, context: VoiceCaptureContext, timeZone: TimeZone = .current) throws -> [VoiceCaptureItem] {
    struct Raw: Decodable {
      struct Item: Decodable {
        let kind: String
        let text: String
        let due: String?
        let hasTime: Bool?
        let projectId: String?
        let goalId: String?
        let amount: Double?
        let routineId: String?
      }
      let items: [Item]
    }

    let start = text.firstIndex(of: "{") ?? text.startIndex
    let end = text.lastIndex(of: "}").map { text.index(after: $0) } ?? text.endIndex
    guard let data = String(text[start..<end]).data(using: .utf8) else { throw AIProviderAPIError.decoding }
    let raw = try JSONDecoder().decode(Raw.self, from: data)

    let goalIDs = Set(context.goals.map(\.id))
    let routineIDs = Set(context.routines.map(\.id))
    let projectIDs = Set(context.projects.map(\.id))

    return raw.items.compactMap { item in
      var kind = VoiceCaptureItem.Kind(rawValue: item.kind) ?? .task
      let words = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
      // An id the model made up demotes the item rather than pointing it at nothing.
      if kind == .goalCheckIn, item.goalId.map(goalIDs.contains) != true || item.amount == nil { kind = .journal }
      if kind == .routineDone, item.routineId.map(routineIDs.contains) != true { kind = .task }
      if words.isEmpty, kind == .task || kind == .journal { return nil }

      let due = item.due.flatMap { parseDue($0, timeZone: timeZone) }
      return VoiceCaptureItem(
        kind: kind,
        text: words,
        dueDate: kind == .task ? due : nil,
        hasTime: kind == .task && due != nil && (item.hasTime ?? false),
        projectId: kind == .task ? item.projectId.flatMap { projectIDs.contains($0) ? $0 : nil } : nil,
        goalId: kind == .goalCheckIn ? item.goalId : nil,
        amount: kind == .goalCheckIn ? item.amount : nil,
        routineId: kind == .routineDone ? item.routineId : nil
      )
    }
  }

  static func parseDue(_ raw: String, timeZone: TimeZone = .current) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
      formatter.dateFormat = format
      if let date = formatter.date(from: raw.trimmingCharacters(in: .whitespaces)) { return date }
    }
    return nil
  }
}

// MARK: - Recording

@MainActor
final class VoiceRecorder: ObservableObject {
  static let maximumDuration: TimeInterval = 10 * 60
  static let levelCount = 48

  @Published private(set) var levels: [Double] = Array(repeating: 0.04, count: levelCount)
  @Published private(set) var elapsed: TimeInterval = 0
  @Published private(set) var isRecording = false

  private var recorder: AVAudioRecorder?
  private var meterTimer: Timer?
  private var fileURL: URL?

  static func requestPermission() async -> Bool {
#if os(macOS)
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .audio)
    default:
      return false
    }
#else
    return await AVAudioApplication.requestRecordPermission()
#endif
  }

  func start() throws {
#if os(iOS)
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .spokenAudio)
    try session.setActive(true)
#endif
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("serenity-voice-\(UUID().uuidString).m4a")
    let recorder = try AVAudioRecorder(
      url: url,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
      ]
    )
    recorder.isMeteringEnabled = true
    guard recorder.record(forDuration: Self.maximumDuration) else {
      throw VoiceTranscriptionError.emptyRecording
    }

    self.recorder = recorder
    fileURL = url
    elapsed = 0
    levels = Array(repeating: 0.04, count: Self.levelCount)
    isRecording = true
    meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.sampleLevel() }
    }
  }

  /// Ends the recording and hands back the file. The caller deletes it once transcribed.
  func stop() -> URL? {
    guard let recorder else { return nil }
    recorder.stop()
    finishSession()
    return fileURL
  }

  func cancel() {
    recorder?.stop()
    if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    finishSession()
  }

  private func finishSession() {
    meterTimer?.invalidate()
    meterTimer = nil
    recorder = nil
    isRecording = false
#if os(iOS)
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
  }

  private func sampleLevel() {
    guard let recorder, recorder.isRecording else {
      if isRecording { _ = stop() }
      return
    }
    recorder.updateMeters()
    let power = Double(recorder.averagePower(forChannel: 0))
    // -50 dB and below reads as silence; the curve keeps quiet speech visible.
    let level = max(0.04, min(1, pow(10, power / 40)))
    levels = Array(levels.dropFirst()) + [level]
    elapsed = recorder.currentTime
  }
}
