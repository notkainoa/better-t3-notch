import Foundation

/// What the collapsed notch says: one short line that leaves nothing out.
///
/// Anything waiting on you wins over work in progress. One kind waiting gets its own words
/// ("1 thread failed", "2 plans ready"); two or more kinds collapse into "N threads need you",
/// with every kind's icon beside it. Only when nothing waits does it count working threads.
struct NotchSummary: Equatable, Sendable {
    /// Kinds of "waiting on you", in the order their icons are drawn.
    enum Kind: CaseIterable, Sendable { case question, plan, failed, done }

    var questions = 0, plans = 0, failed = 0, done = 0
    var working = 0
    /// T3's sidebar shelves, for the list's footer.
    var snoozed = 0, settled = 0

    static func kind(of status: ThreadStatus) -> Kind? {
        switch status {
        case .pendingApproval, .awaitingInput, .guestRequest: .question
        case .planReady: .plan
        case .failed: .failed
        case .completed: .done
        default: nil
        }
    }

    mutating func add(_ status: ThreadStatus) {
        switch Self.kind(of: status) {
        case .question?: questions += 1
        case .plan?: plans += 1
        case .failed?: failed += 1
        case .done?: done += 1
        case nil: if status.isBusy { working += 1 }
        }
    }

    func count(_ kind: Kind) -> Int {
        switch kind {
        case .question: questions
        case .plan: plans
        case .failed: failed
        case .done: done
        }
    }

    /// Kinds with at least one thread, in icon order.
    var waiting: [Kind] { Kind.allCases.filter { count($0) > 0 } }
    var attention: Int { questions + plans + failed + done }
    /// Nothing to say: the notch stays plain.
    var isQuiet: Bool { attention == 0 && working == 0 }

    var text: String? {
        func n(_ c: Int, _ one: String, _ many: String) -> String { "\(c) \(c == 1 ? one : many)" }
        let kinds = waiting
        if kinds.count > 1 { return n(attention, "thread needs you", "threads need you") }
        switch kinds.first {
        case .question?: return n(questions, "thread needs you", "threads need you")
        case .plan?: return n(plans, "plan ready", "plans ready")
        case .failed?: return n(failed, "thread failed", "threads failed")
        case .done?: return n(done, "thread done", "threads done")
        case nil: return working > 0 ? n(working, "thread working", "threads working") : nil
        }
    }
}
