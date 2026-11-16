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

private func cause(_ input: OwnInput, of app: Int32, at milliseconds: Int, launched: Int? = nil) -> OwnInput.Cause? {
    input.cause(at: ms(milliseconds), launched: launched.map(ms), listening: true, target: place(from: app))
}

/// HID counts each key down the tap sees, as Steve's own do.
private struct Keyboard {
    var input = OwnInput()
    var hid: UInt32 = 1000

    mutating func key(to target: Int32, at milliseconds: Int, from source: Int32 = 0) {
        hid += 1
        input.heardKey(from: source, target: target, hidKeys: hid, at: ms(milliseconds))
    }

    /// A key down a hotkey took before the tap saw it.
    mutating func hotkey(at milliseconds: Int) {
        hid += 1
    }

    mutating func modifiersUp(to target: Int32, at milliseconds: Int, lastKey: Int) {
        input.heardModifiers(from: 0, target: target, flags: [], hidKeys: hid, lastKeyAt: ms(lastKey), at: ms(milliseconds))
    }

    mutating func modifiers(_ flags: CGEventFlags, to target: Int32, at milliseconds: Int, from source: Int32 = 0) {
        input.heardModifiers(from: source, target: target, flags: flags, hidKeys: hid, lastKeyAt: ms(milliseconds), at: ms(milliseconds))
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
    keyboard.modifiersUp(to: dock, at: 8000, lastKey: 6000)
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

@Test func aHotkeysKeyTheTapNeverSawCounts() {
    // BetterTouchTool posted Option-Tab for Kosmos's hotkey, and the tap saw its modifiers
    // but no key down: a hotkey takes its key before the tap. HID still counts it.
    var keyboard = Keyboard()
    keyboard.key(to: ghostty, at: 0)
    keyboard.hotkey(at: 2000)
    // Spotify activated before the modifiers came up: the decision finds the key.
    var decided = keyboard.input
    decided.noteUnseenKeys(hidKeys: keyboard.hid, lastKeyAt: ms(2000))
    #expect(cause(decided, of: chrome, at: 2150) == .opener(.unseenKey, ago: .milliseconds(150), beforeLaunch: false))
    // Raycast launched Chrome, whose window comes after the modifiers came up and Steve typed on.
    keyboard.modifiersUp(to: ghostty, at: 2100, lastKey: 2000)
    keyboard.key(to: ghostty, at: 2500)
    #expect(cause(keyboard.input, of: chrome, at: 7000, launched: 2200)
        == .opener(.unseenKey, ago: .milliseconds(200), beforeLaunch: true))
    // Keys the tap saw leave nothing unseen.
    var typing = Keyboard()
    for at in stride(from: 0, through: 1000, by: 100) { typing.key(to: ghostty, at: at) }
    typing.modifiersUp(to: ghostty, at: 1050, lastKey: 1000)
    typing.input.noteUnseenKeys(hidKeys: typing.hid, lastKeyAt: ms(1000))
    #expect(cause(typing.input, of: chrome, at: 1100) == nil)
}

@Test func aHotkeyUnderHeldModifiersCountsBeforeHIDCountsItsKey() {
    // Steve's Opt-Shift-S on 2026-11-16: the tap heard Option and Shift go down to the front app and
    // no key, Spotify activated 824 ms later, and HID counted the key 121 ms after that.
    var keyboard = Keyboard()
    keyboard.key(to: ghostty, at: 0)
    keyboard.modifiers(.maskAlternate, to: ghostty, at: 5000)
    keyboard.modifiers([.maskAlternate, .maskShift], to: ghostty, at: 5001)
    #expect(cause(keyboard.input, of: chrome, at: 5824) == .hotkey(heldFor: .milliseconds(824), beforeLaunch: false))
    // Held for longer than the opener bound, the key could have come just before.
    #expect(cause(keyboard.input, of: chrome, at: 7000) == .hotkey(heldFor: .milliseconds(2000), beforeLaunch: false))
    // Once the modifiers come up, the key came before that.
    keyboard.modifiersUp(to: ghostty, at: 7100, lastKey: 0)
    #expect(cause(keyboard.input, of: chrome, at: 8000) == .hotkey(heldFor: .milliseconds(3000), beforeLaunch: false))
    #expect(cause(keyboard.input, of: chrome, at: 8200) == nil)
    // Shift held to type a capital is no hotkey: the tap heard the key.
    keyboard.modifiers(.maskShift, to: ghostty, at: 10_000)
    keyboard.key(to: ghostty, at: 10_050)
    #expect(cause(keyboard.input, of: chrome, at: 10_100) == nil)
    // Cmd-Shift-T the tap heard, let go of Shift first: Command alone is no new chord.
    keyboard.modifiers(.maskCommand, to: ghostty, at: 15_000)
    keyboard.modifiers([.maskCommand, .maskShift], to: ghostty, at: 15_010)
    keyboard.key(to: ghostty, at: 15_050)
    keyboard.modifiers(.maskCommand, to: ghostty, at: 15_100)
    keyboard.modifiersUp(to: ghostty, at: 15_150, lastKey: 15_050)
    #expect(cause(keyboard.input, of: chrome, at: 16_000) == nil)
    #expect(keyboard.input.lastKey(at: ms(16_000)) == ms(15_050))
    // Modifiers another process posted, as BetterTouchTool's, are no chord of the user's.
    var posted = Keyboard()
    posted.key(to: ghostty, at: 0)
    posted.modifiers(.maskAlternate, to: ghostty, at: 2000, from: computerUse)
    #expect(cause(posted.input, of: chrome, at: 2100) == nil)
}

@Test func theLastKeyCountsAHotkeyUnderHeldModifiers() {
    // Steve held Option for 4.4 s over Opt-D, Opt-Shift-S and Opt-D on 2026-11-16.
    var keyboard = Keyboard()
    #expect(keyboard.input.lastKey(at: ms(0)) == nil)
    keyboard.key(to: ghostty, at: 0)
    keyboard.modifiers(.maskAlternate, to: ghostty, at: 2000)
    #expect(keyboard.input.lastKey(at: ms(1900)) == ms(0), "no chord before its modifiers")
    #expect(keyboard.input.lastKey(at: ms(6400)) == ms(6400), "a held chord's key is as late as the read")
    keyboard.modifiersUp(to: ghostty, at: 6500, lastKey: 0)
    #expect(keyboard.input.lastKey(at: ms(7000)) == ms(6500), "a released chord's key is no later than its release")
}

@Test func aClickUnderHeldModifiersIsTheClicksAndNoHotkeys() {
    var keyboard = Keyboard()
    keyboard.key(to: ghostty, at: 0)
    keyboard.modifiers(.maskCommand, to: ghostty, at: 10_000)
    keyboard.click(on: chatGPT, at: 10_200)
    #expect(keyboard.input.lastKey(at: ms(10_300)) == ms(0), "the Command-click stays the later press")
    #expect(cause(keyboard.input, of: chrome, at: 10_300) == .opener(.click(target: chatGPT), ago: .milliseconds(100), beforeLaunch: false))
}

@Test func aClickAfterAHotkeysReleaseKeepsItForTheLaunch() {
    // Raycast launches Chrome, whose first window can come 5.2 s after the hotkey.
    var keyboard = Keyboard()
    keyboard.key(to: ghostty, at: 0)
    keyboard.modifiers(.maskAlternate, to: ghostty, at: 1000)
    keyboard.modifiersUp(to: ghostty, at: 1300, lastKey: 0)
    keyboard.click(on: chatGPT, at: 3000)
    #expect(cause(keyboard.input, of: chrome, at: 6200, launched: 1500) == .hotkey(heldFor: .milliseconds(500), beforeLaunch: true))
}

@Test func hidsModifierStateClosesAChordWhoseReleaseTheTapMissed() {
    var keyboard = Keyboard()
    keyboard.key(to: ghostty, at: 0)
    keyboard.modifiers(.maskAlternate, to: ghostty, at: 1000)
    // Noticed at 5000 ms, released at 1200 ms by HID's last modifier change.
    keyboard.input.noteModifiersUp(lastChange: ms(1200))
    #expect(keyboard.input.lastKey(at: ms(5000)) == ms(1200))
    #expect(cause(keyboard.input, of: chrome, at: 5000) == nil, "no hotkey 3.8 s after HID's release")
    keyboard.modifiers(.maskAlternate, to: ghostty, at: 6000)
    #expect(cause(keyboard.input, of: chrome, at: 6100) == .hotkey(heldFor: .milliseconds(100), beforeLaunch: false), "the next press opens a new chord")
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
    #expect(keyboard.input.cause(at: ms(100), launched: nil, listening: false, target: place(from: chrome)) == .unheard)
}

@Test func pressesOlderThanAnyBoundAreDropped() {
    var keyboard = Keyboard()
    keyboard.click(on: finder, at: 0)
    keyboard.key(to: ghostty, at: 31_000)
    #expect(cause(keyboard.input, of: chrome, at: 31_100, launched: 500) == nil)
}
