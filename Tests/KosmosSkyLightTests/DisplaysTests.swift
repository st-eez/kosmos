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
