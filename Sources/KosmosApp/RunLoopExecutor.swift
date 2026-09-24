import Foundation

/// A serial executor on a dedicated thread's run loop. An app worker's AX observer delivers
/// callbacks on the run loop it was added to, so running the actor there lets callbacks use
/// the actor's state directly, and a hung app blocks only its own thread.
final class RunLoopExecutor: SerialExecutor, @unchecked Sendable {
    let runLoop: CFRunLoop

    init(name: String) {
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var loop: CFRunLoop?
        let thread = Thread {
            loop = CFRunLoopGetCurrent()
            // A run loop with no sources returns at once; the port keeps this one alive.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            CFRunLoopRun()   // returns after stop()
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        runLoop = loop!
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            job.runSynchronously(on: executor)
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// Runs a block on the thread, in order with the actor's jobs and other blocks.
    func perform(_ block: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    func checkIsolated() {
        precondition(CFRunLoopGetCurrent() === runLoop, "not on this executor's thread")
    }

    func stop() {
        CFRunLoopStop(runLoop)
    }
}
