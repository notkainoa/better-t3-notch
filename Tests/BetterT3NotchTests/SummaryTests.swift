import Foundation
import Testing
@testable import BetterT3Notch

/// The collapsed notch's one line, and which of T3's sidebar shelves a thread sits on.
@Suite struct SummaryTests {
    private func summary(_ statuses: [ThreadStatus]) -> NotchSummary {
        var s = NotchSummary()
        statuses.forEach { s.add($0) }
        return s
    }

    @Test func quietWhenNothingIsGoingOn() {
        let s = summary([.idle, .idle])
        #expect(s.isQuiet)
        #expect(s.text == nil)
    }

    @Test func workingOnlyCountsWork() {
        #expect(summary([.working, .connecting, .waiting, .idle]).text == "3 working")
        #expect(summary([.working]).text == "1 working")
    }

    @Test func oneKindSaysWhatItIs() {
        #expect(summary([.completed, .working, .working]).text == "1 done")
        #expect(summary([.failed, .failed]).text == "2 failed")
        #expect(summary([.planReady]).text == "1 plan ready")
        #expect(summary([.planReady, .planReady]).text == "2 plans ready")
        #expect(summary([.pendingApproval]).text == "1 needs you")
        // Approvals, questions and guest messages are all "a question for you".
        let asked = summary([.awaitingInput, .pendingApproval, .guestRequest])
        #expect(asked.text == "3 need you")
        #expect(asked.waiting == [.question])
    }

    @Test func mixedKindsNeedYouWithEveryIcon() {
        let s = summary([.completed, .awaitingInput, .working])
        #expect(s.text == "2 need you")
        #expect(s.waiting == [.question, .done])
        let all = summary([.completed, .failed, .planReady, .pendingApproval, .completed])
        #expect(all.text == "5 need you")
        #expect(all.waiting == [.question, .plan, .failed, .done])
    }

    /// Work keeps its own side while something waits: "6 working" and "2 need you" side by side.
    @Test func workingStaysBesideWhatWaits() {
        let s = summary(Array(repeating: .working, count: 6) + [.completed, .awaitingInput])
        #expect(s.text == "2 need you")
        #expect(s.workingAside == "6 working")
        #expect(s.waiting == [.question, .done])
        let one = summary([.planReady, .waiting])
        #expect(one.text == "1 plan ready")
        #expect(one.workingAside == "1 working")
    }

    /// The notch sizes each side for what sits there: the work on the left by default, what
    /// waits on the left with "What needs you sits on: Left".
    @MainActor @Test func sidesFollowTheSetting() {
        let saved = UserDefaults.standard.object(forKey: "needsYouOnLeft")
        defer { UserDefaults.standard.set(saved, forKey: "needsYouOnLeft") }
        let s = summary(Array(repeating: .working, count: 6) + [.completed, .awaitingInput])
        UserDefaults.standard.removeObject(forKey: "needsYouOnLeft")
        #expect(!Settings.needsYouOnLeft)
        let right = StatusPill.widths(s)
        #expect(right.left < right.right) // spinner + "6 working" vs two icons + "2 need you"
        Settings.needsYouOnLeft = true
        let left = StatusPill.widths(s)
        #expect(left.left == right.right && left.right == right.left)
        // Nothing to split: the setting changes nothing.
        let alone = summary([.completed, .awaitingInput])
        Settings.needsYouOnLeft = false
        let a = StatusPill.widths(alone)
        Settings.needsYouOnLeft = true
        #expect(StatusPill.widths(alone) == a)
    }

    @Test func noAsideWithoutBothSides() {
        #expect(summary([.working, .working]).workingAside == nil) // the words already say it
        #expect(summary([.completed, .awaitingInput]).workingAside == nil)
        #expect(summary([.idle]).workingAside == nil)
    }

    // MARK: Shelves

