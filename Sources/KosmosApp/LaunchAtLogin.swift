import Foundation
import ServiceManagement

/// Launch at login through the LaunchAgent in Contents/Library/LaunchAgents, whose
/// `KeepAlive` restarts Kosmos after a crash (docs/overview.md, section 4.1).
///
/// Registering starts the agent at once. While another Kosmos holds the instance lock, the
/// agent's copy exits successfully and launchd leaves it stopped until the next login, so a
/// Kosmos opened by hand runs without crash restarts until then. Starting it through
/// `launchctl kickstart` whenever the agent is enabled would close that gap.
@MainActor
enum LaunchAtLogin {
    static let label = "io.github.st-eez.kosmos"
    /// Its status is `.notFound` until the first registration, since Background Task
    /// Management has no record of the agent before then.
    static var service: SMAppService { .agent(plistName: label + ".plist") }

    /// Whether launchd started this process as the agent. Unregistering kills that process.
    static var isAgent: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }

    /// `Kosmos launch-at-login status | on | off`, for script/install.sh. SMAppService acts
    /// for the bundle of the process that calls it, so the scripts go through the app.
    static func command(_ arguments: [String]) -> Int32 {
        do {
            switch arguments {
            case ["status"]:
                switch service.status {
                case .enabled: print("enabled")
                case .requiresApproval: print("requires-approval")
                default: print("not-registered")
                }
            case ["on"]: try service.register()
            case ["off"]: try service.unregister()
            default:
                FileHandle.standardError.write(Data("usage: Kosmos launch-at-login status | on | off\n".utf8))
                return 2
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("launch at login: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
