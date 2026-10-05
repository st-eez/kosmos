import Darwin
import Dispatch

/// All socket I/O runs on the server's serial queue, which is also the actor's executor. Only
/// the handler runs on the main actor, and waiting for it holds up no other client.
public actor IPCServer {
    static let requestDeadline = DispatchTimeInterval.seconds(1)

    private let queue: DispatchSerialQueue
    private let socketPath: String
    private let allowedUID: uid_t
    private let log: @Sendable (String) -> Void
    private let handler: @MainActor ([String]) async -> Reply
    private let listenerFD: Int32
    private let listener: any DispatchSourceRead
    private var connections: [Int: Connection] = [:]
    private var nextID = 0
    private var stopped = false

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// A file already at the path is taken as stale and replaced, so start only after taking
    /// Kosmos's instance lock.
    public init(
        socketPath: String,
        log: @escaping @Sendable (String) -> Void,
        handler: @escaping @MainActor ([String]) async -> Reply
    ) throws(IPCError) {
        try self.init(socketPath: socketPath, allowedUID: getuid(), log: log, handler: handler)
    }

    /// For a handler that holds no connection.
    public init(
        socketPath: String,
        log: @escaping @Sendable (String) -> Void,
        handler: @escaping @MainActor ([String]) async -> Response
    ) throws(IPCError) {
        try self.init(socketPath: socketPath, allowedUID: getuid(), log: log) { Reply(await handler($0)) }
    }

    /// Tests pass another uid to exercise the rejection path.
    init(
        socketPath: String,
        allowedUID: uid_t,
        log: @escaping @Sendable (String) -> Void,
        handler: @escaping @MainActor ([String]) async -> Response
    ) throws(IPCError) {
        try self.init(socketPath: socketPath, allowedUID: allowedUID, log: log) { Reply(await handler($0)) }
    }

    init(
        socketPath: String,
        allowedUID: uid_t,
        log: @escaping @Sendable (String) -> Void,
        handler: @escaping @MainActor ([String]) async -> Reply
    ) throws(IPCError) {
        try secureDirectory(of: socketPath)
        let listenerFD = try listen(at: socketPath)
        let queue = DispatchSerialQueue(label: "kosmos.ipc")
        let listener = DispatchSource.makeReadSource(fileDescriptor: listenerFD, queue: queue)
        self.queue = queue
        self.socketPath = socketPath
        self.allowedUID = allowedUID
        self.log = log
        self.handler = handler
        self.listenerFD = listenerFD
        self.listener = listener
        // The handler holds the server until stop() cancels the source.
        listener.setEventHandler { self.assumeIsolated { $0.acceptPending() } }
        listener.setCancelHandler { Darwin.close(listenerFD) }
        listener.activate()
    }

    /// Waits only for the server's queue, which never blocks on a client.
    public nonisolated func stop() {
        queue.sync { self.assumeIsolated { $0.shutDown() } }
    }

    private final class Connection {
        enum Phase {
            case request
            /// The handler runs, or its response is on its way.
            case answering
            /// After a held response, until the client's next request or its close.
            case held(@MainActor @Sendable ([String]?) -> Response)
        }

        let io: DispatchIO
        var decoder = FrameDecoder()
        var phase = Phase.request
        var clientClosed = false

        init(io: DispatchIO) {
            self.io = io
        }
    }

    private func acceptPending() {
        while true {
            let fd = accept(listenerFD, nil, nil)
            guard fd >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                // Out of descriptors (EMFILE or ENFILE), macOS closes the pending connection, so
                // this loop cannot spin: the client reads EOF, and the next accept gets EAGAIN.
                if errno != EAGAIN { log("accept failed: \(String(cString: strerror(errno)))") }
                return
            }
            admit(fd)
        }
    }

    private func admit(_ fd: Int32) {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            let error = IPCError.system("getpeereid", errno)
            log("rejected a client from pid \(peerPID(fd)): \(error.description)")
            Darwin.close(fd)
            return
        }
        guard uid == allowedUID else {
            log("rejected a client from pid \(peerPID(fd)) with uid \(uid)")
            Darwin.close(fd)
            return
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let id = nextID
        nextID += 1
        let io = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in Darwin.close(fd) }
        io.setLimit(lowWater: 1)
        connections[id] = Connection(io: io)
        io.read(offset: 0, length: .max, queue: queue) { [weak self] done, data, _ in
            self?.assumeIsolated { $0.received(data, done: done, from: id) }
        }
        queue.asyncAfter(deadline: .now() + Self.requestDeadline) { [weak self] in
            self?.assumeIsolated { $0.requestDeadlinePassed(for: id) }
        }
    }

    private func received(_ data: DispatchData?, done: Bool, from id: Int) {
        guard let connection = connections[id] else { return }
        if let data { connection.decoder.append(data) }
        if done { connection.clientClosed = true }
        proceed(id)
    }

    private func proceed(_ id: Int) {
        guard let connection = connections[id] else { return }
        switch connection.phase {
        case .request:
            do {
                if let body = try connection.decoder.next() { return handle(body, from: connection, id: id) }
            } catch {
                return reply(Reply(Response(error)), to: id)
            }
            if connection.clientClosed { disconnect(id) }
        case .answering:
            // A client that closes its end while its command runs still gets the response.
            break
        case .held(let hold):
            let args: [String]?
            do {
                guard let body = try connection.decoder.next() else {
                    guard connection.clientClosed else { return }
                    return release(id, hold, args: nil)
                }
                args = try Request(decoding: body).args
            } catch {
                args = nil
            }
            release(id, hold, args: args)
        }
    }

    private func handle(_ body: [UInt8], from connection: Connection, id: Int) {
        do {
            let request = try Request(decoding: body)
            connection.phase = .answering
            Task {
                let reply = await handler(request.args)
                self.reply(reply, to: id)
            }
        } catch {
            reply(Reply(Response(error)), to: id)
        }
    }

    /// A held response keeps the connection once written; a failed write, as to a client gone,
    /// releases the hold at once.
    private func reply(_ reply: Reply, to id: Int) {
        guard let connection = connections[id] else {
            if let hold = reply.hold { Task { @MainActor in _ = hold(nil) } }
            return
        }
        connection.phase = .answering
        var response = reply.response
        response.held = reply.hold != nil
        let data = frame(response.encoded).withUnsafeBytes { DispatchData(bytes: $0) }
        connection.io.write(offset: 0, data: data, queue: queue) { [weak self] done, _, error in
            guard done else { return }
            self?.assumeIsolated { server in
                guard let hold = reply.hold else { return server.disconnect(id) }
                guard error == 0, let connection = server.connections[id] else { return server.release(id, hold, args: nil) }
                connection.phase = .held(hold)
                server.proceed(id)
            }
        }
    }

    private func release(_ id: Int, _ hold: @escaping @MainActor @Sendable ([String]?) -> Response, args: [String]?) {
        connections[id]?.phase = .answering
        Task {
            let response = await hold(args)
            self.reply(Reply(response), to: id)
        }
    }

    private func requestDeadlinePassed(for id: Int) {
        if case .request? = connections[id]?.phase { disconnect(id) }
    }

    private func disconnect(_ id: Int) {
        // Stopping the channel cancels its pending writes; its cleanup handler closes the socket.
        connections.removeValue(forKey: id)?.io.close(flags: .stop)
    }

    private func shutDown() {
        guard !stopped else { return }
        stopped = true
        listener.cancel()
        for id in connections.keys { disconnect(id) }
        unlink(socketPath)
    }
}

