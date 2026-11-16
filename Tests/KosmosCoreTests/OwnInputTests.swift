import CoreGraphics
import Testing
@testable import KosmosCore

// What makes a key window change the user's (docs/focus.md). The processes are those of
// Steve's input sample of 2026-10-02: his own presses carried source pid 0, and the input
// other processes posted carried their own pids.

private let dock: Int32 = 10
private let raycast: Int32 = 11
private let teamsNotifications: Int32 = 12
private let kosmos: Int32 = 13
private let computerUse: Int32 = 14
private let ghostty: Int32 = 100
private let chatGPT: Int32 = 200
private let chrome: Int32 = 300
private let teams: Int32 = 400
private let finder: Int32 = 500

private func ms(_ milliseconds: Int) -> ContinuousClock.Instant { t0 + .milliseconds(milliseconds) }

/// Where each process's press went, seen from `app`.
private func place(from app: Int32) -> (Int32) -> OwnInput.Target {
    { pid in
        if pid == app || (app == teams && pid == teamsNotifications) { return .app }
        return [dock, raycast, teamsNotifications, kosmos].contains(pid) ? .notRegular : .otherApp
    }
}

/// Read 100 ms after the change's stamp, as Kosmos decided on Spotify's activation on 2026-11-16.
private func cause(_ input: OwnInput, of app: Int32, at milliseconds: Int, launched: Int? = nil,
                   readAt read: Int? = nil) -> OwnInput.Cause? {
    input.cause(at: ms(milliseconds), launched: launched.map(ms), listening: true, now: ms(read ?? milliseconds + 100),
                target: place(from: app))
}

private struct Keyboard {
    var input = OwnInput()
    var events: UInt64 = 0

    mutating func key(to target: Int32, at milliseconds: Int, from source: Int32 = 0) {
        events += 1
        input.heardSessionKey(from: source, event: events, at: ms(milliseconds))
        input.heardKey(from: source, target: target, event: events, at: ms(milliseconds))
    }

    mutating func hotkey(at milliseconds: Int, from source: Int32 = 0) {
        events += 1
        input.heardSessionKey(from: source, event: events, at: ms(milliseconds))
    }

    mutating func modifiers(to target: Int32, at milliseconds: Int, from source: Int32 = 0) {
        input.heardModifiers(from: source, target: target, at: ms(milliseconds))
    }

    mutating func click(on target: Int32, at milliseconds: Int, from source: Int32 = 0) {
        input.heardClick(from: source, target: target, at: ms(milliseconds))
    }
}

@Test func commandTabAndTheDockAreTheUsers() {
    // His Command-Tab's key downs went to the Dock.
    var keyboard = Keyboard()
    keyboard.key(to: ghostty, at: 0)
    keyboard.key(to: dock, at: 500)
    #expect(cause(keyboard.input, of: chrome, at: 700) == .opener(.key(target: dock), ago: .milliseconds(200), beforeLaunch: false))
    keyboard.click(on: dock, at: 3000)
    #expect(cause(keyboard.input, of: chrome, at: 3100) == .opener(.click(target: dock), ago: .milliseconds(100), beforeLaunch: false))
    // A switcher held open past the second activates its app as Command comes up, a change
    // that goes to the Dock too.
    keyboard.key(to: dock, at: 6000)
    keyboard.modifiers(to: dock, at: 8000)
    #expect(cause(keyboard.input, of: chrome, at: 8100) == .opener(.key(target: dock), ago: .milliseconds(100), beforeLaunch: false))
}

@Test func anAgentsOpenWhileTheUserTypesElsewhereIsNotHis() {
    // Steve typed 72 keys into ChatGPT and 64 into Ghostty in 90 s, so a key came within the
    // second before most moments. Keys into another regular app open nothing.
    var keyboard = Keyboard()
    for at in stride(from: 0, through: 2000, by: 150) { keyboard.key(to: ghostty, at: at) }
    keyboard.key(to: chatGPT, at: 2100)
    #expect(cause(keyboard.input, of: chrome, at: 2200) == nil)
    #expect(cause(keyboard.input, of: chrome, at: 60_000) == nil)
}

@Test func aClickAnywhereOrAKeyIntoALauncherOpensApps() {
    // A link in ChatGPT, a Finder double-click or a Dock click: any click within the second.
    var keyboard = Keyboard()
    keyboard.click(on: chatGPT, at: 0)
    #expect(cause(keyboard.input, of: chrome, at: 900) == .opener(.click(target: chatGPT), ago: .milliseconds(900), beforeLaunch: false))
    #expect(cause(keyboard.input, of: chrome, at: 1100) == nil)
    // Typed into Raycast, which is no regular app.
    keyboard.key(to: raycast, at: 5000)
    #expect(cause(keyboard.input, of: chrome, at: 5300) == .opener(.key(target: raycast), ago: .milliseconds(300), beforeLaunch: false))
    // A press after the change made nothing.
    #expect(cause(keyboard.input, of: chrome, at: 4900) == nil)
}

@Test func aPressIntoTheAppOrAHelperInItsBundleCountsForSeconds() {
    // Accepting a Teams call in its notification clicks Teams' XPC service, and the meeting
    // window can come seconds later, after a key elsewhere.
    var keyboard = Keyboard()
    keyboard.click(on: teamsNotifications, at: 0)
    keyboard.key(to: ghostty, at: 1500)
    #expect(cause(keyboard.input, of: teams, at: 4000) == .inApp(.click(target: teamsNotifications), ago: .seconds(4)))
    #expect(cause(keyboard.input, of: teams, at: 10_001) == nil)
    // Cmd-N in Ghostty opens a window a rule can send elsewhere.
    keyboard.key(to: ghostty, at: 20_000)
    #expect(cause(keyboard.input, of: ghostty, at: 20_100) == .inApp(.key(target: ghostty), ago: .milliseconds(100)))
}

