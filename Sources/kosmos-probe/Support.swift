// What several probes share.
import CKosmos
import Foundation
import KosmosSkyLight

/// The probe run again as a child process, with its standard input and output piped, for a
/// probe to act on another app's windows.
final class Child {
    let process = Process()
    private let input = Pipe(), output = Pipe()
    private var buffer = Data()

    init(_ arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        try! process.run()
    }

    var pid: pid_t { process.processIdentifier }

    /// The next line the child prints. The probe exits when the child exits first.
    func line() -> String {
        while !buffer.contains(UInt8(ascii: "\n")) {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { print("\(process.arguments![0]) exited"); exit(1) }
            buffer.append(chunk)
        }
        let end = buffer.firstIndex(of: UInt8(ascii: "\n"))!
        let text = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex...end)
        return text
    }

    /// The next line, as window ids.
    func readWindows() -> [UInt32] { line().split(whereSeparator: \.isWhitespace).compactMap { UInt32($0) } }

    func send(_ line: String) { input.fileHandleForWriting.write(Data((line + "\n").utf8)) }

    /// Calls `handle` with each line the child prints from now on, on the pipe's queue.
    func onLines(_ handle: @escaping @Sendable (Substring) -> Void) {
        String(decoding: buffer, as: UTF8.self).split(separator: "\n").forEach(handle)
        buffer = Data()
        output.fileHandleForReading.readabilityHandler = { file in
            let data = file.availableData
            guard !data.isEmpty else { file.readabilityHandler = nil; return }
            String(decoding: data, as: UTF8.self).split(separator: "\n").forEach(handle)
        }
    }

    /// Closes the child's standard input, which ends a child that reads it, and waits for it.
    func quit() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    func terminate() { process.terminate() }
}

extension WindowServerEvent {
    /// Calls `handle` on the thread that read each event, with its id, the window it names and
    /// its payload. SkyLight delivers events only inside a running AppKit event loop, as in
    /// Kosmos.
    static func register(_ ids: [UInt32], _ handle: @escaping @Sendable (UInt32, UInt32?, UnsafeRawBufferPointer) -> Void) {
        let context = Unmanaged.passRetained(EventHandler(handle)).toOpaque()   // lives for the process
        for id in ids {
            SLSRegisterConnectionNotifyProc(SLSMainConnectionID(), { id, data, length, context, _ in
                let payload = UnsafeRawBufferPointer(start: data, count: data == nil ? 0 : length)
                Unmanaged<EventHandler>.fromOpaque(context!).takeUnretainedValue()
                    .handle(id, WindowServerEvent(id: id, payload: payload)?.window, payload)
            }, id, context)
        }
    }
}

private final class EventHandler: Sendable {
    let handle: @Sendable (UInt32, UInt32?, UnsafeRawBufferPointer) -> Void

    init(_ handle: @escaping @Sendable (UInt32, UInt32?, UnsafeRawBufferPointer) -> Void) { self.handle = handle }
}

func inSpace(_ window: UInt32, _ space: UInt64) -> Bool {
    let windows = SkyLight.windows(in: space) ?? []
    return windows.contains(window)
}

func elapsed(_ start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

/// The wall clock time the unified log prints.
@MainActor let wallClock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

/// Milliseconds since boot, the same in every process.
func uptime() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e6 }
