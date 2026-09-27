import Foundation
import Observation

#if DEBUG
@MainActor
@Observable
final class ChatDemoStore {
    var messages: [ChatMessage] = [
        ChatMessage(
            role: .assistant,
            text: "This prototype renders the transcript with UIKit and keeps the surrounding app in SwiftUI."
        )
    ]

    var draft = ""
    private var streamTask: Task<Void, Never>?

    init() {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-rich-content") {
            messages = [
                ChatMessage(
                    role: .assistant,
                    text: """
                    ## Structured answer

                    Native text stays separate from executable examples.

                    ```swift
                    let renderer = "native"
                    print(renderer)
                    ```

                    | Feature | Status |
                    | --- | --- |
                    | Code cards | Native |
                    | Tables | Native |

                    The paragraph after the code block keeps its original order.
                    """
                ),
                ChatMessage(
                    role: .activity,
                    text: "Looked up the latest public references without exposing provider-specific tool internals.",
                    kind: .webSearch,
                    title: "Web search",
                    status: "completed",
                    durationMilliseconds: 1_350
                )
            ]
        } else if ProcessInfo.processInfo.arguments.contains("--stress-2000") {
            loadStressConversation(count: 2_000)
        }
    }

    func sendDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        draft = ""
        messages.append(ChatMessage(role: .user, text: trimmed))
        beginDemoResponse(for: trimmed)
    }

    func loadStressConversation(count: Int = 400) {
        streamTask?.cancel()
        messages = (0..<count).map { index in
            let role: ChatMessage.Role = index.isMultiple(of: 2) ? .user : .assistant
            let prefix = role == .user ? "User" : "Assistant"
            let body: String

            if role == .assistant, (index + 1).isMultiple(of: 20) {
                body = """
                **Native Markdown** stays inside the reusable collection-view cell.

                - Bold and *italic* text
                - Inline `code` without a WebView
                - Lists that wrap onto additional lines
                - A tappable [OpenAI link](https://openai.com)

                ![Swift logo](https://developer.apple.com/assets/elements/icons/swift/swift-64x64_2x.png)

                $$
                e^{i\\pi} + 1 = 0
                $$

                ```swift
                let renderer = "native"
                print(renderer)
                ```
                """
            } else if index.isMultiple(of: 7) {
                body = "Longer sample message used to exercise cached sizing, fast scrolling, and cell reuse. It intentionally wraps onto several lines without any web rendering layer."
            } else {
                body = "Native transcript sample message."
            }
            return ChatMessage(role: role, text: "\(prefix) \(index + 1): \(body)")
        }
    }

    func reset() {
        streamTask?.cancel()
        messages = [
            ChatMessage(role: .assistant, text: "Conversation reset. Send a message to simulate streaming.")
        ]
    }

    private func beginDemoResponse(for prompt: String) {
        streamTask?.cancel()

        let replyID = UUID()
        messages.append(ChatMessage(id: replyID, role: .assistant, text: ""))

        let response = """
        Received **\"\(prompt)\"**. This Markdown is arriving incrementally.

        - The transcript is a native `UICollectionView`.
        - Only the last assistant cell is reconfigured while streaming.
        - In the real app, chunks can come from your gateway or an official streaming endpoint.
        - Markdown links such as [OpenAI](https://openai.com) stay native and tappable.

        ![Swift logo](https://developer.apple.com/assets/elements/icons/swift/swift-64x64_2x.png)

        $$\\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$$

        ```swift
        let renderingLayer = "UIKit"
        ```
        """
        let chunks = streamChunks(from: response, maximumCharacters: 12)

        streamTask = Task { [weak self] in
            for chunk in chunks {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(35))
                guard let self else { return }
                guard let messageIndex = self.messages.firstIndex(where: { $0.id == replyID }) else { return }
                self.messages[messageIndex].text += chunk
            }
        }
    }

    private func streamChunks(from text: String, maximumCharacters: Int) -> [String] {
        precondition(maximumCharacters > 0)

        var result: [String] = []
        result.reserveCapacity(max(1, text.count / maximumCharacters))
        var start = text.startIndex

        while start < text.endIndex {
            let end = text.index(
                start,
                offsetBy: maximumCharacters,
                limitedBy: text.endIndex
            ) ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }

        return result
    }
}
#endif
