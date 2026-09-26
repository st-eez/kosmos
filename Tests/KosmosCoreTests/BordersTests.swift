import CoreGraphics
import Testing
@testable import KosmosCore

private let blue = BorderColor(hex: "#7aa2f7")!
private let steve = BorderSettings(width: 2, active: blue)
/// macOS's blue accent in the light appearance.
private let accent = BorderColor(red: 0, green: 122 / 255, blue: 1, alpha: 1)
/// macOS's system red in the light appearance.
private let red = BorderColor(red: 1, green: 59 / 255, blue: 48 / 255, alpha: 1)

@Test func colorsAreHexWithOptionalAlphaLast() {
    #expect(blue == BorderColor(red: 0x7A / 255, green: 0xA2 / 255, blue: 0xF7 / 255, alpha: 1))
    #expect(BorderColor(hex: "#7aa2f780") == BorderColor(red: 0x7A / 255, green: 0xA2 / 255, blue: 0xF7 / 255, alpha: 0x80 / 255))
    #expect(BorderColor(hex: "#00000000") == .clear)
    #expect(BorderColor(hex: "#FFFFFF")?.red == 1)
    for bad in ["7aa2f7", "#7aa2f", "#7aa2g7", "#7aa2f7ff0", "#7aa2f7ff00", "#+7aa2f7", ""] {
        #expect(BorderColor(hex: bad) == nil, "\(bad)")
    }
}

@Test func theRingLiesOutsideTheWindowsEdge() {
    let display = Monitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
    let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
    let border = Border(around: frame, radius: 16, width: 2, color: blue, displays: [display])!
    #expect(border.ring == CGRect(x: 98, y: 98, width: 404, height: 304))
    #expect(border.frame == border.ring && border.display == 1 && border.displayFrame == display.frame)
    #expect(border.cornerRadius == 18 && border.lineWidth == 2)
    // The inner edge is the window's edge, its radius the window's.
    #expect(border.ring.insetBy(dx: border.lineWidth, dy: border.lineWidth) == frame)
    #expect(border.cornerRadius - border.lineWidth == 16)
    // A square window gets square corners.
    let square = Border(around: frame, radius: 0, width: 2, color: blue, displays: [display])!
    #expect(square.cornerRadius == 0)
}

@Test func theBorderStaysOnTheWindowsDisplay() {
    let left = Monitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let right = Monitor(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
    let mostlyLeft = Border(around: CGRect(x: 600, y: 100, width: 500, height: 300), radius: 16, width: 2, color: blue,
                            displays: [left, right])!
    #expect(mostlyLeft.display == 1 && mostlyLeft.frame == CGRect(x: 598, y: 98, width: 402, height: 304))
    let mostlyRight = Border(around: CGRect(x: 900, y: 100, width: 500, height: 300), radius: 16, width: 2, color: blue,
                             displays: [left, right])!
    #expect(mostlyRight.display == 2 && mostlyRight.frame.minX == 1000 && mostlyRight.ring.minX == 898)
    // At a display's edge the ring is cut there too.
    let edge = Border(around: CGRect(x: 0, y: 0, width: 500, height: 300), radius: 16, width: 2, color: blue, displays: [left])!
    #expect(edge.frame == CGRect(x: 0, y: 0, width: 502, height: 302))
    // A window off every display has no border.
    #expect(Border(around: CGRect(x: 100_000, y: 100_000, width: 500, height: 300), radius: 16, width: 2, color: blue,
                   displays: [left, right]) == nil)
}

@Test func theShownTiledAndFloatingWindowsAreBordered() {
    var s = Session(names: ["1", "2"], display: CGRect(x: 0, y: 0, width: 1000, height: 800))
    _ = s.add(1); _ = s.add(2); _ = s.add(3, floating: true)
    _ = s.add(4, to: "2")
    s.adopt(2)
    #expect(s.bordered == [1: false, 2: true, 3: false])
    // Minimized, hidden or in native fullscreen: parked, with no border.
    _ = s.park([1], because: .minimized)
    #expect(s.bordered == [2: true, 3: false])
    // Kosmos's fullscreen takes the tiles' borders, the fullscreen window's too.
    _ = s.perform(.fullscreen)
    #expect(s.bordered == [3: false])
    _ = s.perform(.fullscreen)
    // Another workspace shown: its windows have the borders.
    _ = s.perform(.workspace(.named("2")))
    #expect(s.bordered == [4: true])
}

@Test func aLiftedWindowKeepsTheActiveBorder() {
    var s = Session(names: ["1"], display: CGRect(x: 0, y: 0, width: 1000, height: 800))
    _ = s.add(1); _ = s.add(2)
    s.adopt(2)
    _ = s.lift(2)
    #expect(s.bordered[2] == true && s.isParked(2))
}

