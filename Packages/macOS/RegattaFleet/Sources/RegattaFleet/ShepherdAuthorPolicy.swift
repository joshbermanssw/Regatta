/// The shared rule set deciding whether a comment's **author** makes the item
/// something the shepherd should act on.
///
/// Both reactive layers — ``ReviewThreadReactor`` and
/// ``ConversationCommentReactor`` — consult this policy so the skip rules stay
/// identical across the inline-review and conversation surfaces:
///
/// - **Bot authors are never actionable.** A login ending in `[bot]` (e.g.
///   `vercel[bot]`, `github-actions[bot]`) is an automated comment; reacting to
///   it would spawn pointless workers.
/// - **The current user's own items are never actionable.** A comment authored
///   by the authenticated `gh` user is either the shepherd's own reply (the
///   self-reply loop) or the user's own remark; in both cases there is nothing
///   to address.
///
/// "Already answered" (the current user replied *after* a comment) is a sequence
/// property of a thread / timeline, so it is decided by the reactors using
/// ``isActionableAuthor(_:)`` over the relevant comment — not by this value type
/// in isolation.
///
/// ## Resilience
/// `selfLogin` is `nil` when the authenticated login could not be resolved. In
/// that case the policy still skips bots (a syntactic check that needs no login)
/// and simply cannot apply the self-author rule — it never starts treating
/// everything as actionable.
///
/// ## Concurrency
/// A `Sendable` value type with no mutable state; safe to capture in any actor.
struct ShepherdAuthorPolicy: Sendable, Equatable {
    /// The authenticated `gh` user's login, or `nil` when it could not be
    /// resolved this poll.
    let selfLogin: String?

    /// The suffix that marks an automated (bot) account login on GitHub.
    static let botSuffix = "[bot]"

    /// Creates a policy bound to the (optional) current-user login.
    ///
    /// - Parameter selfLogin: The authenticated `gh` login, or `nil`.
    init(selfLogin: String?) {
        self.selfLogin = selfLogin
    }

    /// Whether `author` is an automated bot account (login ends in `[bot]`).
    func isBot(_ author: String) -> Bool {
        author.hasSuffix(Self.botSuffix)
    }

    /// Whether `author` is the authenticated current user.
    ///
    /// Always `false` when ``selfLogin`` is `nil` or empty — an unresolved login
    /// must never cause the shepherd to skip a genuine reviewer.
    func isSelf(_ author: String) -> Bool {
        guard let selfLogin, !selfLogin.isEmpty else { return false }
        return author == selfLogin
    }

    /// Whether a comment authored by `author` is actionable on author grounds:
    /// it is neither a bot nor the current user.
    func isActionableAuthor(_ author: String) -> Bool {
        !isBot(author) && !isSelf(author)
    }
}
