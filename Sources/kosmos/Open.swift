import Darwin
import KosmosIPC

/// `kosmos open [-a <app> | -b <bundle id>] [<file or URL>...] [open's options]`: runs
/// `open -g`, which leaves the app in the background, once Kosmos has claimed the app's new
/// windows for the agent workspace, then prints where they landed, and exits with its status
/// (docs/ipc.md). `open` runs whatever Kosmos answers.
func open(_ args: [String], socketPath: String) -> Never {
    guard !args.isEmpty else {
        fputs("usage: kosmos open [-a <app> | -b <bundle id>] [<file or URL>...] [open's options]\n", stderr)
        exit(2)
    }
    var claimed: (app: String, at: ContinuousClock.Instant)?
    if let claim = claim(args) {
        do throws(IPCError) {
            let response = try IPCClient.send(["claim"] + claim, socketPath: socketPath)
            if !response.stderr.isEmpty { fputs(response.stderr + "\n", stderr) }
            if response.exitCode == 0 { claimed = (response.stdout, .now) }
        } catch {
            fputs("kosmos: " + error.description + "; where the app's windows open is unknown\n", stderr)
        }
    }
    let status = run(["/usr/bin/open", "-g"] + args)
    if status == 0, let claimed { report(claimed.app, since: claimed.at, socketPath: socketPath) }
    exit(status)
}

/// Prints where what `open` opened landed, which Kosmos answers within the claim's 10 s and
/// half a second more. Kosmos reports the windows since this claim, not another's (docs/ipc.md).
private func report(_ app: String, since claimed: ContinuousClock.Instant, socketPath: String) {
    let elapsed = (ContinuousClock.now - claimed) / .milliseconds(1)
    do throws(IPCError) {
        let response = try IPCClient.open(["opened", app, String(Int(elapsed))], socketPath: socketPath, timeout: .seconds(15)).response
        if !response.stdout.isEmpty { print(response.stdout) }
        if !response.stderr.isEmpty { fputs(response.stderr + "\n", stderr) }
    } catch {
        fputs("kosmos: " + error.description + "; where it opened is unknown\n", stderr)
    }
}

/// `-a` or `-b` with its value, else the first file or URL, each path made absolute, as Kosmos
/// resolves it from another directory, a link's target in its place, a folder's ending with a
/// slash and an executable's after `-x`. `-e` names
/// TextEdit; `-t` and `-f` name the default text editor, which goes unclaimed, and `-R` opens no app. Nil when `args` name no app.
private func claim(_ args: [String]) -> [String]? {
    let valued: Set<String> = ["-a", "-b", "-s", "-u", "-i", "-o", "--arch", "--env", "--stdin", "--stdout", "--stderr"]
    func absolute(_ path: String) -> String { path.hasPrefix("/") ? path : workingDirectory() + "/" + path }
    let options = args.prefix { $0 != "--args" }
    // Short options can come together, as in `open -na Safari`, the last one taking a value.
    func given(_ letter: Character) -> Bool {
        options.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains(letter) }
    }
    if given("e") { return ["-b", "com.apple.TextEdit"] }
    // -R only reveals the file in Finder.
    if given("t") || given("f") || given("R") { return nil }
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
        if !arg.hasPrefix("-") { return isURL(arg) ? [arg] : file(absolute(arg)) }
        index += 1
    }
    return nil
}

/// `open` takes a URL with a scheme and no slashes too, as `mailto:` or
/// `x-apple.systempreferences:`, unless a file has that name.
private func isURL(_ arg: String) -> Bool {
    guard let colon = arg.firstIndex(of: ":"), arg.first?.isLetter == true,
          arg[..<colon].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else { return false }
    return access(arg, F_OK) != 0
}

/// Kosmos finds the opener from what the CLI sends alone: a link's target, as LaunchServices
/// goes by the target's name, a folder's path ending with a slash, and a file with any execute
/// bit, which with no extension opens in Terminal, after `-x`.
private func file(_ path: String) -> [String] {
    var info = stat()
    guard let resolved = realpath(path, nil) else { return [path] }
    let path = String(cString: resolved)
    free(resolved)
    guard stat(path, &info) == 0 else { return [path] }
    switch info.st_mode & S_IFMT {
    case S_IFDIR: return [path.hasSuffix("/") ? path : path + "/"]
    case S_IFREG where info.st_mode & 0o111 != 0: return ["-x", path]
    default: return [path]
    }
}

private func workingDirectory() -> String {
    guard let path = getcwd(nil, 0) else { return "." }
    defer { free(path) }
    return String(cString: path)
}
