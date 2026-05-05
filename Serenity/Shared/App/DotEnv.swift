import Foundation

enum DotEnv {
  static func loadIfPresent(filename: String = ".env") {
    let candidates = searchPaths(for: filename)
    guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
          let contents = try? String(contentsOf: url, encoding: .utf8)
    else {
      return
    }

    for rawLine in contents.split(whereSeparator: { $0.isNewline }) {
      let line = String(rawLine).trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }

      guard let separator = line.firstIndex(of: "=") else { continue }
      let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
      var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)

      if value.count >= 2,
         (value.hasPrefix("\"") && value.hasSuffix("\""))
           || (value.hasPrefix("'") && value.hasSuffix("'")) {
        value = String(value.dropFirst().dropLast())
      }

      guard !key.isEmpty else { continue }
      guard ProcessInfo.processInfo.environment[key] == nil else { continue }

      setenv(key, value, 0)
    }
  }

  private static func searchPaths(for filename: String) -> [URL] {
    var urls: [URL] = []

    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    urls.append(cwd.appendingPathComponent(filename))

    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
      .deletingLastPathComponent()
    urls.append(executable.appendingPathComponent(filename))

    return urls
  }
}
