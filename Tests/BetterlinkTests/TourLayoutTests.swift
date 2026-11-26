import AppKit
import BetterlinkCore
import SwiftUI
import Testing
@testable import Betterlink

/// The tour's copy and the window it is read in (docs/tour.md). A step whose
/// words grow past the window still works, since it scrolls, but the tour is
/// meant to be read a screen at a time: these fail when a step stops fitting.
@MainActor @Suite struct TourLayoutTests {
    /// The room a step has in a window of `size`: all of it but the tour's
    /// header and footer.
    private func room(in size: CGSize) -> CGFloat { size.height - TourLayout.header - TourLayout.footer }

    /// How tall a step is with a control as tall as controls may be.
    private func height(_ entry: TourPlan.Entry, width: CGFloat) -> CGFloat {
        let view = TourStepContent(entry: entry) { Color.clear.frame(height: TourLayout.controlBudget) }
        return NSHostingView(rootView: view.frame(width: width)).fittingSize.height
    }

    @Test func everyStepFitsTheWindowAsItOpens() {
        let size = BetterlinkWindow.defaultSize
        for topic in TourRegistry.topics {
            for step in topic.steps {
                // As the first run shows it, and as What's New does: with its
                // badge and, for a changed step, what changed.
                let notes: [TourPlan.Note?] = [nil, .new, .updated(step.changed)]
                for note in notes {
                    let tall = height(TourPlan.Entry(topic: topic, step: step, note: note), width: size.width)
                    #expect(tall <= room(in: size), "\(step.id) is \(tall) pt tall; the window has \(room(in: size)) pt. Shorten its body in Tour/tour.json.")
                }
            }
        }
    }

    /// A step with no control has room to spare even in the smallest window.
    @Test func theWordsAloneFitTheSmallestWindow() {
        let size = BetterlinkWindow.minSize
        for topic in TourRegistry.topics {
            for step in topic.steps {
                let tall = height(TourPlan.Entry(topic: topic, step: step), width: size.width) - TourLayout.controlBudget
                #expect(tall <= room(in: size), "\(step.id) is \(tall) pt tall without its control; the smallest window has \(room(in: size)) pt.")
            }
        }
    }

    /// The window can't be made smaller than the tour's own bars plus a step's tile and title.
    @Test func theSmallestWindowHoldsTheTour() {
        #expect(room(in: BetterlinkWindow.minSize) >= 300)
        #expect(BetterlinkWindow.defaultSize.width >= BetterlinkWindow.minSize.width)
        #expect(BetterlinkWindow.defaultSize.height >= BetterlinkWindow.minSize.height)
        #expect(TourLayout.column + 2 * DS.Space.space8 <= BetterlinkWindow.minSize.width)
    }
}
