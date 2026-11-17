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