@Test func aLaunchesWindowCountsFromTheLaunch() {
    // Chrome launched from Raycast keyed its first window 5.2 s after the hotkey, and Steve
    // typed in Ghostty meanwhile.
    var keyboard = Keyboard()
    keyboard.key(to: raycast, at: 0)
    for at in stride(from: 1000, through: 5000, by: 200) { keyboard.key(to: ghostty, at: at) }
    #expect(cause(keyboard.input, of: chrome, at: 5200, launched: 300)
        == .opener(.key(target: raycast), ago: .milliseconds(300), beforeLaunch: true))
    // An agent's launch came long after his last press into an opener.
    #expect(cause(keyboard.input, of: chrome, at: 9200, launched: 4000) == nil)
}

@Test func aHotkeysKeyCountsFromItsFirstPress() {
    var keyboard = Keyboard()
    keyboard.key(to: ghostty, at: 0)
    keyboard.hotkey(at: 5000)
    #expect(cause(keyboard.input, of: chrome, at: 5824) == .opener(.hotkey, ago: .milliseconds(824), beforeLaunch: false))
    #expect(cause(keyboard.input, of: chrome, at: 6100) == nil)
    // Raycast activated Spotify about 100 ms after its key at 10:04:51 on 2026-11-16.
    keyboard.hotkey(at: 8000)
    #expect(cause(keyboard.input, of: chrome, at: 8030, readAt: 8104) == .opener(.hotkey, ago: .milliseconds(30), beforeLaunch: false))
    keyboard.key(to: ghostty, at: 5500)
    #expect(cause(keyboard.input, of: chrome, at: 10_200, launched: 5200)
        == .opener(.hotkey, ago: .milliseconds(200), beforeLaunch: true), "a launch's window seconds later, after typing on")
}

@Test func keysThatReachedAnAppAreNoHotkeys() {
    var typing = Keyboard()
    for at in stride(from: 0, through: 1000, by: 100) { typing.key(to: ghostty, at: at) }
    #expect(cause(typing.input, of: chrome, at: 1100) == nil)
    var arriving = Keyboard()
    arriving.key(to: ghostty, at: 0)
    arriving.input.heardSessionKey(from: 0, event: 99, at: ms(1000))
    #expect(cause(arriving.input, of: chrome, at: 1003, readAt: 1005) == nil, "no hotkey before its app copy had time")
    var reordered = Keyboard()
    reordered.key(to: ghostty, at: 0)
    reordered.input.heardKey(from: 0, target: ghostty, event: 99, at: ms(1000))
    reordered.input.heardSessionKey(from: 0, event: 99, at: ms(1000))
    #expect(cause(reordered.input, of: chrome, at: 1500) == nil, "the app copy can come first")
}

@Test func aHotkeyAnotherProcessPostedIsNotTheUsers() {
    var keyboard = Keyboard()
    keyboard.key(to: ghostty, at: 0)
    keyboard.modifiers(to: ghostty, at: 1900, from: computerUse)
    keyboard.hotkey(at: 2000, from: computerUse)
    #expect(cause(keyboard.input, of: chrome, at: 2400) == nil)
    #expect(keyboard.input.lastKey == ms(0))
}

@Test func theLastKeyCountsEachHotkeyUnderOneHeldModifier() {
    // Steve held Option for 4.4 s over Opt-D, Opt-Shift-S and Opt-D on 2026-11-16.
    var keyboard = Keyboard()
    #expect(keyboard.input.lastKey == nil)
    keyboard.key(to: ghostty, at: 0)
    keyboard.modifiers(to: ghostty, at: 1000)
    keyboard.hotkey(at: 1200)
    keyboard.hotkey(at: 2600)
    keyboard.hotkey(at: 4100)
    #expect(keyboard.input.lastKey == ms(4100))
    #expect(cause(keyboard.input, of: chrome, at: 4400) == .opener(.hotkey, ago: .milliseconds(300), beforeLaunch: false))
}

@Test func inputAnotherProcessPostedIsNotTheUsers() {
    // Kosmos's own focus records showed as left mouse downs under its pid, and computer use
    // posts its clicks and keys under its own.
    var keyboard = Keyboard()
    keyboard.click(on: chatGPT, at: 0, from: kosmos)
    keyboard.click(on: chrome, at: 100, from: computerUse)
    keyboard.key(to: chrome, at: 200, from: computerUse)
    #expect(cause(keyboard.input, of: chrome, at: 300) == nil)
}

@Test func withoutTheTapEveryChangeCountsAsTheUsers() {
    var keyboard = Keyboard()
    #expect(cause(keyboard.input, of: chrome, at: 0) == .unheard)
    keyboard.key(to: ghostty, at: 0)
    #expect(cause(keyboard.input, of: chrome, at: 100) == nil)
    #expect(keyboard.input.cause(at: ms(100), launched: nil, listening: false, now: ms(200), target: place(from: chrome)) == .unheard)
}

@Test func pressesOlderThanAnyBoundAreDropped() {
    var keyboard = Keyboard()
    keyboard.click(on: finder, at: 0)
    keyboard.key(to: ghostty, at: 31_000)
    #expect(cause(keyboard.input, of: chrome, at: 31_100, launched: 500) == nil)
}
