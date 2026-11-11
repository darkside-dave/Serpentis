import Foundation

protocol InputTapSession: AnyObject {
    func start() throws
    func stop()
}

// The caller serializes start/stop; sessions keep all callback-owned state on this run loop.
final class EventTapThread {
    private var loop: CFRunLoop?
    private var thread: Thread?
    private var stopped: DispatchSemaphore?

    func start(name: String, makeSession: @escaping () throws -> InputTapSession) throws {
        stop()
        let ready = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        var result: Result<CFRunLoop, Error>?
        let thread = Thread {
            do {
                let session = try makeSession()
                do {
                    try session.start()
                    result = .success(CFRunLoopGetCurrent())
                    ready.signal()
                    CFRunLoopRun()
                    session.stop()
                } catch {
                    session.stop()
                    throw error
                }
            } catch {
                result = .failure(error)
                ready.signal()
            }
            stopped.signal()
        }
        thread.name = name
        thread.start()
        ready.wait()
        guard let result = result else { throw ModifierError.interception }
        loop = try result.get()
        self.thread = thread
        self.stopped = stopped
    }

    func stop() {
        if let loop = loop {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop) }
            CFRunLoopWakeUp(loop)
            stopped?.wait()
        }
        loop = nil; thread = nil; stopped = nil
    }
}
