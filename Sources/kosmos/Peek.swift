import Darwin
import KosmosIPC

/// `kosmos peek <window id> -- <command> [args...]`: runs the command while Kosmos shows the
/// window past its display's edge, when Kosmos conceals it, and exits with the command's
/// status (docs/ipc.md, docs/hiding.md). The command runs whatever Kosmos answers.
func peek(_ args: [String], socketPath: String) -> Never {
    guard args.count >= 3, args[1] == "--", UInt32(args[0]) != nil else {
        fputs("usage: kosmos peek <window id> -- <command> [args...]\n", stderr)
        exit(2)
    }
    var held: HeldRequest?
    do throws(IPCError) {
        let (response, hold) = try IPCClient.open(["peek", args[0]], socketPath: socketPath, timeout: answerBound)
        if !response.stderr.isEmpty { fputs(response.stderr + "\n", stderr) }
        held = hold
    } catch .notRunning {
        // A Kosmos that is not running conceals nothing.
    } catch {
        fputs("kosmos: " + error.description + "; the command runs without a peek\n", stderr)
    }
    let status = run(Array(args[2...]))
    if let held {
        do throws(IPCError) {
            let response = try held.end(["ended", String(status)])
            if !response.stderr.isEmpty { fputs(response.stderr + "\n", stderr) }
        } catch {
            fputs("kosmos: " + error.description + "\n", stderr)
        }
    }
    exit(status)
}

/// Kosmos answers once the window shows, which can wait behind other peeks of up to 10 s each
/// (Peeks.timeout).
private let answerBound = Duration.seconds(30)

/// The command's exit status, 128 plus the signal that killed it, or 127 and 126 as a shell
/// gives for a command not found or not run.
func run(_ command: [String]) -> Int32 {
    // A Ctrl-C at the terminal reaches the command too; the CLI stays to end the peek.
    signal(SIGINT, SIG_IGN)
    signal(SIGQUIT, SIG_IGN)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var defaults = sigset_t()
    sigemptyset(&defaults)
    sigaddset(&defaults, SIGINT)
    sigaddset(&defaults, SIGQUIT)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))
    let argv = command.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let error = posix_spawnp(&pid, command[0], nil, &attributes, argv, environ)
    guard error == 0 else {
        fputs("kosmos: " + command[0] + ": " + String(cString: strerror(error)) + "\n", stderr)
        return error == ENOENT ? 127 : 126
    }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 {
        guard errno == EINTR else { return 1 }
    }
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : 128 + signal
}
