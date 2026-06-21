import Foundation
import Testing
import RegattaFleet

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests for ``RegattaFleetViewModel``'s activity-log + fix-loop seams (#33).
///
/// These cover the per-PR projection the card binds to without driving the live
/// ``Fleet`` (which is the #30/#31 seam): the view model owns the activity log,
/// caps it, and clears it on dismiss.
@Suite("RegattaFleetViewModel activity + fix-loop seams")
@MainActor
struct RegattaFleetViewModelActivityTests {

    private func ref(_ number: Int = 1) -> PullRequestRef {
        PullRequestRef(owner: "joshbermanssw", repo: "regatta", number: number)
    }

    @Test("recordActivity appends per-PR entries")
    func recordAppends() {
        let vm = RegattaFleetViewModel()
        let pr = ref()
        vm.recordActivity(ShepherdActivityEntry(kind: .push, summary: "one"), for: pr)
        vm.recordActivity(ShepherdActivityEntry(kind: .reply, summary: "two"), for: pr)
        #expect(vm.activity(for: pr).map(\.summary) == ["one", "two"])
    }

    @Test("activity is isolated per PR")
    func activityIsolatedPerPR() {
        let vm = RegattaFleetViewModel()
        vm.recordActivity(ShepherdActivityEntry(kind: .push, summary: "a"), for: ref(1))
        vm.recordActivity(ShepherdActivityEntry(kind: .push, summary: "b"), for: ref(2))
        #expect(vm.activity(for: ref(1)).map(\.summary) == ["a"])
        #expect(vm.activity(for: ref(2)).map(\.summary) == ["b"])
    }

    @Test("activity log is capped at 50 entries, keeping the most recent")
    func activityCapped() {
        let vm = RegattaFleetViewModel()
        let pr = ref()
        for index in 0..<60 {
            vm.recordActivity(ShepherdActivityEntry(kind: .note, summary: "\(index)"), for: pr)
        }
        let log = vm.activity(for: pr)
        #expect(log.count == 50)
        #expect(log.first?.summary == "10")
        #expect(log.last?.summary == "59")
    }

    @Test("setFixLoop sets and clears the per-PR fix loop")
    func fixLoopSetClear() {
        let vm = RegattaFleetViewModel()
        let pr = ref()
        #expect(vm.fixLoop(for: pr) == nil)
        vm.setFixLoop(ShepherdFixLoopStatus(phase: .running, attempt: 1), for: pr)
        #expect(vm.fixLoop(for: pr)?.phase == .running)
        vm.setFixLoop(nil, for: pr)
        #expect(vm.fixLoop(for: pr) == nil)
    }

    @Test("dismiss clears the PR's activity log and fix loop")
    func dismissClearsState() {
        let vm = RegattaFleetViewModel()
        let pr = ref()
        vm.recordActivity(ShepherdActivityEntry(kind: .push, summary: "x"), for: pr)
        vm.setFixLoop(ShepherdFixLoopStatus(phase: .running), for: pr)
        vm.dismiss(pr)
        #expect(vm.activity(for: pr).isEmpty)
        #expect(vm.fixLoop(for: pr) == nil)
    }
}
