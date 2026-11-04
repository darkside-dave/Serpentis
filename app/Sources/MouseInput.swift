// macOS input preferences, scoped to supported Naga services. No firmware writes.
import AppKit
import Combine
import Darwin
import IOKit.hidsystem

struct MouseInputService {
    let id: UInt64
    let vendor: Int
    let product: Int
    let pointer: Bool
    let acceleration: Int?
    var linearScaling: Int = 0
    var resolution: Int = 400 * 65536

    var location: Int = 0
    var isNaga: Bool { NagaDockRegistry.supports(vendor: vendor, product: product, location: location) }
    var pointerValues: [String: Int]? {
        guard let acceleration = acceleration else { return nil }
        return [PointerSensitivity.accelerationKey: acceleration, PointerSensitivity.linearKey: linearScaling,
                PointerSensitivity.resolutionKey: resolution]
    }
}

final class NagaInputSystem {
    private let client: IOHIDEventSystemClient
    let supportsPointerTuning: Bool

    init() {
        // The limited public client only exposes a subset of service properties. The full
        // client is needed for per-device linear tracking and resolution; resolve it safely.
        typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<IOHIDEventSystemClient>?
        let handle = dlopen(nil, RTLD_LAZY)
        defer { if let handle = handle { dlclose(handle) } }
        if let handle = handle, let address = dlsym(handle, "IOHIDEventSystemClientCreate"),
           let fullClient = unsafeBitCast(address, to: CreateClient.self)(kCFAllocatorDefault)?.takeRetainedValue() {
            client = fullClient; supportsPointerTuning = true
        } else {
            client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
            supportsPointerTuning = false
        }
    }

