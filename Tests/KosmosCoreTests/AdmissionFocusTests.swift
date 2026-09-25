import Testing
@testable import KosmosCore

/// Seconds since an input the session never saw.
private let never = 3600.0
private let chrome: Int32 = 63518, raycast: Int32 = 18576, ghostty: Int32 = 900

/// No key press or click for a long while, the pointer at rest too.
private let idle = ActivationInput(key: never, leftClick: never, rightClick: never, moved: never)

@Suite struct AdmissionFocusTests {
    @Test func anAgentsLaunchWithNoInputIsNotFollowed() {
        var launches = UserLaunches()
        let start = ContinuousClock.now
        // `open -a` or Playwright, with Steve's last key press 30 s back.
        let input = ActivationInput(key: 30, leftClick: never, rightClick: never, moved: 12)
        let judged = launches.launching(chrome, input: input, onDock: false, age: 0.3, at: start)
        #expect(judged == false)
        let asked = launches.asked(forKeyOf: chrome, keyBefore: ghostty, input: input, onDock: false, at: start + .seconds(1))
        #expect(!asked)
        #expect(AdmissionFocus.decide(keyed: true, asked: asked, shown: false, parked: false, atLaunch: false,
                                      locked: false) == .none)
    }

    @Test func theUsersSlowLaunchIsFollowedWithinTheDeadline() {
        // Live, 2026-09-25: Enter in Raycast, then 5.5 s until Chrome's first window was
        // admitted on hidden workspace 4.
        var launches = UserLaunches()
        let start = ContinuousClock.now
        let enter = ActivationInput(key: 0.35, leftClick: never, rightClick: never, moved: 20)
        let judged = launches.launching(chrome, input: enter, onDock: false, age: 0.3, at: start)
        #expect(judged == true)
        // A later word of the same launch is not judged again.
        let again = launches.launching(chrome, input: idle, onDock: false, age: 4.4, at: start + .seconds(4.1))
        #expect(again == nil)
        let asked = launches.asked(forKeyOf: chrome, keyBefore: raycast, input: idle, onDock: false,
                                   at: start + .seconds(5.5))
        #expect(asked)
        #expect(AdmissionFocus.decide(keyed: true, asked: asked, shown: false, parked: false, atLaunch: false,
                                      locked: false) == .follow)
        // Only its first key window: the next one comes with nothing new from the user.
        let next = launches.asked(forKeyOf: chrome, keyBefore: chrome, input: idle, onDock: false, at: start + .seconds(6))
        #expect(!next)
    }

    @Test func aFirstWindowAfterTheDeadlineIsNotFollowed() {
        var launches = UserLaunches()
        let start = ContinuousClock.now
        let enter = ActivationInput(key: 0.35, leftClick: never, rightClick: never, moved: 20)
        let judged = launches.launching(chrome, input: enter, onDock: false, age: 0.3, at: start)
        #expect(judged == true)
        let late = start - .seconds(0.3) + UserLaunches.deadline + .milliseconds(1)
        let asked = launches.asked(forKeyOf: chrome, keyBefore: raycast, input: idle, onDock: false, at: late)
        #expect(!asked)
    }

    @Test func aLaunchIsJudgedAsOfWhenItBegan() {
        func judged(_ input: ActivationInput, onDock: Bool = false, age: Double) -> Bool? {
            var launches = UserLaunches()
            return launches.launching(chrome, input: input, onDock: onDock, age: age, at: .now)
        }
        // Heard of only at the check-in, 4.1 s after the launch began, 0.1 s after the key.
        #expect(judged(ActivationInput(key: 4.2, leftClick: never, rightClick: never, moved: 30), age: 4.1) == true)
        // The pointer moved during the wait: it may have moved before the launch too.
        #expect(judged(ActivationInput(key: 4.2, leftClick: never, rightClick: never, moved: 2), age: 4.1) == false)
        // A key press during the wait hides the one before the launch.
        #expect(judged(ActivationInput(key: 1, leftClick: never, rightClick: never, moved: 30), age: 4.1) == false)
        // A Dock click, the pointer on its way up since.
        #expect(judged(ActivationInput(key: 40, leftClick: 0.5, rightClick: never, moved: 0.1), onDock: true, age: 0.2) == true)
    }

    @Test func commandNFollowsOnlyAKeyPressInTheAppItself() {
        func asked(after keyBefore: Int32, _ input: ActivationInput) -> Bool {
            var launches = UserLaunches()
            return launches.asked(forKeyOf: chrome, keyBefore: keyBefore, input: input, onDock: false, at: .now)
        }
        let pressed = ActivationInput(key: 0.15, leftClick: never, rightClick: never, moved: 9)
        // Command-N in Chrome, whose own window was key.
        #expect(asked(after: chrome, pressed))
        // An agent fronted Chrome to open a window while Steve typed in Ghostty.
        #expect(!asked(after: ghostty, pressed))
        // Command-N over a second after the key, or after the pointer moved.
        #expect(!asked(after: chrome, ActivationInput(key: 1.2, leftClick: never, rightClick: never, moved: 9)))
        #expect(!asked(after: chrome, ActivationInput(key: 0.15, leftClick: never, rightClick: never, moved: 0.05)))
    }

    @Test func admissionFollowsOnlyAWindowTheUserAskedFor() {
        func decide(keyed: Bool = true, asked: Bool = true, shown: Bool = false, parked: Bool = false,
                    atLaunch: Bool = false, locked: Bool = false) -> AdmissionFocus {
            AdmissionFocus.decide(keyed: keyed, asked: asked, shown: shown, parked: parked, atLaunch: atLaunch, locked: locked)
        }
        #expect(decide() == .follow)
        // On a shown workspace, as with a rule that names no workspace, it becomes the focus
        // there, asked for or not, at launch too.
        #expect(decide(shown: true) == .adopt)
        #expect(decide(asked: false, shown: true, atLaunch: true) == .adopt)
        // A window its app did not key, as one a background app opened, changes nothing.
        #expect(decide(keyed: false) == .none)
        #expect(decide(keyed: false, shown: true) == .none)
        // Nor does Kosmos's launch sweep, a parked window or a locked session.
        #expect(decide(atLaunch: true) == .none)
        #expect(decide(parked: true) == .none)
        #expect(decide(shown: true, parked: true) == .none)
        #expect(decide(locked: true) == .none)
        #expect(decide(shown: true, locked: true) == .none)
    }
}