private func secureDirectory(of socketPath: String) throws(IPCError) {
    guard let slash = socketPath.lastIndex(of: "/"), socketPath.first == "/" else {
        throw IPCError.unsafeDirectory("the socket path must be absolute: \(socketPath)")
    }
    let directory = slash == socketPath.startIndex ? "/" : String(socketPath[..<slash])
    var info = stat()
    guard stat(directory, &info) == 0 else { throw IPCError.system("stat \(directory)", errno) }
    guard info.st_mode & S_IFMT == S_IFDIR else {
        throw IPCError.unsafeDirectory("\(directory) is not a directory")
    }
    guard info.st_uid == getuid() else {
        throw IPCError.unsafeDirectory("\(directory) belongs to uid \(info.st_uid), not \(getuid())")
    }
    if info.st_mode & 0o077 != 0, chmod(directory, 0o700) != 0 {
        throw IPCError.system("chmod \(directory)", errno)
    }
}

private func listen(at path: String) throws(IPCError) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw IPCError.system("socket", errno) }
    do throws(IPCError) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw IPCError.system("fcntl", errno) }
        guard unlink(path) == 0 || errno == ENOENT else { throw IPCError.system("unlink \(path)", errno) }
        guard try withSocketAddress(path, { bind(fd, $0, $1) }) == 0 else {
            throw IPCError.system("bind \(path)", errno)
        }
        guard Darwin.listen(fd, SOMAXCONN) == 0 else { throw IPCError.system("listen", errno) }
        return fd
    } catch {
        Darwin.close(fd)
        throw error
    }
}

private func peerPID(_ fd: Int32) -> pid_t {
    var pid: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 ? pid : -1
}
