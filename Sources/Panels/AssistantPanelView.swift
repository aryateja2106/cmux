import SwiftUI

/// SwiftUI view for the AI assistant panel.
struct AssistantPanelView: View {
    @ObservedObject var panel: AssistantPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var inputText: String = ""
    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()
                .background(Color(white: 0.15))

            // Messages
            messagesView

            // Error
            if let error = panel.errorMessage {
                errorBanner(error)
            }

            // Input
            inputView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: NSColor(srgbRed: 10.0/255.0, green: 10.0/255.0, blue: 10.0/255.0, alpha: 1.0)))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.blue.opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: Color.blue.opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(2)
                .allowsHitTesting(false)
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlash()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundColor(.blue)

            Text("Assistant")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(Color(white: 0.8))

            if !panel.claude.isAvailable {
                Text("(CLI not found)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))
            }

            Spacer()

            if panel.isStreaming {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
            }

            // Context indicator
            if let sibling = panel.siblingPanel {
                HStack(spacing: 4) {
                    Image(systemName: sibling.displayIcon ?? "square")
                        .font(.system(size: 9))
                    Text(sibling.displayTitle)
                        .font(.system(size: 9, design: .monospaced))
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(white: 0.12))
                .cornerRadius(3)
                .foregroundColor(Color(white: 0.5))
            }

            Button(action: { panel.clearHistory() }) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(Color(white: 0.4))
            .help("Clear conversation")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(white: 0.06))
    }

    // MARK: - Messages

    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if panel.messages.isEmpty {
                        welcomeView
                    }

                    ForEach(panel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if panel.isStreaming, !panel.claude.currentStreamText.isEmpty {
                        streamingBubble
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: panel.messages.count) { _ in
                if let last = panel.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 20)

            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .thin))
                .foregroundColor(Color(white: 0.25))

            Text("Ask me anything about what's on screen")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(white: 0.4))
                .multilineTextAlignment(.center)

            // Quick action chips
            HStack(spacing: 6) {
                QuickChip(text: "What's on screen?") {
                    sendQuickMessage("What's on screen?")
                }
                QuickChip(text: "Help me debug") {
                    sendQuickMessage("Help me debug the error I'm seeing")
                }
            }

            HStack(spacing: 6) {
                QuickChip(text: "Explain this") {
                    sendQuickMessage("Explain what I'm looking at")
                }
                QuickChip(text: "What should I do?") {
                    sendQuickMessage("What should I do next?")
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var streamingBubble: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 9))
                .foregroundColor(.blue)
                .padding(.top, 3)

            Text(panel.claude.currentStreamText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(white: 0.75))
                .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.08))
        .cornerRadius(6)
    }

    // MARK: - Error

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(white: 0.6))
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(red: 0.15, green: 0.1, blue: 0.0))
    }

    // MARK: - Input

    private var inputView: some View {
        HStack(spacing: 6) {
            TextField("Ask about what's on screen...", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(white: 0.08))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
                .onSubmit {
                    sendCurrentMessage()
                }

            if panel.isStreaming {
                Button(action: { panel.cancelStreaming() }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .frame(width: 28, height: 28)
            } else {
                Button(action: { sendCurrentMessage() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(inputText.isEmpty ? Color(white: 0.2) : .blue)
                }
                .buttonStyle(.plain)
                .disabled(inputText.isEmpty)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(white: 0.04))
    }

    // MARK: - Actions

    private func sendCurrentMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        Task {
            await panel.sendMessage(text)
        }
    }

    private func sendQuickMessage(_ text: String) {
        Task {
            await panel.sendMessage(text)
        }
    }

    // MARK: - Focus flash

    private func triggerFocusFlash() {
        let generation = focusFlashAnimationGeneration + 1
        focusFlashAnimationGeneration = generation

        withAnimation(.easeIn(duration: 0.15)) {
            focusFlashOpacity = 0.6
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard focusFlashAnimationGeneration == generation else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                focusFlashOpacity = 0.0
            }
        }
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: AssistantMessage

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundColor(.blue)
                    .padding(.top, 3)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(message.content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(message.role == .user ? Color(white: 0.9) : Color(white: 0.75))
                    .textSelection(.enabled)

                if let target = message.pointTarget {
                    HStack(spacing: 4) {
                        Image(systemName: "scope")
                            .font(.system(size: 8))
                        Text(target.label)
                            .font(.system(size: 9, design: .monospaced))
                    }
                    .foregroundColor(.blue.opacity(0.7))
                    .padding(.top, 2)
                }
            }

            if message.role == .user {
                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .background(message.role == .user ? Color(white: 0.12) : Color(white: 0.06))
        .cornerRadius(6)
    }
}

// MARK: - Quick Action Chip

private struct QuickChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(white: 0.08))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundColor(Color(white: 0.5))
    }
}
