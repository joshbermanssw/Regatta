/// Canned JSON fixtures that simulate real `gh` CLI output.
enum Fixtures {
    // MARK: - Status check rollup

    /// Realistic `gh pr view --json statusCheckRollup` output with a mix of
    /// completed, pending, and failed check runs.
    static let statusCheckRollup = """
    {
      "statusCheckRollup": [
        {
          "name": "build",
          "status": "COMPLETED",
          "conclusion": "SUCCESS",
          "detailsUrl": "https://github.com/manaflow-ai/cmux/actions/runs/1234/jobs/5678"
        },
        {
          "name": "test (macos-14)",
          "status": "COMPLETED",
          "conclusion": "SUCCESS",
          "detailsUrl": "https://github.com/manaflow-ai/cmux/actions/runs/1234/jobs/5679"
        },
        {
          "name": "lint",
          "status": "IN_PROGRESS",
          "conclusion": null,
          "detailsUrl": "https://github.com/manaflow-ai/cmux/actions/runs/1234/jobs/5680"
        }
      ]
    }
    """

    /// A check rollup where one check has failed.
    static let statusCheckRollupWithFailure = """
    {
      "statusCheckRollup": [
        {
          "name": "build",
          "status": "COMPLETED",
          "conclusion": "SUCCESS",
          "detailsUrl": null
        },
        {
          "name": "test (macos-14)",
          "status": "COMPLETED",
          "conclusion": "FAILURE",
          "detailsUrl": "https://github.com/manaflow-ai/cmux/actions/runs/9999/jobs/0001"
        }
      ]
    }
    """

    /// An empty `statusCheckRollup` — the PR has no CI checks wired up.
    static let statusCheckRollupEmpty = """
    {
      "statusCheckRollup": []
    }
    """

    /// A null `statusCheckRollup` field — some PRs omit the key entirely.
    static let statusCheckRollupNull = """
    {
      "statusCheckRollup": null
    }
    """

    /// A legacy commit-status entry (GitHub Status API, not check-runs).
    static let statusCheckRollupWithCommitStatus = """
    {
      "statusCheckRollup": [
        {
          "context": "ci/circleci: build",
          "state": "success",
          "detailsUrl": "https://circleci.com/gh/org/repo/123"
        }
      ]
    }
    """

    /// Malformed JSON — not valid JSON at all.
    static let malformedJSON = "this is not JSON {{"

    /// Valid JSON but wrong shape (missing `statusCheckRollup`).
    static let wrongShape = """
    { "unexpectedKey": 42 }
    """

    // MARK: - Review threads

    /// Realistic GraphQL review-thread response with two threads (one resolved, one open).
    static let reviewThreads = """
    {
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": [
                {
                  "id": "PRRT_kwDOBcDe8M5ABC123",
                  "isResolved": false,
                  "isOutdated": false,
                  "path": "Sources/Regatta/GitHubPoller.swift",
                  "comments": {
                    "nodes": [
                      {
                        "id": "PRRC_kwDOBcDe8M5ABC456",
                        "body": "This looks like it could throw unexpectedly on empty input.",
                        "author": { "login": "alice" },
                        "url": "https://github.com/manaflow-ai/cmux/pull/28#discussion_r111"
                      },
                      {
                        "id": "PRRC_kwDOBcDe8M5ABC789",
                        "body": "Good catch — will fix in follow-up.",
                        "author": { "login": "bob" },
                        "url": "https://github.com/manaflow-ai/cmux/pull/28#discussion_r112"
                      }
                    ]
                  }
                },
                {
                  "id": "PRRT_kwDOBcDe8M5DEF123",
                  "isResolved": true,
                  "isOutdated": false,
                  "path": "Tests/RegattaGitHubTests/GitHubPollerTests.swift",
                  "comments": {
                    "nodes": [
                      {
                        "id": "PRRC_kwDOBcDe8M5DEF456",
                        "body": "Add a test for the empty-checks case.",
                        "author": { "login": "alice" },
                        "url": "https://github.com/manaflow-ai/cmux/pull/28#discussion_r113"
                      }
                    ]
                  }
                }
              ]
            }
          }
        }
      }
    }
    """

    /// Review threads response with no threads.
    static let reviewThreadsEmpty = """
    {
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": []
            }
          }
        }
      }
    }
    """

    /// An outdated review thread.
    static let reviewThreadsOutdated = """
    {
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": [
                {
                  "id": "PRRT_outdated",
                  "isResolved": false,
                  "isOutdated": true,
                  "path": "README.md",
                  "comments": {
                    "nodes": [
                      {
                        "id": "PRRC_outdated_1",
                        "body": "Outdated comment.",
                        "author": { "login": "carol" },
                        "url": "https://github.com/manaflow-ai/cmux/pull/28#discussion_r114"
                      }
                    ]
                  }
                }
              ]
            }
          }
        }
      }
    }
    """
}
