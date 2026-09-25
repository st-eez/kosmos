import Testing
@testable import KosmosSkyLight

/// The check names classes and initializers this macOS has, so a typo in it would turn hiding
/// off here too.
@Test func thisMacOSHasEveryBridgedOperation() {
    #expect(SkyLight.missingBridgedOperation == nil)
}
