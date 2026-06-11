import Foundation

/// Locates and runs the ClaudeGauge / CodexGauge CLIs as subprocesses.
enum BackendRunner {
    enum Kind { case claude, codex }

    enum RunError: Error, LocalizedError {
        case binaryNotFound(String)
        case nonZeroExit(code: Int32, stderr: String)
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound(let name): return "Could not find \(name). Set its path in Settings → General."
            case .nonZeroExit(let code, let err): return "Exit code \(code). \(err.prefix(200))"
            case .decodeFailed(let m): return "Could not parse output: \(m)"
            }
        }
    }

    // MARK: - Binary discovery

    static func resolveBinary(_ kind: Kind) -> URL? {
        let exeName = binaryName(kind)

        // 1. User override in settings
        let override = (kind == .claude
                        ? AppSettings.shared.claudeGaugePath
                        : AppSettings.shared.codexGaugePath)
            .trimmingCharacters(in: .whitespaces)
        if !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }

        // 2. Inside the .app bundle's Resources/ (drag-to-/Applications layout)
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent(exeName)
            if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        }

        // 3. Same directory as the AIGauge executable (flat release/ scenario)
        let selfDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        let siblingInRelease = selfDir.appendingPathComponent(exeName)
        if FileManager.default.isExecutableFile(atPath: siblingInRelease.path) { return siblingInRelease }

        // 4. Sibling project layout: ../claude-gauge/.build/release/ClaudeGauge (dev)
        var dir = selfDir
        for _ in 0..<6 {
            let candidate = dir
                .appendingPathComponent(kind == .claude ? "claude-gauge" : "codex-gauge")
                .appendingPathComponent(".build/release/\(exeName)")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }

        // 5. PATH
        if let onPath = which(exeName) { return onPath }

        return nil
    }

    private static func binaryName(_ kind: Kind) -> String {
        switch kind {
        case .claude: return "ClaudeGauge"
        case .codex:  return "CodexGauge"
        }
    }

    private static func which(_ exe: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        let paths = (env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":")
        for p in paths {
            let url = URL(fileURLWithPath: String(p)).appendingPathComponent(exe)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - Run

    /// Runs the CLI and returns parsed stdout JSON as the requested Decodable.
    /// Throws on missing binary, non-zero exit, or decode failure.
    static func runJSON<T: Decodable>(_ kind: Kind, args: [String], as type: T.Type) async throws -> T {
        let data = try await run(kind: kind, args: args + ["--json"])
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RunError.decodeFailed(error.localizedDescription)
        }
    }

    /// Raw run — returns stdout Data.
    static func run(kind: Kind, args: [String]) async throws -> Data {
        guard let bin = resolveBinary(kind) else {
            throw RunError.binaryNotFound(binaryName(kind))
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = bin
                task.arguments = args
                let outPipe = Pipe()
                let errPipe = Pipe()
                task.standardOutput = outPipe
                task.standardError = errPipe
                do {
                    try task.run()
                    task.waitUntilExit()
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    if task.terminationStatus == 0 {
                        cont.resume(returning: outData)
                    } else {
                        let errStr = String(data: errData, encoding: .utf8) ?? ""
                        cont.resume(throwing: RunError.nonZeroExit(code: task.terminationStatus, stderr: errStr))
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
