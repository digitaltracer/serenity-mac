import Foundation
import XCTest
@testable import SerenityMac

final class SerenityCloudAdapterTests: XCTestCase {
  override func tearDown() {
    super.tearDown()
    URLProtocolStub.responseProvider = nil
  }

  func testValidateConnectionUsesHealthEndpointAndAuthHeader() async {
    let expectation = expectation(description: "health request")

    URLProtocolStub.responseProvider = { request in
      XCTAssertEqual(request.url?.path, "/health")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
      expectation.fulfill()

      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!

      return (response, Data("{}".utf8))
    }

    let adapter = makeAdapter()
    let validation = await adapter.validateConnection()

    XCTAssertEqual(validation, .available(message: "Connected to Serenity Cloud."))
    await fulfillment(of: [expectation], timeout: 1)
  }

  func testListTasksDecodesTaskPayload() async throws {
    let now = Date()
    let nowString = ISO8601DateFormatter().string(from: now)

    URLProtocolStub.responseProvider = { request in
      XCTAssertEqual(request.url?.path, "/tasks")
      XCTAssertEqual(request.httpMethod, "GET")

      let payload = """
      [
        {
          "id": "task-1",
          "title": "Cloud task",
          "description": "From API",
          "completed": false,
          "completedAt": null,
          "priority": "high",
          "dueDate": null,
          "projectId": null,
          "tags": ["cloud"],
          "createdAt": "\(nowString)",
          "updatedAt": "\(nowString)",
          "subtasks": [],
          "recurring": null,
          "userId": "user-1"
        }
      ]
      """

      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!

      return (response, Data(payload.utf8))
    }

    let tasks = try await makeAdapter().listTasks()
    XCTAssertEqual(tasks.count, 1)
    XCTAssertEqual(tasks.first?.id, "task-1")
    XCTAssertEqual(tasks.first?.priority, .high)
    XCTAssertEqual(tasks.first?.tags, ["cloud"])
  }

  func testCreateTaskSendsPostRequest() async throws {
    let now = Date()
    let nowString = ISO8601DateFormatter().string(from: now)
    let expectation = expectation(description: "post task")

    URLProtocolStub.responseProvider = { request in
      XCTAssertEqual(request.url?.path, "/tasks")
      XCTAssertEqual(request.httpMethod, "POST")
      let bodyData = Self.requestBodyData(from: request)
      XCTAssertNotNil(bodyData)
      let bodyString = String(data: bodyData ?? Data(), encoding: .utf8) ?? ""
      XCTAssertTrue(bodyString.contains("\"title\":\"Cloud create\""))
      expectation.fulfill()

      let responsePayload = """
      {
        "id": "task-created",
        "title": "Cloud create",
        "description": null,
        "completed": false,
        "completedAt": null,
        "priority": "medium",
        "dueDate": null,
        "projectId": null,
        "tags": [],
        "createdAt": "\(nowString)",
        "updatedAt": "\(nowString)",
        "subtasks": [],
        "recurring": null,
        "userId": null
      }
      """

      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!

      return (response, Data(responsePayload.utf8))
    }

    let created = try await makeAdapter().createTask(
      TaskEntity(
        id: "temp-id",
        title: "Cloud create",
        description: nil,
        completed: false,
        completedAt: nil,
        priority: .medium,
        dueDate: nil,
        projectId: nil,
        tags: [],
        createdAt: now,
        updatedAt: now,
        subtasks: [],
        recurring: nil,
        userId: nil
      )
    )

    XCTAssertEqual(created.id, "task-created")
    XCTAssertEqual(created.title, "Cloud create")
    await fulfillment(of: [expectation], timeout: 1)
  }

  private func makeAdapter() -> SerenityCloudAdapter {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: configuration)

    return SerenityCloudAdapter(
      configuration: SerenityCloudConfiguration(
        baseURL: URL(string: "https://cloud.serenity.example")!,
        accessToken: "token-123"
      ),
      session: session
    )
  }

  private static func requestBodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
      return body
    }

    guard let stream = request.httpBodyStream else {
      return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
      let bytesRead = stream.read(buffer, maxLength: bufferSize)
      if bytesRead <= 0 {
        break
      }
      data.append(buffer, count: bytesRead)
    }

    return data
  }
}

private final class URLProtocolStub: URLProtocol {
  static var responseProvider: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let provider = URLProtocolStub.responseProvider else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }

    do {
      let (response, data) = try provider(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

extension SerenityCloudAdapterTests {
  /// A token that expires mid-session is refreshed on the 401 and the request is sent once more.
  func testA401RefreshesTheTokenAndRetriesOnce() async throws {
    let seen = TokenLog()
    URLProtocolStub.responseProvider = { request in
      let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
      seen.append(header)
      let status = header == "Bearer fresh-token" ? 200 : 401
      let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      return (response, Data("[]".utf8))
    }
    let adapter = makeAdapter()
    let refreshes = TokenLog()
    adapter.accessTokenProvider = { force in
      guard force else { return nil }
      refreshes.append("forced")
      return "fresh-token"
    }

    let tasks = try await adapter.listTasks()

    XCTAssertTrue(tasks.isEmpty)
    XCTAssertEqual(seen.values, ["Bearer token-123", "Bearer fresh-token"])
    XCTAssertEqual(refreshes.values, ["forced"])
  }

  func testARefreshThatChangesNothingDoesNotRetry() async {
    let seen = TokenLog()
    URLProtocolStub.responseProvider = { request in
      seen.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
      let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
      return (response, Data("unauthorized".utf8))
    }
    let adapter = makeAdapter()
    adapter.accessTokenProvider = { _ in nil }

    do {
      _ = try await adapter.listTasks()
      XCTFail("Expected the 401 to surface")
    } catch {
      XCTAssertEqual(seen.values.count, 1)
    }
  }
}

private final class TokenLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []

  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func append(_ value: String) {
    lock.lock()
    stored.append(value)
    lock.unlock()
  }
}
