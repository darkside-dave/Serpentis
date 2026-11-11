import AppKit
import ApplicationServices
import IOKit.hid

private final class ScrollTapSession: InputTapSession {
    private let origin: EventOrigin
    private let filter: ScrollEventFilter
    private let onError: (Error) -> Void
    private let configurationLock = NSLock()
    private var configuration: ScrollConfiguration
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var failed = false

    init(configuration: ScrollConfiguration, device: IOHIDDevice, onError: @escaping (Error) -> Void) throws {
        do {
            origin = try EventOrigin()
            filter = ScrollEventFilter(targetSenderIDs: try mouseSenderIDs(device))
        } catch { throw ScrollError.eventIdentity }
        self.configuration = configuration
        self.onError = onError
    }

    func update(_ configuration: ScrollConfiguration) {
        configurationLock.lock()
        self.configuration = configuration
        configurationLock.unlock()
    }

    private func snapshot() -> ScrollConfiguration {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        return configuration
    }

    func start() throws {
        guard CGPreflightListenEventAccess(), AXIsProcessTrusted() else { throw ScrollError.permission }
        let context = Unmanaged.passUnretained(self).toOpaque()
        // Session events have already passed the system's device/scrolling transformations.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
            callback: { _, type, event, context in
                guard let context = context else { return Unmanaged.passUnretained(event) }
                let session = Unmanaged<ScrollTapSession>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    session.fail(ScrollError.interrupted)
                } else if !session.failed {
                    let configuration = session.snapshot()
                    if configuration.shouldInvert {
                        do {
                            try session.filter.process(event, senderID: session.origin.senderID(event),
                                                       configuration: configuration)
                        } catch { session.fail(error) }
                    }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: context
        ) else { throw ScrollError.interception }
        self.tap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw ScrollError.interception
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func fail(_ error: Error) {
        guard !failed else { return }
        failed = true
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        onError(error)
    }

    func stop() {
        if let tap = tap { CFMachPortInvalidate(tap) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        tap = nil; source = nil
    }
}

final class ScrollEventTap: ScrollTapDriving {
    private let queue = DispatchQueue(label: "serpentis.scroll.configuration")
    private let worker = EventTapThread()
    private var session: ScrollTapSession?
    private var device: IOHIDDevice?
    private var token: UUID?
    private var onError: ((Error) -> Void)?

    func configure(_ configuration: ScrollConfiguration, mouse: RazerMouse,
                   onError: @escaping (Error) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            self.onError = onError
            do {
                guard let device = mouse.device else { throw ScrollError.eventIdentity }
                if let current = self.device, CFEqual(current, device), let session = self.session {
                    session.update(configuration)
                } else {
                    self.stopOnQueue()
                    self.onError = onError
                    let token = UUID()
                    self.token = token
                    let session = try ScrollTapSession(configuration: configuration, device: device) { [weak self] error in
                        guard let self = self else { return }
                        self.queue.async {
                            guard self.token == token else { return }
                            let handler = self.onError
                            self.stopOnQueue()
                            DispatchQueue.main.async { handler?(error) }
                        }
                    }
                    try self.worker.start(name: "Serpentis vertical scrolling") { session }
                    self.session = session
                    self.device = device
                }
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                self.stopOnQueue()
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func stop(wait: Bool) {
        if wait { queue.sync { stopOnQueue() } }
        else { queue.async { self.stopOnQueue() } }
    }

    private func stopOnQueue() {
        token = nil
        worker.stop()
        session = nil; device = nil; onError = nil
    }
}
