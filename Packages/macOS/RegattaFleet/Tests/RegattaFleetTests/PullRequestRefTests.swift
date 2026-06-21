import Testing
@testable import RegattaFleet

@Suite("PullRequestRef — identity & parsing")
struct PullRequestRefTests {
    @Test("normalises owner/repo to lowercase for case-insensitive identity")
    func normalisesCase() {
        let a = PullRequestRef(owner: "Manaflow-AI", repo: "Cmux", number: 28)
        let b = PullRequestRef(owner: "manaflow-ai", repo: "cmux", number: 28)
        #expect(a == b)
        #expect(a.id == b.id)
        #expect(a.id == "manaflow-ai/cmux#28")
    }

    @Test("different PR numbers are distinct identities")
    func distinctNumbers() {
        let a = PullRequestRef(owner: "o", repo: "r", number: 1)
        let b = PullRequestRef(owner: "o", repo: "r", number: 2)
        #expect(a != b)
    }

    @Test("repoSlug returns owner/repo for gh --repo")
    func repoSlug() {
        let ref = PullRequestRef(owner: "manaflow-ai", repo: "cmux", number: 5)
        #expect(ref.repoSlug == "manaflow-ai/cmux")
    }

    @Test("parses a well-formed owner/repo label")
    func parsesLabel() throws {
        let ref = try #require(PullRequestRef.parse(label: "manaflow-ai/cmux", number: 42))
        #expect(ref.owner == "manaflow-ai")
        #expect(ref.repo == "cmux")
        #expect(ref.number == 42)
    }

    @Test("trims whitespace and a stray leading @ when parsing")
    func parsesMessyLabel() throws {
        let ref = try #require(PullRequestRef.parse(label: "  @manaflow-ai/cmux  ", number: 7))
        #expect(ref.id == "manaflow-ai/cmux#7")
    }

    @Test("rejects labels without exactly one slash")
    func rejectsBadLabels() {
        #expect(PullRequestRef.parse(label: "noslash", number: 1) == nil)
        #expect(PullRequestRef.parse(label: "a/b/c", number: 1) == nil)
        #expect(PullRequestRef.parse(label: "/cmux", number: 1) == nil)
        #expect(PullRequestRef.parse(label: "owner/", number: 1) == nil)
    }
}
