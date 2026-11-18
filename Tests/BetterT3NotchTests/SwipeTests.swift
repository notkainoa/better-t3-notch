import AppKit
import Testing
@testable import BetterT3Notch

@MainActor @Suite struct SwipeTests {
    /// A trackpad scroll event, as the fingers move: `up` points upward.
    private func scroll(_ phase: Int64, up: Int32 = 0, sideways: Int32 = 0, momentum: Int64 = 0) -> NSEvent {
        // Synthesized events may or may not say natural scrolling is on; move the fingers up either way.
        let probe = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0)!
        let flip: Int32 = NSEvent(cgEvent: probe)!.isDirectionInvertedFromDevice ? -1 : 1
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                         wheel1: up * flip, wheel2: sideways * flip, wheel3: 0)!
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(up * flip))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(sideways * flip))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return NSEvent(cgEvent: cg)!
    }

    private let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4

    /// Runs a whole gesture and counts how often it fired.
    private func fires(_ events: [NSEvent], toward direction: SwipeTracker.Direction? = .up,
                       tracker: inout SwipeTracker) -> Int {
        events.filter { tracker.track($0, toward: direction) == .fire }.count
    }

    @Test func swipeUpFiresOnce() {
        var t = SwipeTracker()
        let gesture = [scroll(began)] + Array(repeating: scroll(changed, up: 8), count: 10)
            + [scroll(ended), scroll(0, up: 20, momentum: 2)] // momentum after lift-off
        #expect(fires(gesture, tracker: &t) == 1)
    }

    @Test func nothingOpenIgnoresIt() {
        var t = SwipeTracker()
        let gesture = [scroll(began)] + Array(repeating: scroll(changed, up: 8), count: 10) + [scroll(ended)]
        #expect(fires(gesture, toward: nil, tracker: &t) == 0)
    }

    /// A quick flick: the fingers barely move before letting go, still going up.
    @Test func aFlickUpFires() {
        var t = SwipeTracker()
        let flick = [scroll(began), scroll(changed, up: 4), scroll(changed, up: 7), scroll(ended),
                     scroll(0, up: 12, momentum: 1), scroll(0, up: 15, momentum: 2)]
        #expect(fires(flick, tracker: &t) == 1)
    }

    @Test func aTinyNudgeOrAFlickDownDoesNot() {
        var t = SwipeTracker()
        let nudge = [scroll(began), scroll(changed, up: 4), scroll(ended), scroll(0, up: 12, momentum: 1)]
        let down = [scroll(began), scroll(changed, up: -12), scroll(ended), scroll(0, up: -15, momentum: 1)]
        let slow = [scroll(began), scroll(changed, up: 12), scroll(ended)] // short, no momentum
        #expect([nudge, down, slow].map { fires($0, tracker: &t) } == [0, 0, 0])
    }

    @Test func shortOrSidewaysOrDownOrAWheelDoesNothing() {
        var t = SwipeTracker()
        let gestures = [
            [scroll(began), scroll(changed, up: 20), scroll(ended)],                // too short, no momentum
            [scroll(began), scroll(changed, up: 40, sideways: 80), scroll(ended)],  // mostly sideways
            [scroll(began), scroll(changed, up: -80), scroll(ended)],               // down
            [scroll(0, up: 80)],                                                    // mouse wheel
        ]
        #expect(gestures.map { fires($0, tracker: &t) } == [0, 0, 0, 0])
    }

    /// The pop-up goes away on its own mid-swipe (its timer, read in T3 Code): the lift drops
    /// at once, instead of leaving the pill hanging a few points too high.
    @Test func liftDropsWhenThePopUpGoesMidSwipe() {
        var t = SwipeTracker()
        _ = t.track(scroll(began), toward: .up)
        #expect(t.track(scroll(changed, up: 20), toward: .up) == .lift(20))
        #expect(t.track(scroll(changed, up: 5), toward: nil) == .lift(0))
        #expect(t.track(scroll(ended), toward: nil) == .lift(0))
    }

    // MARK: Two fingers down, on the closed notch

    @Test func swipeDownOnTheClosedNotchOpensIt() {
        var t = SwipeTracker()
        let down = [scroll(began)] + Array(repeating: scroll(changed, up: -8), count: 5) + [scroll(ended)]
        let up = [scroll(began)] + Array(repeating: scroll(changed, up: 8), count: 5) + [scroll(ended)]
        let flick = [scroll(began), scroll(changed, up: -10), scroll(ended), scroll(0, up: -14, momentum: 1)]
        #expect(fires(down, toward: .down, tracker: &t) == 1)
        #expect(fires(up, toward: .down, tracker: &t) == 0) // up does nothing while closed
        #expect(fires(flick, toward: .down, tracker: &t) == 1)
    }

    // MARK: Press, hold and drag

    private func drag(_ direction: SwipeTracker.Direction, by moves: [CGPoint]) -> DragSwipe.Outcome {
        var d = DragSwipe(at: .init(x: 500, y: 900), toward: direction)
        for m in moves.dropLast() { _ = d.move(to: .init(x: 500 + m.x, y: 900 + m.y)) }
        let last = moves.last ?? .zero
        return d.end(at: .init(x: 500 + last.x, y: 900 + last.y))
    }

    @Test func dragUpOnTheOpenNotchSwipesIt() {
        #expect(drag(.up, by: [.init(x: 0, y: 10), .init(x: 2, y: 30)]) == .swipe)
    }

    @Test func dragDownOnTheClosedNotchSwipesIt() {
        #expect(drag(.down, by: [.init(x: 0, y: -10), .init(x: -3, y: -40)]) == .swipe)
    }

    /// A press that barely moves is the click it always was (rows and cards open, buttons press).
    @Test func aPressThatDoesNotMoveIsAClick() {
        #expect(drag(.up, by: []) == .click)
        #expect(drag(.up, by: [.init(x: 2, y: 1), .init(x: 1, y: 2)]) == .click)
    }

    /// A drag that doesn't count does nothing at all: not a swipe, and not a click either.
    @Test func aShortSidewaysOrWrongWayDragDoesNothing() {
        #expect(drag(.up, by: [.init(x: 0, y: 15)]) == .cancel)                  // too short
        #expect(drag(.up, by: [.init(x: 60, y: 30)]) == .cancel)                 // mostly sideways
        #expect(drag(.up, by: [.init(x: 0, y: -40)]) == .cancel)                 // down while open
        #expect(drag(.down, by: [.init(x: 0, y: 40)]) == .cancel)                // up while closed
        #expect(drag(.up, by: [.init(x: 0, y: 40), .init(x: 0, y: 5)]) == .cancel) // came back before letting go
    }

    /// The lift follows the drag only once it's a drag, and only the swipe's way.
    @Test func dragReportsHowFarItWent() {
        var d = DragSwipe(at: .init(x: 500, y: 900), toward: .up)
        #expect(d.move(to: .init(x: 500, y: 902)) == nil)
        #expect(d.move(to: .init(x: 500, y: 912)) == 12)
        #expect(d.move(to: .init(x: 500, y: 890)) == 0)
    }

    // MARK: Two fingers, raw values (both natural-scrolling settings)

    /// One gesture event as AppKit reports it: `fingersUp` is how far the fingers moved up.
    private func step(_ t: inout SwipeTracker, _ phase: NSEvent.Phase, fingersUp: CGFloat = 0, sideways: CGFloat = 0,
                      momentum: NSEvent.Phase = [], natural: Bool, toward d: SwipeTracker.Direction? = .up) -> SwipeTracker.Step {
        // With natural scrolling on, the content follows the fingers: up reads as a negative delta.
        let sign: CGFloat = natural ? -1 : 1
        return t.track(phase: phase, momentum: momentum, dx: sideways * sign, dy: fingersUp * sign,
                       inverted: natural, toward: d)
    }

    @Test(arguments: [true, false]) func fingersUpFiresWithEitherScrollingSetting(natural: Bool) {
        var t = SwipeTracker()
        _ = step(&t, .began, natural: natural)
        #expect(step(&t, .changed, fingersUp: 12, natural: natural) == .lift(12))
        #expect(step(&t, .changed, fingersUp: 12, natural: natural) == .fire)
        var down = SwipeTracker()
        _ = step(&down, .began, natural: natural, toward: .down)
        #expect(step(&down, .changed, fingersUp: -30, natural: natural, toward: .down) == .fire)
    }

    /// The glide's first event may carry no movement: the flick still fires on the next one.
    @Test(arguments: [true, false]) func flickFiresOnTheFirstMomentumEventThatMoves(natural: Bool) {
        var t = SwipeTracker()
        _ = step(&t, .began, natural: natural)
        _ = step(&t, .changed, fingersUp: 10, natural: natural)
        _ = step(&t, .ended, natural: natural)
        #expect(step(&t, [], momentum: .began, natural: natural) == .ignore)
        #expect(step(&t, [], fingersUp: 9, momentum: .changed, natural: natural) == .fire)
        #expect(step(&t, [], fingersUp: 9, momentum: .changed, natural: natural) == .ignore) // once
    }

    /// Movement on the lift-off event itself counts toward a flick.
    @Test func liftOffMovementCountsTowardAFlick() {
        var t = SwipeTracker()
        _ = step(&t, .began, natural: false)
        _ = step(&t, .changed, fingersUp: 6, natural: false)
        _ = step(&t, .ended, fingersUp: 3, natural: false)
        #expect(step(&t, [], fingersUp: 9, momentum: .began, natural: false) == .fire)
    }

    @Test func aCancelledGestureNeverFlicks() {
        var t = SwipeTracker()
        _ = step(&t, .began, natural: false)
        _ = step(&t, .changed, fingersUp: 20, natural: false)
        #expect(step(&t, .cancelled, natural: false) == .lift(0))
        #expect(step(&t, [], fingersUp: 9, momentum: .began, natural: false) == .ignore)
    }

    /// After one swipe fires, the next gesture starts fresh and can fire again.
    @Test func theNextGestureFiresAgain() {
        var t = SwipeTracker()
        for _ in 0..<2 {
            _ = step(&t, .began, natural: false)
            #expect(step(&t, .changed, fingersUp: 30, natural: false) == .fire)
            #expect(step(&t, .changed, fingersUp: 30, natural: false) == .lift(0))
            _ = step(&t, .ended, natural: false)
        }
    }

    // MARK: The panel holding a press

    private final class Gestures: NotchGestures {
        var target: SwipeTarget? = SwipeTarget(direction: .up, mode: .expanded, eventId: nil)
        var ended: [Bool] = []
        func swipeTarget(at p: CGPoint) -> SwipeTarget? { target }
        func swipeMoved(_ along: CGFloat, toward direction: SwipeTracker.Direction) {}
        func swipeEnded(_ swiped: Bool, toward direction: SwipeTracker.Direction) { ended.append(swiped) }
    }

    private func mouse(_ type: NSEvent.EventType, _ panel: NSWindow, y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: 100, y: y), modifierFlags: [], timestamp: 0,
                           windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func panel(_ gestures: Gestures) -> NotchPanel {
        let p = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.gestures = gestures
        return p
    }

    @Test func aPressDraggedUpIsASwipe() {
        let g = Gestures(), p = panel(g)
        p.sendEvent(mouse(.leftMouseDown, p, y: 100))
        #expect(p.isPressing)
        p.sendEvent(mouse(.leftMouseDragged, p, y: 120))
        p.sendEvent(mouse(.leftMouseUp, p, y: 140))
        #expect(!p.isPressing)
        #expect(g.ended == [true])
    }

    /// A card came or went while the button was held: the release acts on nothing.
    @Test func theNotchChangingUnderAPressCancelsIt() {
        let g = Gestures(), p = panel(g)
        p.sendEvent(mouse(.leftMouseDown, p, y: 100))
        p.sendEvent(mouse(.leftMouseDragged, p, y: 120))
        g.target = SwipeTarget(direction: .up, mode: .peek, eventId: "new card")
        p.sendEvent(mouse(.leftMouseUp, p, y: 140))
        #expect(g.ended == [false])
    }

    /// A press whose release never came is dropped (lift and all) by the next one.
    @Test func aNewPressDropsAStaleOne() {
        let g = Gestures(), p = panel(g)
        p.sendEvent(mouse(.leftMouseDown, p, y: 100))
        p.sendEvent(mouse(.leftMouseDown, p, y: 100))
        #expect(g.ended == [false])
        #expect(p.isPressing)
    }

    @Test func aPressDraggedDownOnTheClosedNotchIsASwipe() {
        let g = Gestures(), p = panel(g)
        g.target = SwipeTarget(direction: .down, mode: .idle, eventId: nil)
        p.sendEvent(mouse(.leftMouseDown, p, y: 200))
        p.sendEvent(mouse(.leftMouseDragged, p, y: 180))
        p.sendEvent(mouse(.leftMouseUp, p, y: 160))
        #expect(g.ended == [true])
    }

    /// A different button under the pointer by the time a click is let go (a row grew an
    /// Approve button there): the click acts on nothing, not on the new button.
    @Test func aDifferentButtonUnderAClickCancelsIt() {
        let g = Gestures(), p = panel(g)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        p.contentView = content
        p.sendEvent(mouse(.leftMouseDown, p, y: 100))
        content.addSubview(NSButton(frame: CGRect(x: 0, y: 0, width: 300, height: 300))) // now on top
        p.sendEvent(mouse(.leftMouseUp, p, y: 101))
        #expect(g.ended == [false])
    }

    /// A swipe replays nothing, so the list shifting under it mid-drag doesn't cancel it.
    @Test func aSwipeIgnoresWhatShiftedUnderIt() {
        let g = Gestures(), p = panel(g)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        p.contentView = content
        p.sendEvent(mouse(.leftMouseDown, p, y: 100))
        p.sendEvent(mouse(.leftMouseDragged, p, y: 120))
        content.addSubview(NSButton(frame: CGRect(x: 0, y: 0, width: 300, height: 300)))
        p.sendEvent(mouse(.leftMouseUp, p, y: 140))
        #expect(g.ended == [true])
    }

    /// A slow two-finger swipe that crosses the line only on its lift-off event still counts.
    @Test func aSwipeCrossingTheLineAsTheFingersLiftFires() {
        var t = SwipeTracker()
        _ = step(&t, .began, natural: false)
        #expect(step(&t, .changed, fingersUp: 20, natural: false) == .lift(20))
        #expect(step(&t, .ended, fingersUp: 6, natural: false) == .fire)
    }

    private final class Row: NSView, PressTarget {}

    /// A click is on the button under it, or else the row it's in: a label (an NSControl too)
    /// shifting inside the row as the time ticks is still the same row.
    @Test func aClickResolvesToItsButtonOrRow() {
        let row = Row(), label = NSTextField(labelWithString: "12s"), button = NSButton()
        row.addSubview(label)
        row.addSubview(button)
        #expect(NotchPanel.clickTarget(of: label) === row)
        #expect(NotchPanel.clickTarget(of: row) === row)
        #expect(NotchPanel.clickTarget(of: button) === button)
        #expect(NotchPanel.clickTarget(of: NSView()) == nil)
    }

    /// Scrolling while a swipe can't act (a click held, a reply open) doesn't bank distance.
    @Test func blockedTravelDoesNotCount() {
        var t = SwipeTracker()
        _ = step(&t, .began, natural: false)
        _ = step(&t, .changed, fingersUp: 30, natural: false, toward: nil)
        #expect(step(&t, .changed, fingersUp: 5, natural: false) == .lift(5))
    }
}
