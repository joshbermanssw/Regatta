/// A snapshot of the active workspace tab's context, captured when the user
/// taps "＋ Attach tab" in the Brain composer.
///
/// All properties are plain value types so the struct is `Sendable`.
struct AttachedTabContext: Equatable, Sendable {
    /// The workspace's current working directory (absolute path).
    let currentDirectory: String
    /// The git branch name, if one was detected for the active panel.
    let gitBranch: String?
    /// A compact pull-request descriptor, if a PR was associated with the active panel.
    let pullRequest: AttachedTabPullRequest?
}

/// A pull-request descriptor carried inside ``AttachedTabContext``.
struct AttachedTabPullRequest: Equatable, Sendable {
    /// The PR number (e.g. `42`).
    let number: Int
    /// The repository label (e.g. `owner/repo`).
    let label: String
}
