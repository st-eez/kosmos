import AppKit

@MainActor
final class ShutdownCheck: NSObject, NSApplicationDelegate {
    let production = AppDelegate()
    private var requested = false

    /// How the check quits: a direct terminate, as Quit Kosmos does, SIGTERM, as
    /// `script/install.sh` sends, or SIGTERM while a menu tracks.
    private let route = CommandLine.arguments.dropFirst().first ?? "--terminate"

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard route != "--terminate" else { return NSApp.terminate(nil) }
        production.handleTerminationSignals()
        guard route == "--sigterm-tracking" else { return _ = kill(getpid(), SIGTERM) }
        // A menu tracks from the run loop, as this block runs, not from a main-queue block.
        RunLoop.main.perform {
            kill(getpid(), SIGTERM)
            let end = Date.now + 3
            while Date.now < end { RunLoop.main.run(mode: .eventTracking, before: end) }
            fputs("FAIL SIGTERM waited for the tracking loop to end\n", stderr)
            exit(1)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let result = production.applicationShouldTerminate(sender)
        precondition(result == .terminateLater)
        requested = true
        return result
    }

    func applicationWillTerminate(_ notification: Notification) {
        precondition(requested)
        print("PASS production quit hook completes its asynchronous worker barrier through AppKit, \(route)")
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
