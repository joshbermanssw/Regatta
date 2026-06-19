import SwiftUI
import RegattaBrain

/// The macOS chat UI for the Regatta Brain rail section.
///
/// Displays a scrollable message list + a bottom input row. All user-facing
/// strings are localized (en + ja).
///
/// ## Snapshot-boundary rule
/// `messages` is read from the `@Observable` view-model at this level and
/// passed as **value snapshots** into ``BrainMessageRow`` — no observable
/// store reference escapes the `LazyVStack` / `ForEach` boundary.
struct BrainChatView: View {
    let viewModel: RegattaBrainViewModel

    @State private var inputText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            messageList
            inputRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            viewModel.startIfNeeded()
        }
    }

    // MARK: - Status banner

    @ViewBuilder
    private var statusBanner: some View {
        if case .failed(let reason) = viewModel.status {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 11))
                Text(String(
                    format: String(
                        localized: "brain.chat.status.failed",
                        defaultValue: "Claude not available: %@"
                    ),
                    reason
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        // Snapshot both messages and status at the BrainChatView level so no
        // @Observable store reference is read inside the LazyVStack closure
        // (snapshot-boundary rule — see CLAUDE.md).
        let snapshots: [BrainMessage] = viewModel.messages
        let isThinking: Bool = viewModel.status == .thinking
        let currentStatus: BrainStatus = viewModel.status

        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshots) { message in
                        // Pass VALUE snapshot — BrainMessage is a struct.
                        BrainMessageRow(message: message)
                            .id(message.id)
                    }
                    if isThinking {
                        thinkingIndicator
                            .id("__thinking__")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: snapshots.count) { _, _ in
                scrollToBottom(proxy: proxy, snapshots: snapshots)
            }
            .onChange(of: currentStatus) { _, newStatus in
                if newStatus == .thinking {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("__thinking__", anchor: .bottom)
                    }
                }
            }
            // Scroll to bottom when the last message's text grows (streaming).
            .onChange(of: snapshots.last?.text) { _, _ in
                scrollToBottom(proxy: proxy, snapshots: snapshots)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, snapshots: [BrainMessage]) {
        if let lastID = snapshots.last?.id {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    private var thinkingIndicator: some View {
        HStack(spacing: 4) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
            Text(String(localized: "brain.chat.thinking", defaultValue: "Thinking…"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Input row

    private var inputRow: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                TextField(
                    String(localized: "brain.chat.input.placeholder", defaultValue: "Message Brain…"),
                    text: $inputText,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .font(.system(size: 12))
                .textFieldStyle(.plain)
                .onSubmit {
                    submitIfNeeded()
                }

                Button {
                    submitIfNeeded()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? AnyShapeStyle(.tertiary)
                            : AnyShapeStyle(.tint))
                }
                .buttonStyle(.plain)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(String(localized: "brain.chat.send.a11y", defaultValue: "Send"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Actions

    private func submitIfNeeded() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Clear in the action, never in body.
        inputText = ""
        viewModel.send(trimmed)
    }
}

// MARK: - Message row

/// A single chat message bubble. Receives a `BrainMessage` **value snapshot** —
/// no `@Observable` / store reference is held here (snapshot-boundary rule).
private struct BrainMessageRow: View {
    let message: BrainMessage

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 24)
            }
            Text(message.text)
                .font(.system(size: 12))
                .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(message.role == .user
                            ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(.quaternary))
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
            if message.role == .assistant {
                Spacer(minLength: 24)
            }
        }
    }
}