    private func shell(_ fields: [String: Any]) -> ShellThread {
        var thread: [String: Any] = [
            "id": "t1", "projectId": "p1", "title": "A thread",
            "status": "idle", "latestRunId": "run:1", "activeProviderThreadId": NSNull(),
            "activityRunStatus": NSNull(), "pendingRuntimeRequest": NSNull(),
            "updatedAt": "2026-11-16T10:00:00.000Z", "interactionMode": "default",
            "hasActionableProposedPlan": false, "pendingBackgroundTasks": [] as [Any],
            "lineage": ["parentThreadId": NSNull(), "relationshipToParent": NSNull()],
            "archivedAt": NSNull(), "deletedAt": NSNull(), "settledOverride": NSNull(),
        ]
        thread.merge(fields) { _, new in new }
        let message: [String: Any] = [
            "_tag": "Chunk", "requestId": "1",
            "values": [["kind": "thread.updated", "sequence": 1, "location": "active", "thread": thread]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: message)
        guard case .chunk(_, let values)? = Incoming.parse(data),
              case .threadUpdated(let t)? = values.first?.shell else {
            Issue.record("didn't parse as thread.updated")
            fatalError()
        }
        return t
    }

    private let now = ISO8601DateFormatter().date(from: "2026-11-16T12:00:00Z")!
    private let snoozed: [String: Any] = ["snoozedAt": "2026-11-16T11:00:00.000Z", "snoozedUntil": "2026-11-16T15:00:00.000Z"]

    @Test func plainThreadIsInTheInbox() {
        #expect(shell([:]).shelf(now: now) == .inbox)
    }

    @Test func settledOverrideSettles() {
        #expect(shell(["settledOverride": "settled", "settledAt": "2026-11-16T09:00:00.000Z"]).shelf(now: now) == .settled)
        #expect(shell(["settledOverride": "active"]).shelf(now: now) == .inbox)
    }

    private func pr(_ state: String) -> [String: Any] {
        ["pullRequests": [["number": 42, "url": "https://github.com/o/r/pull/42", "source": "agent",
                           "snapshot": ["state": state]]]]
    }

    /// Only T3's server settles: a merged or closed PR it hasn't settled stays in the inbox
    /// (it may have been merged before your last message, or settle-on-merge is off).
    @Test func aMergedPRAloneDoesNotSettle() {
        #expect(shell(pr("merged")).shelf(now: now) == .inbox)
        #expect(shell(pr("closed")).shelf(now: now) == .inbox)
        var settled = pr("merged"); settled["settledOverride"] = "settled"
        #expect(shell(settled).shelf(now: now) == .settled)
    }

    /// A settled thread is done: a request it left behind (here a link card nobody answered
    /// before it was settled) neither lists it nor counts it.
    @Test func aSettledThreadWithALeftoverRequestStaysSettled() {
        var fields: [String: Any] = ["status": "completed", "settledOverride": "settled",
                                     "settledAt": "2026-11-13T01:52:32.081Z"]
        fields["pendingRuntimeRequest"] = ["id": "turn-item:link-request:t1:a:b", "kind": "user_input",
                                           "createdAt": "2026-11-03T20:32:46.314Z", "blocking": true, "userOnly": true]
        let t = shell(fields)
        #expect(t.status == .awaitingInput) // what T3 reports for it
        #expect(t.placement(now: now) == .settled)
        fields["pendingRuntimeRequest"] = ["id": "r1", "kind": "command", "createdAt": "2026-11-16T11:30:00.000Z"]
        #expect(shell(fields).placement(now: now) == .settled)
    }

    @Test func inboxThreadsAreWorkingWaitingOrQuiet() {
        #expect(shell(["status": "running", "activityRunStatus": "running"]).placement(now: now) == .working)
        var asking: [String: Any] = [:]
        asking["pendingRuntimeRequest"] = ["id": "r1", "kind": "command", "createdAt": "2026-11-16T11:30:00.000Z"]
        #expect(shell(asking).placement(now: now) == .waiting)
        #expect(shell([:]).placement(now: now) == .quiet)
        #expect(shell(snoozed).placement(now: now) == .snoozed)
    }

    @Test func snoozedUntilItsWakeTime() {
        #expect(shell(snoozed).shelf(now: now) == .snoozed)
        let later = ISO8601DateFormatter().date(from: "2026-11-16T16:00:00Z")!
        #expect(shell(snoozed).shelf(now: later) == .inbox)
    }

    @Test func snoozeOutranksSettled() {
        var fields = snoozed
        fields["settledOverride"] = "settled"
        #expect(shell(fields).shelf(now: now) == .snoozed)
    }

    @Test func finishingDoesNotWakeASnooze() {
        var fields = snoozed
        fields["status"] = "completed"
        fields["latestRunCompletedAt"] = "2026-11-16T11:30:00.000Z"
        #expect(shell(fields).shelf(now: now) == .snoozed)
    }

    @Test func approvalWakesASnooze() {
        var fields = snoozed
        fields["pendingRuntimeRequest"] = ["id": "r1", "kind": "command", "createdAt": "2026-11-16T11:30:00.000Z"]
        #expect(shell(fields).shelf(now: now) == .inbox)
    }

    @Test func onlyANewQuestionWakesASnooze() {
        var old = snoozed
        old["pendingRuntimeRequest"] = ["id": "r1", "kind": "user_input", "createdAt": "2026-11-16T10:30:00.000Z"]
        #expect(shell(old).shelf(now: now) == .snoozed) // "ask me later"
        var new = snoozed
        new["pendingRuntimeRequest"] = ["id": "r2", "kind": "user_input", "createdAt": "2026-11-16T11:30:00.000Z"]
        #expect(shell(new).shelf(now: now) == .inbox)
    }

    @Test func aFailureAfterTheSnoozeWakesIt() {
        var before = snoozed
        before["status"] = "failed"
        before["latestRunCompletedAt"] = "2026-11-16T10:30:00.000Z"
        #expect(shell(before).shelf(now: now) == .snoozed)
        var after = snoozed
        after["status"] = "failed"
        after["latestRunCompletedAt"] = "2026-11-16T11:30:00.000Z"
        #expect(shell(after).shelf(now: now) == .inbox)
    }
}
