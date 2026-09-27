import SwiftUI

#if DEBUG
struct ChatScreen: View {
    @State private var store = ChatDemoStore()

    var body: some View {
        VStack(spacing: 0) {
            ChatTranscriptView(messages: store.messages)
                .ignoresSafeArea(.keyboard, edges: .bottom)

            Divider()

            ComposerView(text: $store.draft, onSend: store.sendDraft)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
        }
        .navigationTitle("Native Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Reset") {
                    store.reset()
                }
                .accessibilityIdentifier("resetChat")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("2,000 messages") {
                    store.loadStressConversation(count: 2_000)
                }
                .accessibilityIdentifier("loadStress")
            }
        }
    }
}
#endif

private struct ComposerView: View {
    @Binding var text: String
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .onSubmit(onSend)
                .accessibilityIdentifier("composerField")

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("sendMessage")
        }
    }
}