    private func clients() -> [IOHIDServiceClient] {
        (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
    }

    func services() -> [MouseInputService] {
        clients().compactMap { service in
            func number(_ key: String) -> Int? {
                (IOHIDServiceClientCopyProperty(service, key as CFString) as? NSNumber)?.intValue
            }
            guard number(kIOHIDVendorIDKey) == kRazerVID,
                  let product = number(kIOHIDProductIDKey),
                  NagaDockRegistry.supports(vendor: kRazerVID, product: product, location: number(kIOHIDLocationIDKey) ?? 0),
                  let id = IOHIDServiceClientGetRegistryID(service) as? NSNumber else { return nil }
            let type = IOHIDServiceClientCopyProperty(service, "HIDPointerAccelerationType" as CFString) as? String
            let isPointer = IOHIDServiceClientConformsTo(service, 1, 2) != 0 || IOHIDServiceClientConformsTo(service, 1, 1) != 0
            return MouseInputService(id: id.uint64Value, vendor: kRazerVID, product: product,
                                     pointer: isPointer && type == "HIDMouseAcceleration", acceleration: number("HIDMouseAcceleration"),
                                     linearScaling: number(PointerSensitivity.linearKey) ?? 0,
                                     resolution: number(PointerSensitivity.resolutionKey) ?? 400 * 65536, location: number(kIOHIDLocationIDKey) ?? 0)
        }
    }

    func setAcceleration(_ id: UInt64, _ value: Int) -> Bool {
        setPointerProperty(id, PointerSensitivity.accelerationKey, value)
    }

    func setPointerProperty(_ id: UInt64, _ name: String, _ value: Int) -> Bool {
        guard PointerSensitivity.keys.contains(name) else { return false }
        guard let service = clients().first(where: {
            (IOHIDServiceClientGetRegistryID($0) as? NSNumber)?.uint64Value == id
        }), (IOHIDServiceClientCopyProperty(service, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue == kRazerVID,
              let product = IOHIDServiceClientCopyProperty(service, kIOHIDProductIDKey as CFString) as? NSNumber,
              NagaDockRegistry.supports(vendor: kRazerVID, product: product.intValue,
                  location: (IOHIDServiceClientCopyProperty(service, kIOHIDLocationIDKey as CFString) as? NSNumber)?.intValue ?? 0) else { return false }
        let key = name as CFString
        guard IOHIDServiceClientSetProperty(service, key, NSNumber(value: value)) else { return false }
        return (IOHIDServiceClientCopyProperty(service, key) as? NSNumber)?.intValue == value
    }
}

enum PointerSensitivity {
    static let accelerationKey = "HIDMouseAcceleration"
    static let linearKey = "HIDUseLinearScalingMouseAcceleration"
    static let resolutionKey = "HIDPointerResolution"
    // Acceleration is last so the complete configuration is present when the filter rebuilds.
    static let keys = [linearKey, resolutionKey, accelerationKey]
    static func clamp(_ value: Int) -> Int { max(0, min(2000, value)) }
    static func gain(_ value: Int) -> Double { max(0.01, Double(clamp(value)) / 1000) }
    private static func fixed(_ value: Double) -> Int { Int(max(1, min(Double(Int32.max), (value * 65536).rounded()))) }

    static func targets(sensitivity: Int, disableAcceleration: Bool, original: [String: Int]) -> [String: Int] {
        let gain = gain(sensitivity)
        let acceleration = original[accelerationKey] ?? 0
        let linear = original[linearKey] ?? 0
        let resolution = original[resolutionKey] ?? 400 * 65536
        if disableAcceleration {
            // Modern macOS linear tracking applies HIDMouseAcceleration as constant gain.
            // The old negative-acceleration bypass ignores sensitivity multipliers entirely.
            return [linearKey: 1, resolutionKey: resolution, accelerationKey: fixed(gain)]
        }
        if acceleration < 0 || linear != 0 {
            let baselineGain = acceleration < 0 ? 1 : max(0.1, Double(acceleration) / 65536)
            return [linearKey: 1, resolutionKey: resolution, accelerationKey: fixed(baselineGain * gain)]
        }
        // macOS uses inverse device resolution for sensitivity when retaining its acceleration curve.
        let adjustedResolution = Int(max(1, min(Double(Int32.max), (Double(resolution == 0 ? 400 * 65536 : resolution) / gain).rounded())))
        return [linearKey: linear, resolutionKey: adjustedResolution, accelerationKey: acceleration]
    }
}

struct PointerPropertyRecord: Codable {
    let original: Int
    var applied: Int?
    var attempted: Int?
}

/// Each property records its own ownership, so partially accepted writes remain reversible.
final class PointerTuningOverride {
    typealias Journal = [String: [String: PointerPropertyRecord]]
    private(set) var journal: Journal
    private let save: (Journal) -> Void
    init(journal: Journal = [:], save: @escaping (Journal) -> Void = { _ in }) {
        self.journal = journal; self.save = save
    }

    @discardableResult
    func sync(sensitivity: Int, disableAcceleration: Bool, services: [MouseInputService],
              write: (UInt64, String, Int) -> Bool) -> Int {
        let active = disableAcceleration || PointerSensitivity.clamp(sensitivity) != 1000
        var failures = 0
        for service in services where service.isNaga && service.pointer {
            let id = String(service.id)
            guard let current = service.pointerValues else {
                if active || journal[id] != nil { failures += 1 }
                continue
            }
            if active {
                var records = journal[id] ?? [:]
                var addedBaseline = false
                for key in PointerSensitivity.keys where records[key] == nil {
                    records[key] = PointerPropertyRecord(original: current[key]!)
                    addedBaseline = true
                }
                if addedBaseline { journal[id] = records; save(journal) }
                let targets = PointerSensitivity.targets(sensitivity: sensitivity, disableAcceleration: disableAcceleration,
                                                         original: records.mapValues { $0.original })
                var changedParameter = false
                for key in PointerSensitivity.keys {
                    // Changing resolution alone does not rebuild macOS's cached acceleration filter.
                    guard current[key] != targets[key] || (key == PointerSensitivity.accelerationKey && changedParameter) else { continue }
                    let value = targets[key]!
                    records[key]!.attempted = value
                    journal[id] = records; save(journal) // Save recovery data before touching a property.
                    if write(service.id, key, value) {
                        records[key]!.applied = value; records[key]!.attempted = nil
                        changedParameter = true
                    } else { failures += 1 }
                    journal[id] = records; save(journal)
                }
            } else if var records = journal[id] {
                var restoredParameter = false
                for key in PointerSensitivity.keys {
                    guard let record = records[key] else { continue }
                    let value = current[key]!
                    let forceRefresh = key == PointerSensitivity.accelerationKey && restoredParameter && value == record.original
                    if !forceRefresh && (value == record.original || (value != record.applied && value != record.attempted)) {
                        records[key] = nil
                    } else if write(service.id, key, record.original) {
                        records[key] = nil; restoredParameter = true
                    } else { failures += 1 }
                    journal[id] = records.isEmpty ? nil : records; save(journal)
                }
            }
        }
        return failures
    }
}

/// Journal the exact prior values before applying an override, including across app crashes.
/// Registry IDs are meaningful within one boot only; never restore a previous boot's journal.
final class AccelerationOverride {
    static let disabledValue = -65536 // -1.0 in IOHID's 16.16 fixed-point representation.
    private(set) var originals: [String: Int]
    private let save: ([String: Int]) -> Void

    init(originals: [String: Int] = [:], save: @escaping ([String: Int]) -> Void = { _ in }) {
        self.originals = originals
        self.save = save
    }

    /// Returns the number of live pointer services that could not apply/restore the setting.
    @discardableResult
    func sync(enabled: Bool, services: [MouseInputService], write: (UInt64, Int) -> Bool) -> Int {
        var failed = 0
        for service in services where service.isNaga && service.pointer {
            let key = String(service.id)
            guard let current = service.acceleration else {
                if enabled || originals[key] != nil { failed += 1 }
                continue
            }
            if enabled {
                if originals[key] == nil { originals[key] = current; save(originals) }
                if current != Self.disabledValue && !write(service.id, Self.disabledValue) { failed += 1 }
            } else if let original = originals[key] {
                // Leave a later change made by macOS or another utility alone.
                if current != Self.disabledValue || current == original || write(service.id, original) {
                    originals[key] = nil; save(originals)
                } else { failed += 1 }
            }
        }
        return failed
    }
}

/// Optional system SPI: Quartz's public scroll event does not expose the originating device.
/// Resolve these symbols at runtime, and pass all events through if unavailable/unidentified.
final class ScrollDeviceBridge {
    typealias CopyEvent = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    typealias SenderID = @convention(c) (CFTypeRef) -> UInt64
    typealias GetFloat = @convention(c) (CFTypeRef, UInt32) -> Double
    typealias SetFloat = @convention(c) (CFTypeRef, UInt32, Double) -> Void
    private let copyEvent: CopyEvent?
    private let senderID: SenderID?
    private let getFloat: GetFloat?
    private let setFloat: SetFloat?
    var available: Bool { copyEvent != nil && senderID != nil && getFloat != nil && setFloat != nil }

    init() {
        let handle = dlopen(nil, RTLD_LAZY)
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let handle = handle, let address = dlsym(handle, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        copyEvent = symbol("CGEventCopyIOHIDEvent", CopyEvent.self)
        senderID = symbol("IOHIDEventGetSenderID", SenderID.self)
        getFloat = symbol("IOHIDEventGetFloatValue", GetFloat.self)
        setFloat = symbol("IOHIDEventSetFloatValue", SetFloat.self)
        if let handle = handle { dlclose(handle) }
    }

    @discardableResult
    func reverse(_ event: CGEvent, enabled: Bool, nagaIDs: Set<UInt64>) -> Bool {
        guard enabled, available, let hid = copyEvent?(event)?.takeRetainedValue(),
              let sender = senderID?(hid), sender != 0, nagaIDs.contains(sender) else { return false }
        ScrollTransform.reverse(event)
        // Some apps consume the embedded HID scroll deltas rather than Quartz's deltas.
        for field: UInt32 in [0x60000, 0x60001, 0x60002] {
            if let value = getFloat?(hid, field) { setFloat?(hid, field, -value) }
        }
        return true
    }
}

enum ScrollTransform {
    static func reverse(_ event: CGEvent) {
        let axes: [(CGEventField, CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1),
            (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2),
            (.scrollWheelEventDeltaAxis3, .scrollWheelEventFixedPtDeltaAxis3, .scrollWheelEventPointDeltaAxis3)
        ]
        // Read all representations first: setting line deltas also changes the other fields.
        let values = axes.map { (event.getIntegerValueField($0.0), event.getDoubleValueField($0.1), event.getIntegerValueField($0.2)) }
        for (index, fields) in axes.enumerated() {
            let value = values[index]
            event.setIntegerValueField(fields.0, value: value.0 == .min ? .max : -value.0)
            event.setDoubleValueField(fields.1, value: -value.1)
            event.setIntegerValueField(fields.2, value: value.2 == .min ? .max : -value.2)
        }
    }
}

final class MouseInputController: ObservableObject {
    @Published private(set) var disableAcceleration: Bool
    @Published private(set) var invertScrolling: Bool
    @Published private(set) var sensitivity: Int
    @Published private(set) var accelerationStatus = ""
    @Published private(set) var scrollingStatus = ""
    @Published private(set) var needsAccessibility = false
    @Published private(set) var canIdentifyScrollDevices: Bool
    let canAdjustSensitivity: Bool
    private let defaults: UserDefaults
    private let system = NagaInputSystem()
    private let bridge = ScrollDeviceBridge()
    private let acceleration: AccelerationOverride
    private let pointerTuning: PointerTuningOverride
    private var pendingSensitivity: DispatchWorkItem?
    private var nagaIDs: Set<UInt64> = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var started = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        disableAcceleration = defaults.bool(forKey: "disableNagaAcceleration")
        invertScrolling = defaults.bool(forKey: "invertNagaScrolling")
        sensitivity = PointerSensitivity.clamp((defaults.object(forKey: "nagaPointerSensitivity") as? NSNumber)?.intValue ?? 1000)
        canIdentifyScrollDevices = bridge.available
        canAdjustSensitivity = system.supportsPointerTuning
        var size = 0
        sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(1, size))
        let foundBoot = sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0
        let boot = foundBoot ? String(cString: buffer) : UUID().uuidString
        let journalKey = "nagaAccelerationRestoreJournal"
        let stored = defaults.dictionary(forKey: journalKey)
        let originals = stored?["bootSession"] as? String == boot ? (stored?["originals"] as? [String: Int] ?? [:]) : [:]
        acceleration = AccelerationOverride(originals: originals) { values in
            defaults.set(["bootSession": boot, "originals": values], forKey: journalKey)
        }
        let tuningKey = "nagaPointerTuningJournal"
        let tuningData = defaults.dictionary(forKey: tuningKey)
        let restoredJournal: PointerTuningOverride.Journal
        if tuningData?["bootSession"] as? String == boot, let data = tuningData?["records"] as? Data {
            restoredJournal = (try? JSONDecoder().decode(PointerTuningOverride.Journal.self, from: data)) ?? [:]
        } else { restoredJournal = [:] }
        pointerTuning = PointerTuningOverride(journal: restoredJournal) { journal in
            if let data = try? JSONEncoder().encode(journal) { defaults.set(["bootSession": boot, "records": data], forKey: tuningKey) }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        refresh()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func woke() { refresh() }

    func devicesChanged() { if started { refresh() } }

    private func updateTimer() {
        let interval = InputMonitorPolicy.interval(disableAcceleration: disableAcceleration, sensitivity: sensitivity,
            invertScrolling: invertScrolling, hasRecovery: !acceleration.originals.isEmpty || !pointerTuning.journal.isEmpty)
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate(); timer = nil
        guard started, let interval = interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.75
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func setDisableAcceleration(_ enabled: Bool) {
        guard disableAcceleration != enabled else { return }
        disableAcceleration = enabled
        defaults.set(enabled, forKey: "disableNagaAcceleration")
        refresh()
    }

    func setSensitivity(_ value: Int) {
        guard sensitivity != PointerSensitivity.clamp(value) else { return }
        sensitivity = PointerSensitivity.clamp(value)
        defaults.set(sensitivity, forKey: "nagaPointerSensitivity")
        pendingSensitivity?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingSensitivity = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func setInvertScrolling(_ enabled: Bool) {
        guard invertScrolling != enabled else { return }
        invertScrolling = enabled
        defaults.set(enabled, forKey: "invertNagaScrolling")
        if enabled && !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        refresh()
    }

    func refresh() {
        let services = system.services()
        nagaIDs = Set(services.filter { $0.isNaga }.map { $0.id })
        // Migrate a previous version's negative-acceleration override before taking new baselines.
        let hadLegacyOverrides = !acceleration.originals.isEmpty
        let legacyFailures = acceleration.sync(enabled: !canAdjustSensitivity && disableAcceleration, services: services, write: system.setAcceleration)
        let freshServices = hadLegacyOverrides ? system.services() : services
        let failures = legacyFailures > 0 || !canAdjustSensitivity ? legacyFailures : pointerTuning.sync(sensitivity: sensitivity, disableAcceleration: disableAcceleration,
                                                                              services: freshServices, write: system.setPointerProperty)
        // If macOS accepts only part of a configuration, undo it immediately instead of
        // leaving a changed acceleration curve behind while reporting a failure.
        if failures > 0 && canAdjustSensitivity {
            pointerTuning.sync(sensitivity: 1000, disableAcceleration: false, services: system.services(), write: system.setPointerProperty)
        }
        let pointers = services.filter { $0.isNaga && $0.pointer }
        let nextAccelerationStatus: String
        if failures > 0 {
            nextAccelerationStatus = "macOS couldn't apply or restore pointer settings. Quit other mouse utilities, then retry."
        } else if !canAdjustSensitivity {
            nextAccelerationStatus = "Custom sensitivity is unavailable on this macOS version. \(disableAcceleration ? "Acceleration is disabled for the Naga." : "Using your existing pointer settings.")"
        } else if !disableAcceleration && sensitivity == 1000 {
            nextAccelerationStatus = "Using your existing macOS pointer settings."
        } else if pointers.isEmpty {
            nextAccelerationStatus = "Waiting for an accessible Naga pointer. Reconnect the mouse if needed."
        } else {
            nextAccelerationStatus = disableAcceleration ? "Acceleration disabled for the Naga. Sensitivity controls its constant pointer speed." : "Custom sensitivity applied to the Naga with your existing acceleration setting."
        }

        if accelerationStatus != nextAccelerationStatus { accelerationStatus = nextAccelerationStatus }
        let nextNeedsAccessibility = invertScrolling && !AXIsProcessTrusted()
        if needsAccessibility != nextNeedsAccessibility { needsAccessibility = nextNeedsAccessibility }
        let nextScrollingStatus: String
        if !invertScrolling {
            stopTap()
            nextScrollingStatus = "Using your existing macOS scroll direction."
        } else if !bridge.available {
            stopTap()
            nextScrollingStatus = "Device identification is unavailable on this macOS version. Scrolling is unchanged."
        } else if needsAccessibility {
            stopTap()
            nextScrollingStatus = "Allow Serpentis in Accessibility to invert scrolling."
        } else if nagaIDs.isEmpty {
            stopTap()
            nextScrollingStatus = "Waiting for your Naga."
        } else {
            startTap()
            nextScrollingStatus = tap == nil ? "Couldn't start scroll control. Check Accessibility, then reopen Serpentis." : "Inverting the Naga's wheel and tilt scrolling."
        }
        if scrollingStatus != nextScrollingStatus { scrollingStatus = nextScrollingStatus }
        updateTimer()
    }

    private func startTap() {
        guard tap == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                               eventsOfInterest: CGEventMask(1) << CGEventType.scrollWheel.rawValue,
                               callback: { _, type, event, context in
            guard let context = context else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<MouseInputController>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = controller.tap, controller.invertScrolling { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if type == .scrollWheel {
                controller.bridge.reverse(event, enabled: controller.invertScrolling, nagaIDs: controller.nagaIDs)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: context)
        guard let tap = tap else { return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { stopTap(); return }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopTap() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil
    }

    func stop() {
        pendingSensitivity?.cancel(); pendingSensitivity = nil
        timer?.invalidate(); timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        stopTap()
        pointerTuning.sync(sensitivity: 1000, disableAcceleration: false, services: system.services(), write: system.setPointerProperty)
        acceleration.sync(enabled: false, services: system.services(), write: system.setAcceleration)
        started = false
    }

    func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
}


enum InputMonitorPolicy {
    static func interval(disableAcceleration: Bool, sensitivity: Int, invertScrolling: Bool, hasRecovery: Bool) -> TimeInterval? {
        disableAcceleration || sensitivity != 1000 || invertScrolling || hasRecovery ? 3 : nil
    }
}
