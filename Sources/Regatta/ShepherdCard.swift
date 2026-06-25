import SwiftUI
import Foundation
import RegattaFleet
import RegattaGitHub

// MARK: - ShepherdCard

/// The PR shepherd UI card (issue #33).
///
/// One card per watched pull request. It stacks five sections inside a single
/// bordered container:
///
/// 1. **Header** — a phase-coloured dot, the PR title, a one-line summary, and a
///    dismiss button.
/// 2. **Fix loop** — a banner shown only while a ci-fix loop is running / has
///    just resolved (#30 seam).
/// 3. **CI checks** — live per-check rows with pass / fail / running status.
/// 4. **Review threads** — per-thread rows tagged resolved / replied /
///    addressing (#31 derives the richer signal).
/// 5. **Activity + autonomy** — the time-ordered activity log, then the reused
///    #32 autonomy toggle and pending-approval queue.
///
/// ## Snapshot-boundary rule (CLAUDE.md)
/// Receives a ``ShepherdCardModel`` **value snapshot** plus a
/// ``ShepherdCardActions`` closure bundle — no view-model / `Fleet` reference is
/// held, so an orthogonal store change cannot invalidate the card row.
struct ShepherdCard: View {
    let model: ShepherdCardModel
    let actions: ShepherdCardActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if case .paused(let reason, let retryAfter) = model.state.phase {
                pausedBanner(reason: reason, retryAfter: retryAfter)
            }
            if let attention = model.state.needsAttention {
                needsAttentionBanner(reason: attention)
            }
            if let fixLoop = model.fixLoop {
                fixLoopBanner(fixLoop)
            }
            checksSection
            if !model.threadRows.isEmpty {
                threadsSection
            }
            if !model.conversationRows.isEmpty {
                conversationSection
            }
            if !model.reviewRows.isEmpty {
                reviewsSection
            }
            if !model.activity.isEmpty {
                activitySection
            }
            autonomySection
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ShepherdCard")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            statusDot
            VStack(alignment: .leading, spacing: 1) {
                Text(model.state.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(summaryLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: actions.onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                String(localized: "fleet.shepherd.dismiss.a11y", defaultValue: "Dismiss shepherd")
            )
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 7, height: 7)
    }

    private var dotColor: Color {
        if model.state.needsAttention != nil { return .orange }
        switch model.state.phase {
        case .starting: return .gray
        case .failed: return .yellow
        case .paused: return .orange
        case .watching:
            switch model.ciRollup {
            case .failing: return .red
            case .passing: return .green
            case .running, .none: return .blue
            }
        }
    }

    /// The header's one-line summary: CI rollup plus open-thread count, or the
    /// watcher phase when it has no data yet.
    private var summaryLine: String {
        switch model.state.phase {
        case .starting:
            return String(localized: "fleet.shepherd.starting", defaultValue: "Starting…")
        case .failed(let reason):
            return String(
                format: String(localized: "fleet.shepherd.failed", defaultValue: "Poll failed: %@"),
                reason
            )
        case .paused(let reason, _):
            return String(
                format: String(localized: "fleet.shepherd.paused", defaultValue: "Paused: %@"),
                reason
            )
        case .watching:
            var parts: [String] = [ciLabel]
            let open = model.openThreadCount
            if open > 0 {
                parts.append(String(
                    format: String(localized: "fleet.shepherd.threads", defaultValue: "%lld open threads"),
                    open
                ))
            }
            let comments = model.conversationCount
            if comments > 0 {
                parts.append(String(
                    format: String(localized: "fleet.shepherd.comments", defaultValue: "%lld comments"),
                    comments
                ))
            }
            let reviews = model.reviewCount
            if reviews > 0 {
                parts.append(String(
                    format: String(localized: "fleet.shepherd.reviews", defaultValue: "%lld reviews"),
                    reviews
                ))
            }
            return parts.joined(separator: " · ")
        }
    }

