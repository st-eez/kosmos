import AppKit

/// Ends the observation before it releases the app, as AppKit messages an NSRunningApplication
/// freed while observed at the next policy notification (docs/inventory.md).
public final class PolicyWatch {
    public let app: NSRunningApplication
    private let observation: NSKeyValueObservation

    public init(_ app: NSRunningApplication, changed: @escaping @Sendable () -> Void) {
        self.app = app
        observation = app.observe(\.activationPolicy) { _, _ in changed() }
    }

    /// A class releases its properties after its deinit, so `app` is still held here.
    deinit { observation.invalidate() }
}
