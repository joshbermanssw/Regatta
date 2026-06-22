import Foundation

// MARK: - Status Check Rollup decoding

/// The top-level shape returned by `gh pr view --json statusCheckRollup`.
struct PRViewStatusCheckRollupResponse: Decodable {
    let statusCheckRollup: [StatusCheckRollupItem]?
}

/// One entry in the `statusCheckRollup` array.
///
/// The `gh` CLI uses a polymorphic union (`StatusCheckRollupContext`) for
/// check-run vs commit-status entries. Both share `name`/`status`/`conclusion`
/// at the top level for check runs, while commit statuses use `context`/`state`
/// instead. We normalise both into ``PRCheck``.
struct StatusCheckRollupItem: Decodable {
    // Check run fields
    let name: String?
    let status: String?
    let conclusion: String?
    let detailsUrl: String?

    // Commit status fields (legacy Status API — `context` maps to name, `state` to status/conclusion)
    let context: String?
    let state: String?

    enum CodingKeys: String, CodingKey {
        case name, status, conclusion, detailsUrl
        case context, state
    }
}

extension StatusCheckRollupItem {
    /// Converts to a ``PRCheck``, normalising check-run and commit-status shapes.
    func toPRCheck() -> PRCheck? {
        if let name {
            // Check-run shape
            return PRCheck(
                name: name,
                status: status ?? "UNKNOWN",
                conclusion: conclusion,
                detailsURL: detailsUrl
            )
        } else if let context {
            // Commit-status shape — map `state` to both status and conclusion
            let mappedStatus = mapCommitState(state ?? "UNKNOWN")
            return PRCheck(
                name: context,
                status: mappedStatus.status,
                conclusion: mappedStatus.conclusion,
                detailsURL: detailsUrl
            )
        }
        return nil
    }

    /// Maps GitHub commit-status `state` values to the check-run `status`/`conclusion` vocabulary.
    private func mapCommitState(_ state: String) -> (status: String, conclusion: String?) {
        switch state.uppercased() {
        case "SUCCESS":
            return ("COMPLETED", "SUCCESS")
        case "FAILURE", "ERROR":
            return ("COMPLETED", "FAILURE")
        case "PENDING":
            return ("IN_PROGRESS", nil)
        default:
            return ("UNKNOWN", nil)
        }
    }
}

func parseChecks(from json: String) throws(GitHubCommandError) -> [PRCheck] {
    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    do {
        let response = try decoder.decode(PRViewStatusCheckRollupResponse.self, from: data)
        let items = response.statusCheckRollup ?? []
        return items.compactMap { $0.toPRCheck() }
    } catch {
        throw GitHubCommandError.jsonDecodingFailed(error.localizedDescription)
    }
}

// MARK: - Review Thread decoding

/// Top-level GraphQL response shape for review threads.
struct ReviewThreadGraphQLResponse: Decodable {
    let data: ReviewThreadData?
}

struct ReviewThreadData: Decodable {
    let repository: ReviewThreadRepository?
}

struct ReviewThreadRepository: Decodable {
    let pullRequest: ReviewThreadPullRequest?
}

struct ReviewThreadPullRequest: Decodable {
    let reviewThreads: ReviewThreadConnection?
}

struct ReviewThreadConnection: Decodable {
    let nodes: [ReviewThreadNode]?
}

struct ReviewThreadNode: Decodable {
    let id: String
    let isResolved: Bool
    let isOutdated: Bool
    let path: String
    let comments: ReviewCommentConnection?
}

struct ReviewCommentConnection: Decodable {
    let nodes: [ReviewCommentNode]?
}

struct ReviewCommentNode: Decodable {
    let id: String
    let body: String
    let author: ReviewCommentAuthor?
    let url: String
}

struct ReviewCommentAuthor: Decodable {
    let login: String
}

// MARK: - Conversation (issue) comment decoding

/// One node from `gh api repos/{owner}/{repo}/issues/{number}/comments`.
///
/// A PR is an issue for the comments endpoint, so the response is a flat JSON
/// array of these objects.
struct IssueCommentNode: Decodable {
    let id: Int
    let body: String?
    let user: IssueCommentUser?
    let htmlURL: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, body, user
        case htmlURL = "html_url"
        case createdAt = "created_at"
    }
}

struct IssueCommentUser: Decodable {
    let login: String
}

func parseConversationComments(from json: String) throws(GitHubCommandError) -> [PRConversationComment] {
    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    do {
        let nodes = try decoder.decode([IssueCommentNode].self, from: data)
        return nodes.map { node in
            PRConversationComment(
                id: String(node.id),
                body: node.body ?? "",
                author: node.user?.login ?? "",
                url: node.htmlURL ?? "",
                createdAt: node.createdAt ?? ""
            )
        }
    } catch {
        throw GitHubCommandError.jsonDecodingFailed(error.localizedDescription)
    }
}

func parseReviewThreads(from json: String) throws(GitHubCommandError) -> [ReviewThread] {
    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    do {
        let response = try decoder.decode(ReviewThreadGraphQLResponse.self, from: data)
        let nodes = response.data?.repository?.pullRequest?.reviewThreads?.nodes ?? []
        return nodes.map { node in
            let comments = node.comments?.nodes?.map { comment in
                ReviewComment(
                    id: comment.id,
                    body: comment.body,
                    author: comment.author?.login ?? "",
                    url: comment.url
                )
            } ?? []
            return ReviewThread(
                id: node.id,
                isResolved: node.isResolved,
                isOutdated: node.isOutdated,
                path: node.path,
                comments: comments
            )
        }
    } catch {
        throw GitHubCommandError.jsonDecodingFailed(error.localizedDescription)
    }
}
