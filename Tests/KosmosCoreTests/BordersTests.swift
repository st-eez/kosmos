import CoreGraphics
import Testing
@testable import KosmosCore

private let blue = BorderColor(hex: "#7aa2f7")!
private let steve = BorderSettings(width: 4, active: blue)
/// macOS's blue accent in the light appearance.
private let accent = BorderColor(red: 0, green: 122 / 255, blue: 1, alpha: 1)

@Test func colorsAreHexWithOptionalAlphaLast() {
    #expect(blue == BorderColor(red: 0x7A / 255, green: 0xA2 / 255, blue: 0xF7 / 255, alpha: 1))
    #expect(BorderColor(hex: "#7aa2f780") == BorderColor(red: 0x7A / 255, green: 0xA2 / 255, blue: 0xF7 / 255, alpha: 0x80 / 255))
    #expect(BorderColor(hex: "#00000000") == .clear)
    #expect(BorderColor(hex: "#FFFFFF")?.red == 1)
    for bad in ["7aa2f7", "#7aa2f", "#7aa2g7", "#7aa2f7ff0", "#7aa2f7ff00", "#+7aa2f7", ""] {
        #expect(BorderColor(hex: bad) == nil, "\(bad)")
    }
}

/// A transparent color draws no border, as Steve's inactive color does, and with no color
/// given the focused window's border is the accent color.
@Test func aTransparentColorDrawsNoBorder() {
    #expect(steve.color(focused: true, accent: accent) == blue)
    #expect(steve.color(focused: false, accent: accent) == nil)
    let both = BorderSettings(width: 2, active: blue, inactive: BorderColor(hex: "#414868")!)
    #expect(both.color(focused: false, accent: accent) == BorderColor(hex: "#414868"))
    #expect(BorderSettings().color(focused: true, accent: accent) == accent)
    #expect(BorderSettings().color(focused: false, accent: accent) == nil)
}

/// The line is centered on the window's edge as JankyBorders draws it: 2 of its 4 points
/// outside, and 1 point inside over the window's edge, with corners concentric with the
/// window's.
@Test func theRingStraddlesTheWindowsEdge() {
    let display = Monitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
    let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
    let border = Border(around: frame, radius: 16, width: 4, color: blue, displays: [display])!
    #expect(border.ring == CGRect(x: 98, y: 98, width: 404, height: 304))
    #expect(border.frame == border.ring && border.display == 1 && border.displayFrame == display.frame)
    #expect(border.cornerRadius == 18 && border.lineWidth == 3)
    // The inner edge is 1 point inside the frame, its radius 1 point less than the window's.
    #expect(border.ring.insetBy(dx: border.lineWidth, dy: border.lineWidth) == frame.insetBy(dx: 1, dy: 1))
    #expect(border.cornerRadius - border.lineWidth == 15)
    // A line narrower than 2 points shows its whole inner half; a square window gets square corners.
    let thin = Border(around: frame, radius: 0, width: 1, color: blue, displays: [display])!
    #expect(thin.lineWidth == 1 && thin.cornerRadius == 0)
}

/// The border shows on the display that holds most of the window, cut to it, and a window on
/// no display gets none.
@Test func theBorderStaysOnTheWindowsDisplay() {
    let left = Monitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let right = Monitor(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
    let mostlyLeft = Border(around: CGRect(x: 600, y: 100, width: 500, height: 300), radius: 16, width: 4, color: blue,
                            displays: [left, right])!
    #expect(mostlyLeft.display == 1 && mostlyLeft.frame == CGRect(x: 598, y: 98, width: 402, height: 304))
    let mostlyRight = Border(around: CGRect(x: 900, y: 100, width: 500, height: 300), radius: 16, width: 4, color: blue,
                             displays: [left, right])!
    #expect(mostlyRight.display == 2 && mostlyRight.frame.minX == 1000 && mostlyRight.ring.minX == 898)
    // At a display's edge the ring is cut there too.
    let edge = Border(around: CGRect(x: 0, y: 0, width: 500, height: 300), radius: 16, width: 4, color: blue, displays: [left])!
    #expect(edge.frame == CGRect(x: 0, y: 0, width: 502, height: 302))
    // Concealed windows read far off every display.
    #expect(Border(around: CGRect(x: 100_000, y: 100_000, width: 500, height: 300), radius: 16, width: 4, color: blue,
                   displays: [left, right]) == nil)
}

@Test func theShownTiledAndFloatingWindowsAreBordered() {
    var s = Session(names: ["1", "2"], display: CGRect(x: 0, y: 0, width: 1000, height: 800))
    _ = s.add(1); _ = s.add(2); _ = s.add(3, floating: true)
    _ = s.add(4, to: "2")
    s.adopt(2)
    #expect(s.bordered == [1: false, 2: true, 3: false])
    // Minimized, hidden or in native fullscreen: parked, with no border.
    _ = s.park([1])
    #expect(s.bordered == [2: true, 3: false])
    // Kosmos's fullscreen takes the tiles' borders, the fullscreen window's too.
    _ = s.perform(.fullscreen)
    #expect(s.bordered == [3: false])
    _ = s.perform(.fullscreen)
    // Another workspace shown: its windows have the borders.
    _ = s.perform(.workspace(.named("2")))
    #expect(s.bordered == [4: true])
}

/// A tiled window the user drags by its title bar is parked, and keeps its border with the
/// focus's color.
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
    #expect(Array(s.borders(steve, accent: accent, shown: shown).keys) == [2])
    #expect(s.borders(BorderSettings(), accent: accent, shown: shown).mapValues(\.color) == [2: accent])
    let both = BorderSettings(width: 4, active: blue, inactive: BorderColor(hex: "#414868")!)
    let borders = s.borders(both, accent: accent, shown: shown)
    #expect(Set(borders.keys) == [1, 2] && borders[1]?.color == both.inactive && borders[2]?.color == blue)
    #expect(borders[2]?.ring == frames[2]!.insetBy(dx: -2, dy: -2))
}
