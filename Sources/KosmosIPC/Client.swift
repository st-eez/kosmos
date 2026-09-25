import Darwin

/// No dispatch queues or tasks, which keeps the CLI's launch near a bare Swift binary's.
public enum IPCClient {
    private static let timeout = Duration.seconds(5)

    public static func send(_ args: [String], socketPath: String) throws(IPCError) -> Response {
        try exchange(.command(args), socketPath: socketPath).response
    }

    /// Returns Kosmos's refusal at once, else its success response once the stream ends. The
    /// timeout covers only the first response.
    public static func subscribe(socketPath: String, onFrame: ([UInt8]) -> Void) throws(IPCError) -> Response {
        let (connection, response) = try exchange(.subscribe, socketPath: socketPath)
        guard response.exitCode == 0 else { return response }
        while let body = try connection.readFrame(deadline: nil) { onFrame(body) }
        return response
    }

    private static func exchange(
        _ request: Request, socketPath: String
    ) throws(IPCError) -> (connection: ClientConnection, response: Response) {
        let deadline = ContinuousClock.now + timeout
        let connection = try ClientConnection(socketPath: socketPath)
        try connection.write(frame(request.encoded), deadline: deadline)
        guard let body = try connection.readFrame(deadline: deadline) else { throw IPCError.closed }
        return (connection, try Response(decoding: body))
    }
}

/// Nonblocking and waiting with `poll`, so every wait can have a deadline.
final class ClientConnection {
    private let fd: Int32
    private var decoder = FrameDecoder()

    init(socketPath: String) throws(IPCError) {
        // Once `fd` is set, a throw below releases this object and deinit closes the socket.
        // Closing it here as well could close a descriptor another thread has just opened.
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.system("socket", errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = try withSocketAddress(socketPath) { connect(fd, $0, $1) }
        guard result == 0 else {
            let code = errno
            throw code == ENOENT || code == ECONNREFUSED
                ? IPCError.notRunning(socketPath: socketPath) : IPCError.system("connect \(socketPath)", code)
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    }

    deinit {
        Darwin.close(fd)
    }

    func write(_ bytes: [UInt8], deadline: ContinuousClock.Instant) throws(IPCError) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written >= 0 {
                offset += written
            } else if errno == EAGAIN {
                try wait(for: Int16(POLLOUT), deadline: deadline)
            } else if errno == EPIPE || errno == ENOTCONN {
                // ENOTCONN comes when the server's close lands before the write: 14 of 3000
                // rejected clients in a loop got it, the rest EPIPE or a closed read.
                throw IPCError.closed
            } else if errno != EINTR {
                throw IPCError.system("write", errno)
            }
        }
    }

    /// Nil when the server closes between frames. A nil deadline waits indefinitely.
    func readFrame(deadline: ContinuousClock.Instant?) throws(IPCError) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            if let body = try decoder.next() { return body }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                decoder.append(buffer[..<count])
            } else if count == 0 || errno == ECONNRESET {
                guard decoder.isEmpty else { throw IPCError.closed }
                return nil
            } else if errno == EAGAIN {
                try wait(for: Int16(POLLIN), deadline: deadline)
            } else if errno != EINTR {
                throw IPCError.system("read", errno)
            }
        }
    }

    private func wait(for events: Int16, deadline: ContinuousClock.Instant?) throws(IPCError) {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        while true {
            var timeout: Int32 = -1
            if let deadline {
                let remaining = deadline - .now
                guard remaining > .zero else { throw IPCError.timedOut }
                timeout = Int32(min((remaining / .milliseconds(1)).rounded(.up), Double(Int32.max)))
            }
            let ready = poll(&descriptor, 1, timeout)
            if ready > 0 { return }
            if ready < 0 && errno != EINTR { throw IPCError.system("poll", errno) }
        }
    }
}
