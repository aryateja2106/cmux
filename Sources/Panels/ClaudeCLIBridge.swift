import Foundation

/// Message in an assistant conversation.
struct AssistantMessage: Identifiable, Equatable {
    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date
    var pointTarget: PointTarget?

    enum Role: String, Equatable {
        case user
        case assistant
    }

    init(role: Role, content: String, pointTarget: PointTarget? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.pointTarget = pointTarget
    }
}

/// A parsed [POINT:x,y:label] target from Claude's response.
struct PointTarget: Equatable {
    let x: CGFloat
    let y: CGFloat
    let label: String

    /// Parse a [POINT:x,y:label] tag from the end of a response string.
    /// Returns the target and the cleaned text (tag removed).
    static func parse(from text: String) -> (target: PointTarget?, cleanedText: String) {
        let pattern = #"\[POINT:(\d+)\s*,\s*(\d+)(?::([^\]]+))?\]\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return (nil, text)
        }

        guard let xRange = Range(match.range(at: 1), in: text),
              let yRange = Range(match.range(at: 2), in: text),
              let xVal = Double(text[xRange]),
              let yVal = Double(text[yRange]) else {
            return (nil, text)
        }

        var label = "Here"
        if match.range(at: 3).location != NSNotFound,
           let labelRange = Range(match.range(at: 3), in: text) {
            label = String(text[labelRange])
        }

        let tagRange = Range(match.range, in: text)!
        let cleaned = String(text[text.startIndex..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        return (PointTarget(x: xVal, y: yVal, label: label), cleaned)
    }
}

/// Bridge to the `claude` CLI for leveraging Max plan credits.
/// Falls back to direct Anthropic API if CLI is not found.
@MainActor
final class ClaudeCLIBridge: ObservableObject {
    @Published private(set) var isStreaming = false
    @Published private(set) var currentStreamText = ""

    private var currentProcess: Process?
    private var sessionId: String?

    /// Path to the claude CLI binary.
    private let claudePath: String

    /// Whether the claude CLI is available.
    let isAvailable: Bool

    init() {
        // Find claude CLI
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(ProcessInfo.processInfo.environment["HOME"] ?? "")/bin/claude",
            "\(ProcessInfo.processInfo.environment["HOME"] ?? "")/.claude/bin/claude",
        ]

        var found: String?
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                found = path
                break
            }
        }

        // Try `which claude` as fallback
        if found == nil {
            let which = Process()
            which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            which.arguments = ["claude"]
            let pipe = Pipe()
            which.standardOutput = pipe
            which.standardError = Pipe()
            try? which.run()
            which.waitUntilExit()
            if which.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                    found = path
                }
            }
        }

        self.claudePath = found ?? "claude"
        self.isAvailable = found != nil
    }

    /// Send a message to Claude with an optional screenshot.
    /// Streams the response back via the `currentStreamText` property.
    /// Returns the final response text and any parsed point target.
    func send(
        message: String,
        screenshotPath: String? = nil,
        systemPrompt: String? = nil
    ) async throws -> (text: String, pointTarget: PointTarget?) {
        guard !isStreaming else {
            throw ClaudeBridgeError.alreadyStreaming
        }

        isStreaming = true
        currentStreamText = ""
        defer { isStreaming = false }

        if isAvailable {
            return try await sendViaCLI(message: message, screenshotPath: screenshotPath, systemPrompt: systemPrompt)
        } else {
            throw ClaudeBridgeError.cliNotFound
        }
    }

    /// Cancel the current streaming response.
    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil
        isStreaming = false
    }

    // MARK: - CLI subprocess

    private func sendViaCLI(
        message: String,
        screenshotPath: String?,
        systemPrompt: String?
    ) async throws -> (text: String, pointTarget: PointTarget?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)

        // Screenshot directory inside home (trusted by Claude CLI)
        let screenshotDir = (ProcessInfo.processInfo.environment["HOME"] ?? "/tmp") + "/tmp-clicky"
        try? FileManager.default.createDirectory(atPath: screenshotDir, withIntermediateDirectories: true)

        let hasScreenshot = screenshotPath != nil

        var args = [
            "--print",
            "--tools", hasScreenshot ? "Read" : "",  // Read tool only when we have a screenshot
            "--no-session-persistence",               // Lightweight, no disk writes
            "--model", "sonnet",                      // Fast model for assistant responses
            "--permission-mode", "auto",              // Auto-approve Read operations
        ]

        if hasScreenshot {
            args += ["--add-dir", screenshotDir]
        }

        if let systemPrompt {
            args += ["--system-prompt", systemPrompt]
        }

        // Resume session for multi-turn context
        if let sessionId {
            args += ["--resume", sessionId]
        }

        // Build the prompt — if screenshot available, ask Claude to read it
        if let screenshotPath {
            // Copy screenshot to trusted dir
            let trustedPath = screenshotDir + "/" + URL(fileURLWithPath: screenshotPath).lastPathComponent
            try? FileManager.default.copyItem(atPath: screenshotPath, toPath: trustedPath)
            args.append("Read the screenshot at \(trustedPath) and then answer: \(message)")
        } else {
            args.append(message)
        }
        process.arguments = args

        // Run from home directory (trusted by Claude CLI, avoids project CLAUDE.md)
        let homeDir = ProcessInfo.processInfo.environment["HOME"] ?? NSTemporaryDirectory()
        process.currentDirectoryURL = URL(fileURLWithPath: homeDir)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Inherit environment for auth but strip project context
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        process.environment = env

        self.currentProcess = process

        try process.run()

        // Stream stdout line by line
        let handle = outputPipe.fileHandleForReading
        var fullOutput = ""

        return try await withCheckedThrowingContinuation { continuation in
            handle.readabilityHandler = { [weak self] fileHandle in
                let data = fileHandle.availableData
                guard !data.isEmpty else {
                    // EOF — process finished
                    fileHandle.readabilityHandler = nil
                    process.waitUntilExit()

                    let (target, cleaned) = PointTarget.parse(from: fullOutput)

                    Task { @MainActor [weak self] in
                        self?.currentStreamText = cleaned
                        self?.currentProcess = nil

                        // Try to capture session ID from stderr for resume
                        let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        if let errStr = String(data: errData, encoding: .utf8),
                           let range = errStr.range(of: "session_id: ") {
                            self?.sessionId = String(errStr[range.upperBound...].prefix(while: { !$0.isWhitespace }))
                        }

                        continuation.resume(returning: (cleaned, target))
                    }
                    return
                }

                if let chunk = String(data: data, encoding: .utf8) {
                    fullOutput += chunk
                    Task { @MainActor [weak self] in
                        self?.currentStreamText = fullOutput
                    }
                }
            }
        }
    }
}

enum ClaudeBridgeError: Error, LocalizedError {
    case cliNotFound
    case alreadyStreaming
    case processError(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Claude CLI not found — install from https://claude.ai/download"
        case .alreadyStreaming:
            return "Already streaming a response"
        case .processError(let detail):
            return "Claude process error: \(detail)"
        }
    }
}