    private var ciLabel: String {
        switch model.ciRollup {
        case .none: return String(localized: "fleet.shepherd.ci.none", defaultValue: "No checks")
        case .failing: return String(localized: "fleet.shepherd.ci.failing", defaultValue: "CI failing")
        case .passing: return String(localized: "fleet.shepherd.ci.passing", defaultValue: "CI passing")
        case .running: return String(localized: "fleet.shepherd.ci.pending", defaultValue: "CI running")
        }
    }

    // MARK: - Fix-loop banner (#30 seam)

    @ViewBuilder
    private func fixLoopBanner(_ status: ShepherdFixLoopStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: fixLoopIcon(status.phase))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(fixLoopColor(status.phase))
                .symbolEffect(.pulse, options: .repeating, isActive: status.phase == .running)
            Text(fixLoopText(status))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fixLoopColor(status.phase).opacity(0.12))
        )
        .accessibilityIdentifier("ShepherdFixLoopBanner")
        .accessibilityElement(children: .combine)
    }

    private func fixLoopIcon(_ phase: ShepherdFixLoopStatus.Phase) -> String {
        switch phase {
        case .running: return "wrench.and.screwdriver"
        case .succeeded: return "checkmark.seal"
        case .gaveUp: return "exclamationmark.triangle"
        }
    }

    private func fixLoopColor(_ phase: ShepherdFixLoopStatus.Phase) -> Color {
        switch phase {
        case .running: return .blue
        case .succeeded: return .green
        case .gaveUp: return .orange
        }
    }

    private func fixLoopText(_ status: ShepherdFixLoopStatus) -> String {
        switch status.phase {
        case .running:
            if let check = status.failingCheck {
                return String(
                    format: String(
                        localized: "fleet.fixloop.running.check",
                        defaultValue: "Fixing %@ (attempt %lld)…"
                    ),
                    check, status.attempt
                )
            }
            return String(
                format: String(localized: "fleet.fixloop.running", defaultValue: "Fixing CI (attempt %lld)…"),
                status.attempt
            )
        case .succeeded:
            return String(localized: "fleet.fixloop.succeeded", defaultValue: "Fix pushed; CI recovered")
        case .gaveUp(let reason):
            return String(
                format: String(
                    localized: "fleet.fixloop.gaveup",
                    defaultValue: "Gave up — needs attention: %@"
                ),
                reason
            )
        }
    }

    // MARK: - Paused banner (gh auth / rate-limit, issue #35)

    /// A prominent banner shown while the shepherd is paused after a `gh` auth or
    /// rate-limit failure and is backing off before retrying.
    @ViewBuilder
    private func pausedBanner(reason: String, retryAfter: Duration) -> some View {
        statusBanner(
            icon: "pause.circle.fill",
            tint: .orange,
            text: String(
                format: String(
                    localized: "fleet.shepherd.paused.banner",
                    defaultValue: "Polling paused — %1$@. Retrying in %2$@."
                ),
                reason,
                Self.backoffText(retryAfter)
            ),
            identifier: "ShepherdPausedBanner"
        )
    }

    /// A short human label for a backoff duration, e.g. "30s" or "2m".
    private static func backoffText(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        if seconds >= 60 {
            let minutes = seconds / 60
            return String(
                format: String(localized: "fleet.shepherd.backoff.minutes", defaultValue: "%lldm"),
                minutes
            )
        }
        return String(
            format: String(localized: "fleet.shepherd.backoff.seconds", defaultValue: "%llds"),
            seconds
        )
    }

    // MARK: - Needs-attention banner (CI never green, issue #35)

    /// A prominent banner shown when the shepherd gave up automating the PR (the
    /// ci-fix loop hit its cap) and stopped auto-pushing; the human must step in.
    @ViewBuilder
    private func needsAttentionBanner(reason: String) -> some View {
        statusBanner(
            icon: "exclamationmark.triangle.fill",
            tint: .orange,
            text: String(
                format: String(
                    localized: "fleet.shepherd.needsAttention.banner",
                    defaultValue: "Needs attention — %@. Auto-push stopped."
                ),
                reason
            ),
            identifier: "ShepherdNeedsAttentionBanner"
        )
    }

    /// Shared layout for the failure-state banners (paused / needs attention).
    private func statusBanner(
        icon: String,
        tint: Color,
        text: String,
        identifier: String
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .accessibilityIdentifier(identifier)
        .accessibilityElement(children: .combine)
    }

    // MARK: - CI checks

    private var checksSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionLabel(String(localized: "fleet.section.checks", defaultValue: "Checks"))
            if model.checkRows.isEmpty {
                Text(String(localized: "fleet.checks.empty", defaultValue: "No checks reported yet"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.checkRows) { row in
                    HStack(spacing: 6) {
                        Image(systemName: checkIcon(row.status))
                            .font(.system(size: 9))
                            .foregroundStyle(checkColor(row.status))
                            .symbolEffect(.pulse, options: .repeating, isActive: row.status == .running)
                        Text(row.name)
                            .font(.system(size: 10))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func checkIcon(_ status: ShepherdCardModel.CheckRow.Status) -> String {
        switch status {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .running: return "clock"
        }
    }

    private func checkColor(_ status: ShepherdCardModel.CheckRow.Status) -> Color {
        switch status {
        case .passed: return .green
        case .failed: return .red
        case .running: return .blue
        }
    }

    // MARK: - Review threads

    private var threadsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionLabel(String(localized: "fleet.section.threads", defaultValue: "Review threads"))
            ForEach(model.threadRows) { row in
                HStack(spacing: 6) {
                    threadBadge(row.status)
                    Text(row.path)
                        .font(.system(size: 10))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(threadAccessibility(row))
            }
        }
    }

    private func threadBadge(_ status: ShepherdCardModel.ThreadStatus) -> some View {
        Text(threadStatusText(status))
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(threadStatusColor(status))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(threadStatusColor(status).opacity(0.15))
            )
    }

    private func threadStatusText(_ status: ShepherdCardModel.ThreadStatus) -> String {
        switch status {
        case .resolved: return String(localized: "fleet.thread.resolved", defaultValue: "Resolved")
        case .replied: return String(localized: "fleet.thread.replied", defaultValue: "Replied")
        case .addressing: return String(localized: "fleet.thread.addressing", defaultValue: "Addressing")
        }
    }

    private func threadStatusColor(_ status: ShepherdCardModel.ThreadStatus) -> Color {
        switch status {
        case .resolved: return .green
        case .replied: return .blue
        case .addressing: return .orange
        }
    }

    private func threadAccessibility(_ row: ShepherdCardModel.ThreadRow) -> String {
        String(
            format: String(
                localized: "fleet.thread.a11y",
                defaultValue: "Review thread on %1$@, %2$@"
            ),
            row.path, threadStatusText(row.status)
        )
    }

    // MARK: - Conversation comments

    /// The PR conversation-comment section. Each row shows the author and comment
    /// text; the shepherd's own replies are shown muted (and are never reacted to,
    /// per the loop guard).
    private var conversationSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionLabel(conversationSectionTitle)
            ForEach(model.conversationRows) { row in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: row.isSelf ? "arrowshape.turn.up.left" : "bubble.left")
                        .font(.system(size: 9))
                        .foregroundStyle(row.isSelf ? .tertiary : .secondary)
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.author.isEmpty ? unknownAuthor : row.author)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(row.isSelf ? .tertiary : .secondary)
                            .lineLimit(1)
                        Text(row.body)
                            .font(.system(size: 10))
                            .foregroundStyle(row.isSelf ? .secondary : .primary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(conversationAccessibility(row))
            }
        }
    }

    /// The conversation section header, including the actionable-comment count.
    private var conversationSectionTitle: String {
        let count = model.conversationCount
        guard count > 0 else {
            return String(localized: "fleet.section.conversation", defaultValue: "Conversation")
        }
        return String(
            format: String(
                localized: "fleet.section.conversation.count",
                defaultValue: "Conversation (%lld)"
            ),
            count
        )
    }

    private var unknownAuthor: String {
        String(localized: "fleet.conversation.unknownAuthor", defaultValue: "Someone")
    }

    private func conversationAccessibility(_ row: ShepherdCardModel.ConversationRow) -> String {
        if row.isSelf {
            return String(
                format: String(
                    localized: "fleet.conversation.a11y.self",
                    defaultValue: "Your reply: %@"
                ),
                row.body
            )
        }
        return String(
            format: String(
                localized: "fleet.conversation.a11y",
                defaultValue: "Comment from %1$@: %2$@"
            ),
            row.author.isEmpty ? unknownAuthor : row.author, row.body
        )
    }

    // MARK: - Reviews (review summaries)

    /// The submitted-review section. Each row shows a verdict badge (Approved /
    /// Changes requested / Commented), the reviewer, and the review summary
    /// snippet. The shepherd's own reviews are shown muted (never reacted to).
    private var reviewsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionLabel(reviewsSectionTitle)
            ForEach(model.reviewRows) { row in
                HStack(alignment: .top, spacing: 6) {
                    reviewBadge(row.badge)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.author.isEmpty ? unknownAuthor : row.author)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(row.isSelf ? .tertiary : .secondary)
                            .lineLimit(1)
                        if !row.body.isEmpty {
                            Text(row.body)
                                .font(.system(size: 10))
                                .foregroundStyle(row.isSelf ? .secondary : .primary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(reviewAccessibility(row))
            }
        }
    }

    /// The reviews section header, including the actionable-review count.
    private var reviewsSectionTitle: String {
        let count = model.reviewCount
        guard count > 0 else {
            return String(localized: "fleet.section.reviews", defaultValue: "Reviews")
        }
        return String(
            format: String(
                localized: "fleet.section.reviews.count",
                defaultValue: "Reviews (%lld)"
            ),
            count
        )
    }

    private func reviewBadge(_ badge: ShepherdCardModel.ReviewBadge) -> some View {
        Text(reviewBadgeText(badge))
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(reviewBadgeColor(badge))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(reviewBadgeColor(badge).opacity(0.15))
            )
    }

    private func reviewBadgeText(_ badge: ShepherdCardModel.ReviewBadge) -> String {
        switch badge {
        case .approved:
            return String(localized: "fleet.review.approved", defaultValue: "Approved")
        case .changesRequested:
            return String(localized: "fleet.review.changesRequested", defaultValue: "Changes requested")
        case .commented:
            return String(localized: "fleet.review.commented", defaultValue: "Commented")
        case .other:
            return String(localized: "fleet.review.other", defaultValue: "Review")
        }
    }

    private func reviewBadgeColor(_ badge: ShepherdCardModel.ReviewBadge) -> Color {
        switch badge {
        case .approved: return .green
        case .changesRequested: return .orange
        case .commented: return .blue
        case .other: return .secondary
        }
    }

    private func reviewAccessibility(_ row: ShepherdCardModel.ReviewRow) -> String {
        if row.isSelf {
            return String(
                format: String(
                    localized: "fleet.review.a11y.self",
                    defaultValue: "Your review (%1$@): %2$@"
                ),
                reviewBadgeText(row.badge), row.body
            )
        }
        return String(
            format: String(
                localized: "fleet.review.a11y",
                defaultValue: "Review from %1$@ (%2$@): %3$@"
            ),
            row.author.isEmpty ? unknownAuthor : row.author, reviewBadgeText(row.badge), row.body
        )
    }

    // MARK: - Activity log

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionLabel(String(localized: "fleet.section.activity", defaultValue: "Activity"))
            ForEach(model.activity) { entry in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: activityIcon(entry.kind))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.summary)
                            .font(.system(size: 10))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(Self.timeFormatter.string(from: entry.timestamp))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func activityIcon(_ kind: ShepherdActivityEntry.Kind) -> String {
        switch kind {
        case .push: return "arrow.up.circle"
        case .reply: return "arrowshape.turn.up.left"
        case .resolve: return "checkmark.bubble"
        case .fixLoop: return "wrench.and.screwdriver"
        case .note: return "info.circle"
        }
    }

    /// Short time-of-day formatter for activity timestamps. `static` so it is
    /// built once, not per row (formatter construction is expensive).
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    // MARK: - Autonomy + approvals (reused from #32)

    private var autonomySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(String(localized: "fleet.autonomy.label", defaultValue: "Autonomy"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                autonomyPicker
                Spacer(minLength: 0)
            }
            if !model.pending.isEmpty {
                pendingApprovals
            }
        }
    }

    /// The per-PR autonomy mode picker, reused unchanged from #32: stage-for-
    /// approval vs auto-push & resolve. Changeable at any time.
    private var autonomyPicker: some View {
        Picker(
            selection: Binding(
                get: { model.state.autonomyMode },
                set: { actions.onSetMode($0) }
            )
        ) {
            Text(String(localized: "fleet.autonomy.staged", defaultValue: "Stage for approval"))
                .tag(AutonomyMode.staged)
            Text(String(localized: "fleet.autonomy.auto", defaultValue: "Auto-push & resolve"))
                .tag(AutonomyMode.auto)
        } label: {
            Text(String(localized: "fleet.autonomy.label", defaultValue: "Autonomy"))
        }
        .pickerStyle(.menu)
        .controlSize(.mini)
        .labelsHidden()
        .font(.system(size: 10))
        .accessibilityIdentifier("FleetAutonomyPicker")
        .accessibilityLabel(
            String(localized: "fleet.autonomy.a11y", defaultValue: "Autonomy mode for this pull request")
        )
        .help(String(
            localized: "fleet.autonomy.tooltip",
            defaultValue: "Stage holds push/reply/resolve for your approval; Auto runs them immediately"
        ))
    }

    /// The queue of actions awaiting approval in staged mode, reused from #32,
    /// each with an approve/reject pair.
    ///
    /// Made prominent (issue: pending approvals must be obvious): a counted
    /// header, an amber-tinted container, and per-action rows that spell out what
    /// the action will do plus large Approve / Reject controls.
    private var pendingApprovals: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(pendingSectionTitle)
            ForEach(model.pending) { action in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: pendingIcon(action.kind))
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pendingActionTitle(action.kind))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(action.summary)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button {
                        actions.onApprove(action.id)
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "fleet.pending.approve.help", defaultValue: "Run this action now"))
                    .accessibilityLabel(
                        String(localized: "fleet.pending.approve.a11y", defaultValue: "Approve action")
                    )
                    Button {
                        actions.onReject(action.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "fleet.pending.reject.help", defaultValue: "Discard this action"))
                    .accessibilityLabel(
                        String(localized: "fleet.pending.reject.a11y", defaultValue: "Reject action")
                    )
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .accessibilityIdentifier("ShepherdPendingApprovals")
    }

    /// The pending-approval section header, including how many are waiting.
    private var pendingSectionTitle: String {
        String.localizedStringWithFormat(
            String(localized: "fleet.section.pending.count", defaultValue: "Pending approval (%lld)"),
            model.pending.count
        )
    }

    /// A short verb describing what a pending action will do when approved.
    private func pendingActionTitle(_ kind: ActionKind) -> String {
        switch kind {
        case .push: return String(localized: "fleet.pending.title.push", defaultValue: "Push commit")
        case .reply: return String(localized: "fleet.pending.title.reply", defaultValue: "Post reply")
        case .resolve: return String(localized: "fleet.pending.title.resolve", defaultValue: "Resolve thread")
        }
    }

    private func pendingIcon(_ kind: ActionKind) -> String {
        switch kind {
        case .push: return "arrow.up.circle"
        case .reply: return "arrowshape.turn.up.left"
        case .resolve: return "checkmark.bubble"
        }
    }

    // MARK: - Shared

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
    }
}
