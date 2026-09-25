import Foundation
import Testing
@testable import KosmosSkyLight

@Test func anOrdinaryCurrentSpaceWins() {
    #expect(Displays.ordinarySpace(current: 3, spaces: [3, 4], original: 4) == 3)
}

/// A native fullscreen Space on screen leaves no ordinary current Space.
@Test func withoutOneTheOriginalSpaceIsUsedWhileItExists() {
    #expect(Displays.ordinarySpace(current: nil, spaces: [3, 4], original: 4) == 4)
    #expect(Displays.ordinarySpace(current: nil, spaces: [3, 4], original: 99) == 3)
    #expect(Displays.ordinarySpace(current: nil, spaces: [3, 4], original: nil) == 3)
}

@Test func noOrdinarySpaceIsNil() {
    #expect(Displays.ordinarySpace(current: nil, spaces: [], original: 4) == nil)
}

private func space(_ id: UInt64, type: Int) -> [String: Any] { ["id64": NSNumber(value: id), "type": NSNumber(value: type)] }

/// As SLSCopyManagedDisplaySpaces lists them: display A shows ordinary Space 3 and has native
/// fullscreen Space 5, and display B shows its fullscreen Space 8.
private let twoDisplays = Displays(raw: [
    ["Display Identifier": "A", "Current Space": space(3, type: 0), "Spaces": [space(3, type: 0), space(5, type: 4), space(4, type: 0)]],
    ["Display Identifier": "B", "Current Space": space(8, type: 4), "Spaces": [space(7, type: 0), space(8, type: 4)]],
])

@Test func typeZeroIsOrdinaryAndTypeFourFullscreen() {
    #expect(twoDisplays.displays[0].ordinarySpaces == [3, 4])
    #expect(twoDisplays.ordinarySpaces == [3, 4, 7])
    #expect(twoDisplays.fullscreenSpaces == [5, 8])
    #expect(twoDisplays.allSpaces == [3, 5, 4, 7, 8])
}

@Test func aCurrentSpaceThatIsNotOrdinaryIsNone() {
    #expect(twoDisplays.displays.map(\.currentSpace) == [3, nil])
}

/// With one display macOS names it "Main" instead of by UUID.
@Test func anUnknownUUIDFallsBackToMain() {
    #expect(twoDisplays.display(uuid: "B")?.identifier == "B")
    #expect(twoDisplays.display(uuid: "C") == nil)
    let one = Displays(raw: [["Display Identifier": "Main", "Current Space": space(3, type: 0), "Spaces": [space(3, type: 0)]]])
    #expect(one.display(uuid: "C")?.identifier == "Main")
}
