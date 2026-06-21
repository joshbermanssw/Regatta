public import RegattaGitHub
public import Foundation

/// The kind of outward-facing action a shepherd can take on a pull request.
///
/// Every kind here is **gated** by the per-PR ``AutonomyMode``: in
/// ``AutonomyMode/staged`` it queues for approval; in ``AutonomyMode/auto`` it
/// runs immediately. #30/#31/#33 add concrete payloads behind these kinds; the
/// gate stays agnostic about *how* each action talks to GitHub.
public enum ActionKind: String, Sendable, Equatable, Codable, CaseIterable {
    /// Push commits to the PR branch (e.g. a fix the shepherd produced).
    case push
    /// Reply to a review thread / comment.
    case reply
    /// Resolve a review thread.
    case resolve
}

/// The execution status of a gated action, as the gate sees it.
public enum ActionStatus: String, Sendable, Equatable, Codable {
    /// Awaiting the user's approve/reject decision (``AutonomyMode/staged``).
    case pending
    /// Approved and currently executing, or about to.
    case executing
    /// Executed successfully.
    case completed
    /// Rejected by the user; never executed.
    case rejected
    /// Execution was attempted and threw.
    case failed
}

/// A value-typed description of one outward-facing action submitted to the
/// ``AutonomyGate``.
///
/// This is the **seam #30/#31 plug into**. The action carries everything the UI
/// needs to render an approval card — the PR it targets, its ``ActionKind``, a
/// human-readable `summary`, and an optional structured `payload` — plus an
/// opaque identity. The *execution* itself lives behind the
/// ``ActionExecuting`` seam, keyed by `id`, so this value stays `Sendable` and
/// free of closures that would prevent it crossing the actor boundary into the
/// `@MainActor` view layer.
///
/// ## Snapshot-boundary rule (CLAUDE.md)
/// `PendingAction` is a pure value (`Sendable`, `Equatable`, `Identifiable`).
/// It is the snapshot the gate hands to the view layer; no actor reference
/// escapes into a `ForEach`.
public struct PendingAction: Sendable, Equatable, Identifiable, Codable {
    /// Stable identity for this action instance (one per submission).
    public let id: UUID

    /// The pull request this action targets.
    public let pullRequest: PullRequestRef

    /// What kind of outward action this is (push/reply/resolve).
    public let kind: ActionKind

    /// A short human-readable description for the approval UI,
    /// e.g. `"Reply to review thread on line 42"`.
    public let summary: String

    /// An optional structured payload (#30/#31 fill this in: branch ref, comment
    /// body, thread id, …). Opaque to the gate; carried for the executor and UI.
    public let payload: ActionPayload?

    /// The current lifecycle status as the gate sees it.
    public let status: ActionStatus

    /// Creates a pending action.
    ///
    /// - Parameters:
    ///   - id: Stable identity. Defaults to a fresh `UUID`.
    ///   - pullRequest: The targeted PR.
    ///   - kind: The action kind.
    ///   - summary: Human-readable approval-card text.
    ///   - payload: Optional structured payload for the executor/UI.
    ///   - status: Lifecycle status. Defaults to ``ActionStatus/pending``.
    public init(
        id: UUID = UUID(),
        pullRequest: PullRequestRef,
        kind: ActionKind,
        summary: String,
        payload: ActionPayload? = nil,
        status: ActionStatus = .pending
    ) {
        self.id = id
        self.pullRequest = pullRequest
        self.kind = kind
        self.summary = summary
        self.payload = payload
        self.status = status
    }

    /// Returns a copy of this action with a new status.
    public func withStatus(_ newStatus: ActionStatus) -> PendingAction {
        PendingAction(
            id: id,
            pullRequest: pullRequest,
            kind: kind,
            summary: summary,
            payload: payload,
            status: newStatus
        )
    }
}

/// An opaque, value-typed payload bag carried alongside a ``PendingAction``.
///
/// Issue #32 does not implement any `gh` writes, so this is intentionally a
/// thin string-keyed bag rather than a closed enum: #30 (push) and #31
/// (reply/resolve) extend it with whatever fields their executor needs (branch
/// name, comment body, thread id) without forcing a change to the gate.
public struct ActionPayload: Sendable, Equatable, Codable {
    /// Free-form string fields, e.g. `["threadID": "RT_123", "body": "Fixed."]`.
    public var fields: [String: String]

    /// Creates a payload bag.
    public init(fields: [String: String] = [:]) {
        self.fields = fields
    }

    /// Convenience subscript over ``fields``.
    public subscript(key: String) -> String? {
        get { fields[key] }
        set { fields[key] = newValue }
    }
}
