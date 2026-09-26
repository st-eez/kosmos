import AppKit

if CommandLine.arguments.dropFirst().first == "launch-at-login" {
    exit(LaunchAtLogin.command(Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.dropFirst().first == "onboarding-snapshot" {
    exit(Onboarding.snapshot(Array(CommandLine.arguments.dropFirst(2))))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
