import AppKit
import ApplicationServices
import Darwin
import IOKit
import IOKit.hid

struct EventOrigin {
    typealias CopyEvent = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    typealias Sender = @convention(c) (CFTypeRef) -> UInt64
    let copyEvent: CopyEvent
    let sender: Sender

    init() throws {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let copy = dlsym(handle, "CGEventCopyIOHIDEvent"),
              let sender = dlsym(handle, "IOHIDEventGetSenderID") else {
            throw ModifierError.identification
        }
        defer { dlclose(handle) }
        copyEvent = unsafeBitCast(copy, to: CopyEvent.self)
        self.sender = unsafeBitCast(sender, to: Sender.self)
    }

    func senderID(_ event: CGEvent) -> UInt64? {
        guard let hid = copyEvent(event)?.takeRetainedValue() else { return nil }
        let id = sender(hid)
        return id == 0 ? nil : id
    }
}

private func registryID(_ entry: io_registry_entry_t) -> UInt64? {
    var id: UInt64 = 0
    guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else { return nil }
    return id
}

func mouseSenderIDs(_ device: IOHIDDevice) throws -> Set<UInt64> {
    var entry = IOHIDDeviceGetService(device)
    guard entry != 0 else { throw ModifierError.identification }
    IOObjectRetain(entry)
    defer { IOObjectRelease(entry) }
    // The feature-report and keyboard interfaces are siblings of the same USB device.
    while IOObjectConformsTo(entry, "IOUSBHostDevice") == 0 {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else {
            throw ModifierError.identification
        }
        IOObjectRelease(entry)
        entry = parent
    }
    guard let rootID = registryID(entry) else { throw ModifierError.identification }
    var ids: Set<UInt64> = [rootID]
    var iterator: io_iterator_t = 0
    guard IORegistryEntryCreateIterator(entry, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
        throw ModifierError.identification
    }
    defer { IOObjectRelease(iterator) }
    while case let child = IOIteratorNext(iterator), child != 0 {
        if let id = registryID(child) { ids.insert(id) }
        IOObjectRelease(child)
    }
    return ids
}

private final class ModifierTapSession: InputTapSession {
    let filter: PhysicalModifierFilter
    let targetIDs: Set<UInt64>
    let origin: EventOrigin
    let onError: (Error) -> Void
    var manager: IOHIDManager?
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    var failed = false
    var keyboardIDs: [IOHIDDevice: UInt64] = [:]

    init(configuration: ModifierConfiguration, device: IOHIDDevice, onError: @escaping (Error) -> Void) throws {
        let targetIDs = try mouseSenderIDs(device)
        self.targetIDs = targetIDs
        filter = PhysicalModifierFilter(configuration: configuration, targetSenderIDs: targetIDs)
        origin = try EventOrigin()
        self.onError = onError
    }

