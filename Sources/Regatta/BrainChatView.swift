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
///
/// ## Attach-tab context
/// Pass a `contextProvider` closure that returns the active workspace's
/// ``AttachedTabContext`` when tapped. The closure is called lazily inside a
/// `Button` action (never from `body`), so it is safe with Swift 6
/// `@MainActor` isolation.
struct BrainChatView: View {
    let viewModel: RegattaBrainViewModel
    /// Returns the current workspace context when the "＋ Attach tab" button
    /// is tapped. Pass `nil` (or a closure returning `nil`) when no workspace
    /// context is available.
    ///
    /// The closure is `@MainActor`-isolated because `TabManager.selectedWorkspace`
    /// (the source of truth) is also main-actor-bound.
    let contextProvider: (@MainActor () -> AttachedTabContext?)?

    @State private var inputText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            messageList
            contextChip
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
            // Cap the conversation height so a long chat scrolls *within* the
            // Brain section instead of growing unbounded and pushing the Fleet
            // and Memory sections down the rail. (A scroll view nested in the
            // rail's outer scroll view otherwise expands to fit all its content.)
            .frame(maxHeight: Self.maxMessageListHeight)
        }
    }

    /// Maximum height of the scrollable conversation before it scrolls internally.
    private static let maxMessageListHeight: CGFloat = 380

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

    // MARK: - Context chip

    /// A dismissible chip row that appears above the input row when a
    /// workspace context has been attached. Disappears when the user taps ✕.
    @ViewBuilder
    private var contextChip: some View {
        // Snapshot the context at the BrainChatView level — never read the
        // @Observable store inside a conditional expression that runs on
        // every body evaluation.
        let ctx: AttachedTabContext? = viewModel.attachedContext
        if let ctx {
            HStack(spacing: 4) {
                Image(systemName: "paperclip")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(contextChipLabel(for: ctx))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button {
                    // Capture in action — never mutate state from body.
                    viewModel.attachedContext = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(localized: "brain.attach.chip.remove.a11y", defaultValue: "Remove attached context")
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.08))
        }
    }

    /// Builds the display label for the context chip.
    private func contextChipLabel(for ctx: AttachedTabContext) -> String {
        let repoName = URL(fileURLWithPath: ctx.currentDirectory).lastPathComponent
        var parts: [String] = [repoName]
        if let branch = ctx.gitBranch {
            parts.append(branch)
        }
        if let pr = ctx.pullRequest {
            parts.append("PR #\(pr.number)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Input row

    private var inputRow: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                // "＋ Attach tab" affordance — only shown when a context
                // provider is available and no context is already attached.
                if contextProvider != nil, viewModel.attachedContext == nil {
                    Button {
                        // Capture context in the action, never in body.
                        if let ctx = contextProvider?() {
                            viewModel.attachedContext = ctx
                        }
                    } label: {
                        Label(
                            String(localized: "brain.attach.tab.label", defaultValue: "＋ Attach tab"),
                            systemImage: "plus.circle"
                        )
                        .labelStyle(.titleOnly)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(localized: "brain.attach.tab.a11y", defaultValue: "Attach active tab context")
                    )
                    .help(String(localized: "brain.attach.tab.tooltip", defaultValue: "Attach the active tab's repo, branch, and PR to the next message"))
                    Divider()
                        .frame(height: 14)
                }

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
