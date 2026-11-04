import Foundation
import Combine
import Darwin
import IOKit.hid

struct ReportRateWindow {
    private var first: Double?
    private var last: Double?
    private var count = 0
    private(set) var total = 0
    private(set) var best: Double?

    mutating func record(_ time: Double) {
        guard time.isFinite, time >= 0, last.map({ time > $0 }) ?? true else { return }
        total += 1
        if let previous = last, time - previous > 0.05 { first = nil; count = 0 }
        last = time
        guard let start = first else { first = time; count = 1; return }
        count += 1
        let span = time - start
        if span >= 0.25 {
            let rate = Double(count - 1) / span
            best = max(best ?? 0, rate)
            first = time; count = 1
        }
    }
}

// Input reports are counted on a separate queue only during an explicit five-second check.
private final class ReportRateSession {
    private let queue = DispatchQueue(label: "serpentis.report-rate", qos: .userInitiated)
    private var manager: IOHIDManager?
    private var timer: DispatchSourceTimer?
    private var window = ReportRateWindow()
    private var finished = false
    private var secondsPerTick = 0.0
    private let progress: (Double?, Int) -> Void
    private let completion: (Double?, Int, String?) -> Void

    init(progress: @escaping (Double?, Int) -> Void, completion: @escaping (Double?, Int, String?) -> Void) {
        self.progress = progress; self.completion = completion
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
    func start(product: Int, location: Int) {
        queue.async { self.open(product: product, location: location) }
    }
    private func open(product: Int, location: Int) {
        guard !finished else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        self.manager = manager
        var match = [kIOHIDVendorIDKey: kRazerVID, kIOHIDProductIDKey: product,
                     kIOHIDPrimaryUsagePageKey: 1, kIOHIDPrimaryUsageKey: 2]
        if location != 0 { match[kIOHIDLocationIDKey] = location }
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let context = Unmanaged.passRetained(self).toOpaque()
        IOHIDManagerRegisterInputReportWithTimeStampCallback(manager, { context, result, _, type, _, _, length, timestamp in
            guard let context = context, result == kIOReturnSuccess, type == kIOHIDReportTypeInput, length > 0 else { return }
            let session = Unmanaged<ReportRateSession>.fromOpaque(context).takeUnretainedValue()
            if !session.finished { session.window.record(Double(timestamp) * session.secondsPerTick) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context = context else { return }
            Unmanaged<ReportRateSession>.fromOpaque(context).takeUnretainedValue().end("Mouse disconnected during the check.")
        }, context)
        IOHIDManagerSetDispatchQueue(manager, queue)
        IOHIDManagerSetCancelHandler(manager) {
            let session = Unmanaged<ReportRateSession>.fromOpaque(context).takeRetainedValue()
            IOHIDManagerClose(manager, 0)
            session.manager = nil
        }
        let result = IOHIDManagerOpen(manager, 0)
        IOHIDManagerActivate(manager)
        guard result == kIOReturnSuccess else { end("macOS blocked the rate check. Check Input Monitoring for Serpentis."); return }
        guard ((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []).count == 1 else {
            end("A single mouse input interface was not available. Reconnect the mouse and retry."); return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let deadline = DispatchTime.now() + 5
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if DispatchTime.now() >= deadline { self.end(nil) }
            else { self.progress(self.window.best, self.window.total) }
        }
        self.timer = timer; timer.resume()
    }
    func stop() { queue.async { self.end(nil) } }
    private func end(_ message: String?) {
        guard !finished else { return }
        finished = true
        timer?.cancel(); timer = nil
        if let manager = manager { IOHIDManagerCancel(manager) }
        completion(window.best, window.total, message)
    }
}

final class PollingMonitor: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var observedRate: Double?
    @Published private(set) var message = "Move the mouse quickly in circles during the five-second check."
    private var session: ReportRateSession?
    private var generation = 0

    func start(mouse: RazerMouse?) {
        stop()
        guard let mouse = mouse,
              NagaDockRegistry.supports(vendor: kRazerVID, product: mouse.productID, location: mouse.locationID) else {
            message = "Connect an accessible Naga before measuring."; return
        }
        generation += 1
        let generation = self.generation
        observedRate = nil; running = true
        message = "Move the mouse continuously and quickly for five seconds."
        let session = ReportRateSession(progress: { [weak self] rate, count in
            DispatchQueue.main.async {
                guard let self = self, self.generation == generation else { return }
                self.observedRate = rate
                self.message = count == 0 ? "Waiting for mouse reports. Keep moving the mouse." : "Measuring… keep the mouse moving."
            }
        }, completion: { [weak self] rate, count, error in
            DispatchQueue.main.async {
                guard let self = self, self.generation == generation else { return }
                self.running = false; self.observedRate = rate; self.session = nil
                self.message = error ?? (rate == nil ? "Not enough continuous input. Move the mouse faster and try again." : "Highest sustained rate received by macOS during this check (\(count) reports).")
            }
        })
        self.session = session
        session.start(product: mouse.productID, location: mouse.locationID)
    }
    func stop() {
        generation += 1
        session?.stop(); session = nil
        running = false; observedRate = nil
        message = "Move the mouse quickly in circles during the five-second check."
    }
}
