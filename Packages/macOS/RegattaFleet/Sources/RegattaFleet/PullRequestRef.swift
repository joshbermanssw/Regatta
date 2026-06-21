import Foundation

/// A stable identity for a pull request being shepherded.
///
/// The triple of `owner`, `repo`, and `number` uniquely identifies a PR on
/// GitHub. ``Fleet`` keys its shepherds on this value so handing the same PR
/// off twice is idempotent — the second handoff returns the existing shepherd
/// rather than creating a duplicate.
///
/// `owner` and `repo` are normalised to lowercase on construction because
/// GitHub treats repository slugs case-insensitively; `Octocat/Hello-World`
/// and `octocat/hello-world` are the same repository and must collapse to one
/// shepherd.
public struct PullRequestRef: Sendable, Equatable, Hashable, Identifiable, Codable {
    /// The repository owner (user or organisation), normalised to lowercase.
    public let owner: String
    /// The repository name, normalised to lowercase.
    public let repo: String
    /// The pull-request number.
    public let number: Int

    /// A stable string identity, `"owner/repo#number"`, suitable for use as a
    /// SwiftUI `Identifiable` id and as a dictionary key.
    public var id: String { "\(owner)/\(repo)#\(number)" }

    /// The repository slug, `"owner/repo"`, as `gh` expects via `--repo`.
    public var repoSlug: String { "\(owner)/\(repo)" }

    /// Creates a pull-request reference.
    ///
    /// - Parameters:
    ///   - owner: The repository owner; lowercased for case-insensitive identity.
    ///   - repo: The repository name; lowercased for case-insensitive identity.
    ///   - number: The pull-request number.
    public init(owner: String, repo: String, number: Int) {
        self.owner = owner.lowercased()
        self.repo = repo.lowercased()
        self.number = number
    }

    /// Parses a `PullRequestRef` from a repository label and PR number.
    ///
    /// The label is the `owner/repo` slug carried by an attached tab's PR
    /// descriptor (e.g. `"manaflow-ai/cmux"`). Surrounding whitespace and a
    /// leading `@` (occasionally present in copied slugs) are stripped.
    ///
    /// - Parameters:
    ///   - label: A `"owner/repo"` slug.
    ///   - number: The pull-request number.
    /// - Returns: A `PullRequestRef`, or `nil` when the label does not contain
    ///   exactly one `/` separating a non-empty owner and repo.
    public static func parse(label: String, number: Int) -> PullRequestRef? {
        let trimmed = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0])
        let repo = String(parts[1])
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return PullRequestRef(owner: owner, repo: repo, number: number)
    }
}
