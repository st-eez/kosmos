import Foundation
import ServiceManagement

/// Launch at login through the app's LaunchAgent, whose `KeepAlive` restarts Kosmos after a
/// crash (docs/onboarding.md). Ceiling: a Kosmos opened by hand has no crash restart until
/// the next login; `launchctl kickstart` whenever the agent is enabled would close that gap.
@MainActor
enum LaunchAtLogin {
    static let label = "io.github.st-eez.kosmos"
    /// `.notFound` until the first registration: Background Task Management has no record
    /// of the agent before then.
    static var service: SMAppService { .agent(plistName: label + ".plist") }

    /// launchd started this process as the agent, which unregistering kills.
    static var isAgent: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }

    /// For script/install.sh: SMAppService acts for the bundle of the process that calls it,
    /// so the scripts go through the app.
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