@Test func bordersDrawOnlyVisibleColorsOfWindowsOnScreen() {
    var s = Session(names: ["1"], display: CGRect(x: 0, y: 0, width: 1000, height: 800))
    _ = s.add(1); _ = s.add(2); _ = s.add(3)
    s.adopt(2)
    let frames: [WindowID: CGRect] = [1: CGRect(x: 10, y: 10, width: 300, height: 700), 2: CGRect(x: 320, y: 10, width: 300, height: 700)]
    // Window 3 is concealed or ordered out, so `shown` finds it nowhere.
    let shown = { (id: WindowID) in frames[id].map { (frame: $0, radius: CGFloat(16)) } }
    #expect(Array(s.borders(steve, accent: accent, red: red, flashing: [], shown: shown).keys) == [2])
    #expect(s.borders(BorderSettings(), accent: accent, red: red, flashing: [], shown: shown).mapValues(\.color) == [2: accent])
    let both = BorderSettings(width: 2, active: blue, inactive: BorderColor(hex: "#414868")!)
    let borders = s.borders(both, accent: accent, red: red, flashing: [], shown: shown)
    #expect(Set(borders.keys) == [1, 2] && borders[1]?.color == both.inactive && borders[2]?.color == blue)
    #expect(borders[2]?.ring == frames[2]!.insetBy(dx: -2, dy: -2))
}

@Test func aWindowWhoseAppRefusesItsTileFlashesTheWarningColor() {
    var s = Session(names: ["1"], display: CGRect(x: 0, y: 0, width: 1000, height: 800))
    _ = s.add(1); _ = s.add(2)
    s.adopt(2)
    let frames: [WindowID: CGRect] = [1: CGRect(x: 0, y: 0, width: 500, height: 800), 2: CGRect(x: 500, y: 0, width: 500, height: 800)]
    let shown = { (id: WindowID) in frames[id].map { (frame: $0, radius: CGFloat(16)) } }
    // The inactive window, transparent otherwise, flashes the system red, and so does the focused one.
    #expect(s.borders(steve, accent: accent, red: red, flashing: [1], shown: shown).mapValues(\.color) == [1: red, 2: blue])
    #expect(s.borders(steve, accent: accent, red: red, flashing: [2], shown: shown).mapValues(\.color) == [2: red])
    let pink = BorderColor(hex: "#f7768e")!
    var themed = steve
    themed.warning = pink
    #expect(s.borders(themed, accent: accent, red: red, flashing: [1], shown: shown)[1]?.color == pink)
    // A transparent warning leaves each window its own color.
    themed.warning = .clear
    #expect(s.borders(themed, accent: accent, red: red, flashing: [1, 2], shown: shown).mapValues(\.color) == [2: blue])
}

/// v[3 h[1 2]] on a 1000 by 800 display, with 2 held to 500 points tall.
@Test func onlyAWindowWhoseTileMovesAlongTheAxisItRefusesFlashes() {
    var s = Session(names: ["1"], display: CGRect(x: 0, y: 0, width: 1000, height: 800))
    for window: WindowID in [1, 2, 3] {
        _ = s.add(window)
        s.adopt(window)
    }
    let before = s.perform(.move(.up))!.frames
    #expect(before[2] == CGRect(x: 500, y: 400, width: 500, height: 400))
    var tiles: [WindowID: CGRect] = [:]
    #expect(s.spilling(before, written: [], tiles: &tiles) { _ in nil }.isEmpty)
    _ = s.constrain(2, to: CGSize(width: 0, height: 500))
    let spilled = s.frames(of: "1")
    #expect(spilled[2] == CGRect(x: 500, y: 400, width: 500, height: 500))
    // Written where it showed at its tile, it refuses the tile and flashes.
    #expect(s.spilling(spilled, written: [2], tiles: &tiles) { before[$0] } == [2])
    // Where it already shows, it has nothing new to refuse.
    #expect(s.spilling(spilled, written: [2], tiles: &tiles) { spilled[$0] }.isEmpty)
    // A width resize moves it across, the axis its minimum leaves free.
    s.adopt(1)
    let resized = s.perform(.resize(.width, by: 100))!.frames
    #expect(resized[2] == CGRect(x: 600, y: 400, width: 400, height: 500))
    #expect(s.spilling(resized, written: [1, 2], tiles: &tiles) { spilled[$0] }.isEmpty)
    // A height resize moves the edge it refuses.
    let shorter = s.perform(.resize(.height, by: -100))!.frames
    #expect(shorter[2] == CGRect(x: 600, y: 500, width: 400, height: 500))
    #expect(s.spilling(shorter, written: [1, 2, 3], tiles: &tiles) { resized[$0] } == [2])
    // A window that leaves is forgotten.
    _ = s.remove(2)
    _ = s.spilling(s.frames(of: "1"), written: [], tiles: &tiles) { _ in nil }
    #expect(tiles[2] == nil)
}
