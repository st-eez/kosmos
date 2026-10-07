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

/// `-a` or `-b` with its value, else the first file or URL, made absolute, as Kosmos resolves
/// it from another directory. Nil when `args` name neither.
private func claim(_ args: [String]) -> [String]? {
    let valued: Set<String> = ["-a", "-b", "-s", "-u", "--env", "--stdin", "--stdout", "--stderr"]
    var index = 0
    while index < args.count, args[index] != "--args" {
        let arg = args[index]
        if arg == "-a" || arg == "-b" { return index + 1 < args.count ? [arg, args[index + 1]] : nil }
        if arg == "-u" { return index + 1 < args.count ? [args[index + 1]] : nil }
        if valued.contains(arg) {
            index += 2
            continue
        }
        if !arg.hasPrefix("-") { return [arg.contains("://") || arg.hasPrefix("/") ? arg : workingDirectory() + "/" + arg] }
        index += 1
    }
    return nil
}

private func workingDirectory() -> String {
    guard let path = getcwd(nil, 0) else { return "." }
    defer { free(path) }
    return String(cString: path)
}