    func start() throws {
        guard CGPreflightListenEventAccess(), AXIsProcessTrusted() else { throw ModifierError.permission }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6,
        ] as CFDictionary)
        IOHIDManagerSetInputValueMatchingMultiple(manager, PhysicalModifier.allCases.map {
            [kIOHIDElementUsagePageKey: 7, kIOHIDElementUsageKey: Int($0.rawValue)]
        } as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard let context = context else { return }
            let session = Unmanaged<ModifierTapSession>.fromOpaque(context).takeUnretainedValue()
            guard result == kIOReturnSuccess else { session.fail(ModifierError.keyboardState); return }
            let element = IOHIDValueGetElement(value)
            let device = IOHIDElementGetDevice(element)
            guard let modifier = PhysicalModifier(rawValue: IOHIDElementGetUsage(element)),
                  let id = session.keyboardIDs[device] else { return }
            session.filter.setModifier(modifier, down: IOHIDValueGetIntegerValue(value) != 0, keyboard: id)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context = context else { return }
            let session = Unmanaged<ModifierTapSession>.fromOpaque(context).takeUnretainedValue()
            if let id = session.keyboardIDs.removeValue(forKey: device) { session.filter.removeKeyboard(id) }
        }, context)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard let context = context else { return }
            let session = Unmanaged<ModifierTapSession>.fromOpaque(context).takeUnretainedValue()
            guard result == kIOReturnSuccess else { session.fail(ModifierError.keyboardState); return }
            do { try session.snapshotKeyboard(device) }
            catch { session.fail(error) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess else { throw ModifierError.keyboardState }
        let keyboards = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        for keyboard in keyboards { try snapshotKeyboard(keyboard) }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue | 1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context = context else { return Unmanaged.passUnretained(event) }
                let session = Unmanaged<ModifierTapSession>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    session.fail(ModifierError.interrupted)
                    return Unmanaged.passUnretained(event)
                }
                guard !session.failed else { return Unmanaged.passUnretained(event) }
                let synthetic = event.getIntegerValueField(.eventSourceUnixProcessID) != 0
                do { try session.filter.process(event, type: type, senderID: synthetic ? nil : session.origin.senderID(event)) }
                catch { session.fail(error) }
                return Unmanaged.passUnretained(event)
            }, userInfo: context
        ) else { throw ModifierError.interception }
        self.tap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw ModifierError.interception
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func snapshotKeyboard(_ keyboard: IOHIDDevice) throws {
        guard let id = registryID(IOHIDDeviceGetService(keyboard)) else { throw ModifierError.keyboardState }
        if targetIDs.contains(id) { return }
        let vendor = IOHIDDeviceGetProperty(keyboard, kIOHIDVendorIDKey as CFString) as? Int
        let product = IOHIDDeviceGetProperty(keyboard, kIOHIDProductIDKey as CFString) as? Int
        if vendor == kRazerVID, let product = product, kNagaPIDs[product] != nil { return }
        guard let elements = IOHIDDeviceCopyMatchingElements(keyboard, [
            kIOHIDElementUsagePageKey: 7,
        ] as CFDictionary, 0) as? [IOHIDElement] else { throw ModifierError.keyboardState }
        keyboardIDs[keyboard] = id
        for element in elements {
            let type = IOHIDElementGetType(element)
            guard type == kIOHIDElementTypeInput_Button || type == kIOHIDElementTypeInput_ScanCodes || type == kIOHIDElementTypeInput_Misc,
                  let modifier = PhysicalModifier(rawValue: IOHIDElementGetUsage(element)) else { continue }
            let down = try withUnsafeTemporaryAllocation(of: Unmanaged<IOHIDValue>.self, capacity: 1) { values in
                guard let pointer = values.baseAddress,
                      IOHIDDeviceGetValue(keyboard, element, pointer) == kIOReturnSuccess else {
                    throw ModifierError.keyboardState
                }
                return IOHIDValueGetIntegerValue(pointer.pointee.takeUnretainedValue()) != 0
            }
            filter.setModifier(modifier, down: down, keyboard: id)
        }
    }

    func fail(_ error: Error) {
        guard !failed else { return }
        failed = true
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        onError(error)
    }

    func stop() {
        filter.disable()
        if let tap = tap { CFMachPortInvalidate(tap) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        if let manager = manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, 0)
        }
        tap = nil; source = nil; manager = nil
        keyboardIDs.removeAll()
    }
}

// Called only on the model's I/O queue. The session owns all input state on its run loop.
final class ModifierEventTap {
    private let worker = EventTapThread()
    private var configuration: ModifierConfiguration?
    private var device: IOHIDDevice?

    func configure(_ configuration: ModifierConfiguration, device: IOHIDDevice, onError: @escaping (Error) -> Void) throws {
        if self.configuration == configuration, let current = self.device, CFEqual(current, device) { return }
        stop()
        guard !configuration.keys.isEmpty else { return }
        try worker.start(name: "Serpentis physical modifiers") {
            try ModifierTapSession(configuration: configuration, device: device, onError: onError)
        }
        self.configuration = configuration
        self.device = device
    }

    func stop() {
        worker.stop()
        configuration = nil; device = nil
    }
}
