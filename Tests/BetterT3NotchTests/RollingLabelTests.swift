import AppKit
import Testing
@testable import BetterT3Notch

@MainActor @Suite struct RollingLabelTests {
    /// Each run of digits rolls on its own; the words around them stay put.
    @Test func splitsNumbersFromWords() {
        let segments = RollingLabel.segments(NSAttributedString(string: "+12 −3"))
        #expect(segments.map(\.text.string) == ["+", "12", " −", "3"])
        #expect(segments.map(\.number) == [false, true, false, true])
    }

    /// The pill sizes the notch from the text's width before anything is drawn, so the label
    /// has to measure exactly the same.
    @Test func measuresLikeThePillExpects() {
        let summaries = [NotchSummary(working: 5), NotchSummary(working: 10),
                         NotchSummary(questions: 2), NotchSummary(questions: 1)]
        for s in summaries {
            let text = s.text!
            let label = RollingLabel()
            label.set(NSAttributedString(string: text, attributes: [.font: StatusPill.font]), animated: false)
            #expect(label.fittingWidth == StatusPill.widths(s).right) // the words' side of the pill
            #expect(label.string == text)
        }
    }
}
