import Foundation
import Combine
import AppKit

/// Default system prompt for the Clicky assistant.
/// Instructs Claude to use [POINT:x,y:label] tags for element highlighting.
private let assistantSystemPrompt = """
You are Clicky, an AI assistant embedded in a terminal application called cmux. \
You can see screenshots of the user's terminal, browser, VNC, and other panels.

When you want to point at a specific UI element on screen, end your response with a \
[POINT:x,y:label] tag where x,y are pixel coordinates in the screenshot and label is \
a short description. Only use one POINT tag per response, placed at the very end.

Examples:
- "Click the green button in the top right [POINT:450,32:Run button]"
- "The error is on this line [POINT:200,156:TypeError]"
- "That setting is here [POINT:820,400:Preferences]"

Be concise, helpful, and conversational. You're a knowledgeable companion helping \
the user navigate their development environment. When analyzing terminal output, \
focus on errors, warnings, and actionable items.
"""

/// A panel that provides an AI assistant companion powered by Claude.
@MainActor
final class AssistantPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .assistant

    /// Display title shown in the tab bar.
    @Published private(set) var displayTitle: String = "Assistant"

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "sparkles" }

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Chat messages.
    @Published var messages: [AssistantMessage] = []

    /// Whether Claude is currently streaming a response.
    @Published private(set) var isStreaming: Bool = false

    /// Current partial streaming text.
    @Published private(set) var streamingText: String = ""

    /// Error message if something went wrong.
    @Published private(set) var errorMessage: String?

    /// The most recent point target from Claude's response (for overlay rendering).
    @Published private(set) var activePointTarget: PointTarget?

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// The panel this assistant is helping with (e.g., a terminal or browser panel).
    weak var siblingPanel: (any Panel)?

    /// Claude CLI bridge.
    let claude: ClaudeCLIBridge

    /// Auto-dismiss timer for point target overlay.
    private var pointDismissTask: Task<Void, Never>?

    // MARK: - Init

    init(workspaceId: UUID) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.claude = ClaudeCLIBridge()

        if !claude.isAvailable {
            errorMessage = "Claude CLI not found — install from https://claude.ai/download"
        }
    }

    // MARK: - Chat

    /// Send a user message and get a response from Claude.
    func sendMessage(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isStreaming else { return }

        errorMessage = nil
        let userMessage = AssistantMessage(role: .user, content: text)
        messages.append(userMessage)

        isStreaming = true
        streamingText = ""

        // Capture screenshot of sibling panel if available
        var screenshotPath: String?
        if let screenshot = captureContext() {
            let tempPath = NSTemporaryDirectory() + "cmux-assistant-\(UUID().uuidString).jpg"
            do {
                try screenshot.write(to: URL(fileURLWithPath: tempPath), options: .atomic)
                screenshotPath = tempPath
            } catch {
                // Screenshot save failed — proceed without image context
            }
        }

        do {
            let (responseText, pointTarget) = try await claude.send(
                message: text,
                screenshotPath: screenshotPath,
                systemPrompt: assistantSystemPrompt
            )

            let assistantMessage = AssistantMessage(
                role: .assistant,
                content: responseText,
                pointTarget: pointTarget
            )
            messages.append(assistantMessage)

            if let target = pointTarget {
                showPointTarget(target)
            }

            // Clean up temp screenshot
            if let path = screenshotPath {
                try? FileManager.default.removeItem(atPath: path)
            }
        } catch {
            errorMessage = error.localizedDescription
            let errorMsg = AssistantMessage(role: .assistant, content: "Error: \(error.localizedDescription)")
            messages.append(errorMsg)
        }

        isStreaming = false
        streamingText = ""
    }

    /// Cancel the current streaming response.
    func cancelStreaming() {
        claude.cancel()
        isStreaming = false
        streamingText = ""
    }

    /// Clear conversation history.
    func clearHistory() {
        messages.removeAll()
        activePointTarget = nil
        errorMessage = nil
    }

    // MARK: - Context Capture

    /// Capture a screenshot of the sibling panel as JPEG data.
    func captureContext() -> Data? {
        guard let sibling = siblingPanel else { return nil }

        // Try VNC panel screenshot
        if let vncPanel = sibling as? VNCPanel {
            return vncPanel.captureScreenshot()
        }

        // For other panel types, we'd capture their view.
        // Terminal and browser panels would need view-level capture.
        return nil
    }

    // MARK: - Point Target

    private func showPointTarget(_ target: PointTarget) {
        pointDismissTask?.cancel()
        activePointTarget = target

        pointDismissTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000) // 4 seconds
            guard !Task.isCancelled else { return }
            activePointTarget = nil
        }
    }

    func dismissPointTarget() {
        pointDismissTask?.cancel()
        activePointTarget = nil
    }

    // MARK: - Panel Protocol

    func focus() {}

    func unfocus() {}

    func close() {
        cancelStreaming()
        pointDismissTask?.cancel()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        focusFlashToken += 1
    }
}
