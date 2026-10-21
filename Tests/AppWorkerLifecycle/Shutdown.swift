import AppKit

@MainActor
final class ShutdownCheck: NSObject, NSApplicationDelegate {
    let production = AppDelegate()
    private var requested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let result = production.applicationShouldTerminate(sender)
        precondition(result == .terminateLater)
        requested = true
        return result
    }

    func applicationWillTerminate(_ notification: Notification) {
        precondition(requested)
        print("PASS production quit hook completes its asynchronous worker barrier through AppKit")
        fflush(stdout)
    }
}

@main
struct ShutdownMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = ShutdownCheck()
        app.delegate = delegate
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            fputs("FAIL production quit hook did not complete\n", stderr)
            exit(1)
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
