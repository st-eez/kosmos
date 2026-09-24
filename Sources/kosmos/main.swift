import Darwin
import KosmosIPC

// KOSMOS_SOCKET points the CLI at another server, such as the one the tests start.
let socketPath = getenv("KOSMOS_SOCKET").map { String(cString: $0) } ?? kosmosSocketPath()
let args = Array(CommandLine.arguments.dropFirst())

guard let command = args.first else {
    fputs("usage: kosmos <command> [args...]\n", stderr)
    exit(2)
}

do throws(IPCError) {
    let response: Response
    if command == "subscribe" {
        guard args.count == 1 else {
            fputs("usage: kosmos subscribe\n", stderr)
            exit(2)
        }
        response = try IPCClient.subscribe(socketPath: socketPath) { body in
            fwrite(body, 1, body.count, stdout)
            fputc(0x0A, stdout)
            fflush(stdout)
        }
    } else {
        response = try IPCClient.send(args, socketPath: socketPath)
    }
    // fputs and the typed error avoid print and "\(error)", whose runtime type checks cost
    // about half a millisecond on first use.
    if !response.stdout.isEmpty { fputs(response.stdout + "\n", stdout) }
    if !response.stderr.isEmpty { fputs(response.stderr + "\n", stderr) }
    exit(response.exitCode)
} catch {
    fputs("kosmos: " + error.description + "\n", stderr)
    exit(1)
}
