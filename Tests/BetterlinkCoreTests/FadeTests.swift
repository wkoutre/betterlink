import Testing
@testable import BetterlinkCore

struct FadeTests {
    @Test func hidingFadesOutOverItsDuration() {
        var f = Fade(shown: true)
        f.hide(at: 10, reduceMotion: false)
        #expect(f.phase == .hiding)
        #expect(f.alpha(at: 10) == 1)
        let mid = f.alpha(at: 10 + Fade.hideDuration / 2)
        #expect(mid > 0.1 && mid < 0.9)                     // in between, not a jump
        #expect(f.alpha(at: 10 + Fade.hideDuration) == 0)
        f.settle(at: 10 + Fade.hideDuration)
        #expect(f.phase == .hidden)
    }

    @Test func everyStepOfAHideIsSmall() {
        var f = Fade(shown: true)
        f.hide(at: 0, reduceMotion: false)
        var last = 1.0
        for i in 1...30 {   // sampled every 1/240 s
            let a = f.alpha(at: Double(i) / 240)
            #expect(last - a <= 0.25)
            last = a
        }
        #expect(last == 0)
    }

    @Test func showingDuringAHideReversesFromWhereItIs() {
        var f = Fade(shown: true)
        f.hide(at: 0, reduceMotion: false)
        let t = Fade.hideDuration / 2
        let here = f.alpha(at: t)
        f.show(at: t, reduceMotion: false)
        #expect(f.phase == .showing)
        #expect(abs(f.alpha(at: t) - here) < 1e-9)        // no jump
        #expect(f.alpha(at: t + Fade.showDuration) == 1)
    }

    @Test func reduceMotionIsImmediate() {
        var f = Fade(shown: true)
        f.hide(at: 0, reduceMotion: true)
        #expect(f.phase == .hidden && f.alpha(at: 0) == 0)
        f.show(at: 1, reduceMotion: true)
        #expect(f.phase == .shown && f.alpha(at: 1) == 1)
    }

    @Test func repeatedHidesDontRestartTheFade() {
        var f = Fade(shown: true)
        f.hide(at: 0, reduceMotion: false)
        let a = f.alpha(at: 0.05)
        f.hide(at: 0.05, reduceMotion: false)
        #expect(f.alpha(at: 0.05) == a)
        #expect(f.alpha(at: Fade.hideDuration) == 0)
    }
}

