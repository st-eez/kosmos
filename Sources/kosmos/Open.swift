import Darwin
import KosmosIPC

/// `kosmos open [-a <app> | -b <bundle id>] [<file or URL>...] [open's options]`: runs
/// `open -g`, which leaves the app in the background, once Kosmos has claimed the app's new
/// windows for the agent workspace, and exits with its status (docs/ipc.md). `open` runs
/// whatever Kosmos answers.
func open(_ args: [String], socketPath: String) -> Never {
    guard !args.isEmpty else {
        fputs("usage: kosmos open [-a <app> | -b <bundle id>] [<file or URL>...] [open's options]\n", stderr)
        exit(2)
    }
    if let claim = claim(args) {
        do throws(IPCError) {
            let response = try IPCClient.send(["claim"] + claim, socketPath: socketPath)
            if !response.stderr.isEmpty { fputs(response.stderr + "\n", stderr) }
        } catch {
            fputs("kosmos: " + error.description + "; the app's windows open where they would\n", stderr)
        }
    }
    exit(run(["/usr/bin/open", "-g"] + args))
}

/// `-a` or `-b` with its value, else the first file or URL, each path made absolute, as Kosmos
/// resolves it from another directory. `-e` names TextEdit; `-t` and `-f` name the default text
/// editor, which goes unclaimed. Nil when `args` name no app.
private func claim(_ args: [String]) -> [String]? {
    let valued: Set<String> = ["-a", "-b", "-s", "-u", "--env", "--stdin", "--stdout", "--stderr"]
    func absolute(_ path: String) -> String { path.hasPrefix("/") ? path : workingDirectory() + "/" + path }
    let options = args.prefix { $0 != "--args" }
    // Short options can come together, as in `open -na Safari`, the last one taking a value.
    func given(_ letter: Character) -> Bool {
        options.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains(letter) }
    }
    if given("e") { return ["-b", "com.apple.TextEdit"] }
    if given("t") || given("f") { return nil }
    var index = 0
    while index < args.count, args[index] != "--args" {
        var arg = args[index]
        if arg.count > 2, arg.hasPrefix("-"), !arg.hasPrefix("--"), let last = arg.last, "abu".contains(last) { arg = "-\(last)" }
        if arg == "-a", index + 1 < args.count { return [arg, args[index + 1].contains("/") ? absolute(args[index + 1]) : args[index + 1]] }
        if arg == "-b" { return index + 1 < args.count ? [arg, args[index + 1]] : nil }
        if arg == "-u" { return index + 1 < args.count ? [args[index + 1]] : nil }
        if valued.contains(arg) {
            index += 2
            continue
        }
        if !arg.hasPrefix("-") { return [arg.contains("://") ? arg : absolute(arg)] }
        index += 1
    }
    return nil
}

private func workingDirectory() -> String {
    guard let path = getcwd(nil, 0) else { return "." }
    defer { free(path) }
    return String(cString: path)
}
