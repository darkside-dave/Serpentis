import AppKit
import SwiftUI
import IOKit.hid

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError(message) }
}
func service(_ id: UInt64, _ acceleration: Int?, vendor: Int = kRazerVID, product: Int = 0xE7, pointer: Bool = true) -> MouseInputService {
    MouseInputService(id: id, vendor: vendor, product: product, pointer: pointer, acceleration: acceleration)
}

// Physical control IDs and factory assignments must match the protocol inventory.
let ring = SerpentisModel.slot(0x39)
expect(ring.name == "Ring / Pinky Button", "Slot 0x39 must select the ring-finger control")
expect(ring.factory == [1, 0x39, 0, 0x0C, 1, 0x39, 0, 0, 0, 0], "Restore the exact observed ring assignment")
expect(SerpentisModel.slot(0x6A).name == "Front Button Behind Wheel", "Slot 0x6A is the wheel-mode control")
expect(SerpentisModel.slot(0x80).factory == [1, 0x80, 0, 0, 1, 0, 0, 0, 0, 0], "Rear wheel button has a real disabled default")
expect(SerpentisModel.slot(0x0B).factory == [1, 0x0B, 0, 6, 1, 1, 0, 0, 0, 0], "Preserve DPI-up factory action")
expect(SerpentisModel.slot(0x0C).factory == [1, 0x0C, 0, 6, 1, 2, 0, 0, 0, 0], "Preserve DPI-down factory action")
expect(Set(SerpentisModel.slots.map { $0.id }).count == SerpentisModel.slots.count && SerpentisModel.slots.count == 20, "Expose all 20 supported controls without ID collisions")
let factoryModel = SerpentisModel()
factoryModel.buttons[0x39] = [1, 0x39, 0, 0x0C, 1, 0x39, 0, 0, 0, 0]
expect(factoryModel.isDefault(ring), "The actual ring factory binding must display as Default")

// Acceleration must never leak to trackpads, other mice, or non-pointer interfaces.
var writes: [(UInt64, Int)] = []
var saved: [String: Int] = [:]
let state = AccelerationOverride { saved = $0 }
let devices = [service(1, 32768), service(2, 50000, vendor: 0x05AC), service(3, 40000, product: 0x1234), service(4, 10000, pointer: false)]
expect(state.sync(enabled: true, services: devices) { id, value in
    expect(saved[String(id)] != nil, "Original must be journaled before changing the device")
    writes.append((id, value)); return true
} == 0, "Enable should succeed")
expect(writes.count == 1 && writes[0].0 == 1 && writes[0].1 == -65536, "Only the supported Naga pointer should change")
expect(saved == ["1": 32768], "Save the exact original acceleration")
writes = []
expect(state.sync(enabled: true, services: [service(1, -65536)]) { id, value in writes.append((id, value)); return true } == 0, "Repeated refresh succeeds")
expect(writes.isEmpty && saved["1"] == 32768, "Refresh must not overwrite the original or rewrite an applied setting")
state.sync(enabled: false, services: [service(1, -65536)]) { id, value in writes.append((id, value)); return true }
expect(writes.count == 1 && writes[0].1 == 32768 && saved.isEmpty, "Turning off must restore the exact value and clear its journal")

// A journal survives a crash; unplugged IDs must never be applied to a different device.
let recovered = AccelerationOverride(originals: ["1": 49152])
writes = []
recovered.sync(enabled: false, services: [service(9, 20000)]) { id, value in writes.append((id, value)); return true }
expect(writes.isEmpty && recovered.originals["1"] == 49152, "Don't restore an unplugged service onto a new ID")
recovered.sync(enabled: false, services: [service(1, -65536)]) { id, value in writes.append((id, value)); return true }
expect(writes.count == 1 && writes[0].1 == 49152, "Recover the saved baseline after a crash")

let failed = AccelerationOverride()
expect(failed.sync(enabled: true, services: [service(7, 10000)]) { _, _ in false } == 1, "Report denied writes")
expect(failed.originals["7"] == 10000, "Keep recovery data when a write cannot be confirmed")
expect(failed.sync(enabled: false, services: [service(7, -65536)]) { _, _ in false } == 1, "Report failed restoration")
expect(failed.originals["7"] == 10000, "Retry restoration later")
expect(failed.sync(enabled: false, services: [service(7, nil)]) { _, _ in fatalError("Missing property must not be written") } == 1, "Missing property isn't success")
failed.sync(enabled: false, services: [service(7, 25000)]) { _, _ in fatalError("A later external change must be preserved") }
expect(failed.originals.isEmpty, "Release ownership after another app changes the value")

let reconnected = AccelerationOverride(originals: ["1": 12345])
writes = []
reconnected.sync(enabled: true, services: [service(10, 23456, product: 0xE8)]) { id, value in writes.append((id, value)); return true }
expect(writes.count == 1 && writes[0].0 == 10 && reconnected.originals["10"] == 23456, "Reconnect applies to the receiver with its own baseline")

// Sensitivity is independent of sensor DPI, restores all properties, and never accumulates gain.
expect(PointerSensitivity.clamp(-1) == 0 && PointerSensitivity.clamp(3000) == 2000, "Bound sensitivity input")
expect(PointerSensitivity.gain(0) > 0 && PointerSensitivity.gain(1000) == 1 && PointerSensitivity.gain(2000) == 2, "Zero must leave the pointer usable")
var tuningServices = [service(21, 32768), service(22, 50000, vendor: 0x05AC)]
var tuningWrites: [(UInt64, String, Int)] = []
var tuningSaved: PointerTuningOverride.Journal = [:]
let tuning = PointerTuningOverride { tuningSaved = $0 }
func tuneWrite(_ id: UInt64, _ key: String, _ value: Int) -> Bool {
    expect(tuningSaved[String(id)]?[key] != nil, "Every property needs recovery data before its write")
    tuningWrites.append((id, key, value))
    guard let index = tuningServices.firstIndex(where: { $0.id == id }) else { return false }
    let current = tuningServices[index]
    tuningServices[index] = MouseInputService(id: id, vendor: current.vendor, product: current.product, pointer: current.pointer,
        acceleration: key == PointerSensitivity.accelerationKey ? value : current.acceleration,
        linearScaling: key == PointerSensitivity.linearKey ? value : current.linearScaling,
        resolution: key == PointerSensitivity.resolutionKey ? value : current.resolution)
    return true
}
expect(tuning.sync(sensitivity: 1500, disableAcceleration: true, services: tuningServices, write: tuneWrite) == 0, "Linear sensitivity applies")
expect(tuningServices[0].linearScaling == 1 && tuningServices[0].acceleration == 98304, "1500 should apply constant 1.5× gain")
expect(tuningServices[1].acceleration == 50000 && tuningWrites.allSatisfy { $0.0 == 21 }, "Leave other pointing devices unchanged")
tuning.sync(sensitivity: 500, disableAcceleration: true, services: tuningServices, write: tuneWrite)
expect(tuningServices[0].acceleration == 32768 && tuning.journal["21"]?[PointerSensitivity.accelerationKey]?.original == 32768, "Adjust gain from the same baseline")
tuning.sync(sensitivity: 2000, disableAcceleration: false, services: tuningServices, write: tuneWrite)
expect(tuningServices[0].resolution == 200 * 65536 && tuningServices[0].linearScaling == 0 && tuningServices[0].acceleration == 32768, "Retain the acceleration curve and change device sensitivity")
expect(tuningWrites.last?.1 == PointerSensitivity.accelerationKey, "Refresh the acceleration filter after changing resolution")
let priorWrites = tuningWrites.count
tuning.sync(sensitivity: 2000, disableAcceleration: false, services: tuningServices, write: tuneWrite)
expect(tuningWrites.count == priorWrites, "Stable settings should not be rewritten")
let crashJournal = tuning.journal
let crashTuning = PointerTuningOverride(journal: crashJournal) { tuningSaved = $0 }
crashTuning.sync(sensitivity: 1000, disableAcceleration: false, services: tuningServices, write: tuneWrite)
expect(tuningServices[0].resolution == 400 * 65536 && tuningServices[0].linearScaling == 0 && tuningServices[0].acceleration == 32768, "Restore every effective pointer parameter after a crash")
expect(crashTuning.journal.isEmpty, "Clear journal after successful restoration")
let partialTuning = PointerTuningOverride()
var partiallyChanged = service(23, 40000)
expect(partialTuning.sync(sensitivity: 2000, disableAcceleration: true, services: [partiallyChanged]) { _, key, _ in
    if key == PointerSensitivity.linearKey { partiallyChanged.linearScaling = 1; return true }
    return false
} == 1, "Report a partially rejected pointer configuration")
var restoredKeys: [String] = []
partialTuning.sync(sensitivity: 1000, disableAcceleration: false, services: [partiallyChanged]) { _, key, _ in restoredKeys.append(key); return true }
expect(restoredKeys.contains(PointerSensitivity.linearKey) && partialTuning.journal.isEmpty, "Restore the accepted portion of a failed change")
let externalTuning = PointerTuningOverride(journal: crashJournal)
var external = service(21, 123456)
external.resolution = 200 * 65536
externalTuning.sync(sensitivity: 1000, disableAcceleration: false, services: [external]) { _, key, _ in
    expect(key != PointerSensitivity.accelerationKey, "Preserve a later external acceleration value")
    return true
}
expect(externalTuning.journal.isEmpty, "Release ownership after an external change")

// Preserve all scroll representations, including smooth fractions, flags and phases.
let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 3, wheel1: 2, wheel2: -3, wheel3: 1)!
event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 1.5)
event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 19)
event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -2.25)
event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -31)
event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
event.flags = [.maskShift, .maskAlternate]
let copy = event.copy()!
ScrollTransform.reverse(event)
expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -copy.getIntegerValueField(.scrollWheelEventDeltaAxis1), "Reverse vertical line delta")
expect(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) == -1.5, "Preserve vertical fractional precision")
expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -19, "Preserve vertical pixel magnitude")
expect(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) == 2.25, "Reverse horizontal fractional delta")
expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 31, "Reverse horizontal pixel delta")
expect(event.flags == copy.flags && event.getIntegerValueField(.scrollWheelEventScrollPhase) == 2, "Keep modifiers and phases")
expect(event.getIntegerValueField(.scrollWheelEventIsContinuous) == copy.getIntegerValueField(.scrollWheelEventIsContinuous), "Keep continuous-event metadata")
ScrollTransform.reverse(event)
expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 19 && event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) == -2.25, "Reversing twice restores the original")
let bridge = ScrollDeviceBridge()
expect(!bridge.reverse(event, enabled: true, nagaIDs: [123]), "Synthetic/unidentified sources must pass through")
expect(!bridge.reverse(event, enabled: false, nagaIDs: [123]), "Disabled inversion must pass through")
expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 19, "Passthrough must not mutate the event")
// Refresh requests retain all changed fields while merging duplicate reads.
var refreshQueue = RefreshQueue()
let oneButton = MouseRefreshRequest(buttonIDs: [0x0B])
expect(refreshQueue.enqueue(oneButton) == oneButton, "Start a single-button refresh without reading unrelated settings")
expect(refreshQueue.enqueue(.lighting) == nil, "Queue lighting while a read is running")
expect(refreshQueue.enqueue(.lighting) == nil, "Merge repeated lighting refreshes")
expect(refreshQueue.enqueue(MouseRefreshRequest(buttonIDs: [0x39])) == nil, "Queue another changed control")
let mergedRefresh = refreshQueue.finish()
expect(mergedRefresh?.fields == .lighting && mergedRefresh?.buttonIDs == [0x39], "Preserve the union of pending reads")
expect(refreshQueue.running, "A merged request remains in flight")
expect(refreshQueue.finish() == nil && !refreshQueue.running, "Return to idle after the merged request")
expect(refreshQueue.enqueue(MouseRefreshRequest()) == nil && !refreshQueue.running, "Empty requests must not schedule work")
expect(MouseRefreshRequest.menu.buttonIDs.isEmpty && !MouseRefreshRequest.menu.fields.contains(.lighting), "Menu refreshes omit button and lighting reads")
expect(InputMonitorPolicy.interval(disableAcceleration: false, sensitivity: 1000, invertScrolling: false, hasRecovery: false) == nil, "Default pointer settings must not start a polling timer")
expect(InputMonitorPolicy.interval(disableAcceleration: false, sensitivity: 1500, invertScrolling: false, hasRecovery: false) == 3, "Keep monitoring active sensitivity overrides")
expect(InputMonitorPolicy.interval(disableAcceleration: false, sensitivity: 1000, invertScrolling: false, hasRecovery: true) == 3, "Keep recovery retries active until restoration finishes")
expect(InputMonitorPolicy.interval(disableAcceleration: false, sensitivity: 1000, invertScrolling: true, hasRecovery: false) == 3, "Retry scroll permissions and source matching while enabled")

// Diagnostic exports have a closed schema and exclude input text and device identifiers.
let diagnostic = DiagnosticReport(appVersion: "1.5", macOSVersion: "27.0.0", connection: .wireless,
    inputMonitoring: .allowed, accessibility: false, keyboardInterfaces: 2,
    keyboardInterfacesWithoutDriver: 1, otherMouseUtilities: [.karabiner], rawButtonInputObserved: true)
let reportJSON = try JSONSerialization.jsonObject(with: Data(diagnostic.text.utf8)) as! [String: Any]
expect(Set(reportJSON.keys) == ["appVersion", "macOSVersion", "connection", "inputMonitoring", "accessibility", "keyboardInterfaces", "keyboardInterfacesWithoutDriver", "otherMouseUtilities", "rawButtonInputObserved"], "Only the approved diagnostic fields may be exported")
let decodedReport = try JSONDecoder().decode(DiagnosticReport.self, from: Data(diagnostic.text.utf8))
expect(decodedReport == diagnostic, "Diagnostic exports round-trip")
expect(DiagnosticInput.description(page: 7, usage: UInt32.max, value: 89) == nil, "Ignore packed keyboard-array values")
expect(DiagnosticInput.description(page: 7, usage: 0, value: 0) == nil, "Ignore empty keyboard-array entries")
expect(DiagnosticInput.description(page: 1, usage: 0x30, value: 1) == nil, "Pointer motion must not count as a button signal")
expect(DiagnosticInput.description(page: 7, usage: 0x59, value: 1) == "Num 1 pressed", "Recognize Naga keypad input independently of text entry")
expect(DiagnosticInput.description(page: 7, usage: 4, value: 0) == "A released", "Recognize key releases")
expect(DiagnosticInput.description(page: 9, usage: 3, value: 1) == "Mouse button 3 pressed", "Recognize the wheel control test")
var buttonTest = ButtonTestState()
expect(buttonTest.record(device: 1, page: 9, usage: 1, value: 0) == nil && buttonTest.pressCount == 0, "A release without a press must not pass the raw-input check")
expect(buttonTest.record(device: 1, page: 7, usage: 0x59, value: 1) == "Num 1 pressed" && buttonTest.pressCount == 1, "Count a real press")
expect(buttonTest.record(device: 1, page: 7, usage: 0x59, value: 1) == nil && buttonTest.pressCount == 1, "Repeated held values must not inflate the press count")
expect(buttonTest.record(device: 2, page: 7, usage: 0x59, value: 0) == nil, "A different interface cannot release the held key")
expect(buttonTest.record(device: 1, page: 7, usage: 0x59, value: 0) == "Num 1 released" && buttonTest.pressCount == 1, "Track the matching release without counting another press")
expect(MouseUtility.connectedClient("Karabiner-Core-S") == .karabiner, "Identify a background Karabiner client")
expect(MouseUtility.connectedClient("SteerMouse Manag") == .steerMouse, "Identify the SteerMouse background manager")
expect(MouseUtility.connectedClient("WindowServer") == nil, "Do not export unrelated client names")
print("Passed \(checks) input-behavior checks. Device-identification bridge available: \(bridge.available)")

// Menu construction can be timed independently of a connected device.
if CommandLine.arguments.contains("--benchmark-menu") {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let delegate = AppDelegate()
    delegate.model.connected = true
    delegate.model.connection = "Wireless"
    delegate.model.firmware = "1.0"
    delegate.model.dpi = DPIStage(x: 3200, y: 3200)
    delegate.model.stages = DPIStageSet(active: 1, stages: [DPIStage(x: 3200, y: 3200)])
    delegate.model.polling = 1000
    delegate.battery = 85
    delegate.buttonCache = Dictionary(uniqueKeysWithValues: SerpentisModel.slots.map { ($0.id, $0.factory) })
    var durations: [Double] = []
    for _ in 0..<10 {
        let start = Date()
        delegate.buildMenu(delegate.menu)
        durations.append(Date().timeIntervalSince(start))
    }
    print(String(format: "Cached menu benchmark (fixture, no device I/O): average %.2f ms, maximum %.2f ms (10 samples).",
        durations.reduce(0, +) / Double(durations.count) * 1000, (durations.max() ?? 0) * 1000))
}

// Read-only timing check using the production settings queue and cached menu.
func benchmarkMenu() {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let delegate = AppDelegate()
    delegate.model.app = delegate
    let initialStart = Date()
    delegate.startHID()
    defer {
        IOHIDManagerUnscheduleFromRunLoop(delegate.manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(delegate.manager, 0)
    }
    guard delegate.mouse != nil else {
        print("Read-only benchmark unavailable: no accessible settings interface.")
        return
    }
    let timeout = Date().addingTimeInterval(10)
    var retry = Date().addingTimeInterval(1)
    while !delegate.model.loadedOnce && Date() < timeout {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        if delegate.model.busy == 0 && Date() >= retry {
            delegate.model.refresh(.battery)
            retry = Date().addingTimeInterval(1)
        }
    }
    guard delegate.model.loadedOnce else {
        print("Read-only benchmark unavailable: the mouse did not answer a complete settings read (asleep=\(delegate.model.asleep)).")
        return
    }
    let initialTime = Date().timeIntervalSince(initialStart)
    var durations: [Double] = []
    for _ in 0..<10 {
        let start = Date()
        delegate.menuNeedsUpdate(delegate.menu)
        durations.append(Date().timeIntervalSince(start))
    }
    let drain = Date().addingTimeInterval(10)
    while delegate.model.busy > 0 && Date() < drain {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    print(String(format: "Read-only benchmark: initial full read %.0f ms; cached menu average %.2f ms, maximum %.2f ms (10 samples).",
        initialTime * 1000, durations.reduce(0, +) / Double(durations.count) * 1000, (durations.max() ?? 0) * 1000))
}
if CommandLine.arguments.contains("--benchmark") { benchmarkMenu() }

// Explicit opt-in: use the production backend and immediately restore every live Naga value.
if CommandLine.arguments.contains("--hardware") {
    let system = NagaInputSystem()
    let baseline = system.services()
    let pointers = baseline.filter { $0.isNaga && $0.pointer && $0.acceleration != nil }
    expect(!pointers.isEmpty, "Hardware check needs access to a connected Naga")
    let override = AccelerationOverride()
    let applyFailures = override.sync(enabled: true, services: baseline, write: system.setAcceleration)
    let applied = system.services()
    let restoreFailures = override.sync(enabled: false, services: applied, write: system.setAcceleration)
    let restored = system.services()
    // Always attempt restoration before asserting the result of the application check.
    expect(restoreFailures == 0, "Hardware restoration failed; reopen Serpentis and disable acceleration")
    for pointer in pointers {
        expect(restored.first { $0.id == pointer.id }?.acceleration == pointer.acceleration, "Hardware value must match its baseline")
    }
    expect(applyFailures == 0 && applied.filter { $0.pointer }.allSatisfy { $0.acceleration == -65536 }, "Hardware disable/readback failed")
    print("Hardware check: disabled, verified and restored \(pointers.count) Naga pointer services.")
    for mode in [true, false] {
        let before = system.services()
        let tuning = PointerTuningOverride()
        let failures = tuning.sync(sensitivity: 1500, disableAcceleration: mode, services: before) { id, key, value in
            let ok = system.setPointerProperty(id, key, value)
            print("  sensitivity write \(id) \(key)=\(value): \(ok)")
            fflush(stdout)
            return ok
        }
        let applied = system.services()
        let restoreFailures = tuning.sync(sensitivity: 1000, disableAcceleration: false, services: applied, write: system.setPointerProperty)
        let after = system.services()
        print("  mode=\(mode) failures=\(failures) restorationFailures=\(restoreFailures)")
        fflush(stdout)
        expect(restoreFailures == 0, "Restore sensitivity check before reporting application failure")
        for pointer in before where pointer.pointer {
            expect(after.first { $0.id == pointer.id }?.pointerValues == pointer.pointerValues, "Sensitivity check must restore the effective baseline")
        }
        expect(failures == 0, "macOS rejected a sensitivity setting")
        for pointer in before where pointer.pointer {
            let desired = PointerSensitivity.targets(sensitivity: 1500, disableAcceleration: mode, original: pointer.pointerValues!)
            expect(applied.first { $0.id == pointer.id }?.pointerValues == desired, "Sensitivity setting must read back correctly")
        }
        print("Hardware sensitivity check: acceleration disabled=\(mode), applied and restored successfully.")
    }
}

// Optional visual QA. No live input controls are started, and no privacy prompts are made.
if let flag = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > flag + 1 {
    let directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let model = SerpentisModel()
    model.connected = true; model.loadedOnce = true; model.connection = "Cable"; model.battery = 85
    for slot in SerpentisModel.slots { model.buttons[slot.id] = slot.factory }
    let suite = "com.serpentis.visual-check.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let input = MouseInputController(defaults: defaults)
    @MainActor func render<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat) throws {
        let host = NSHostingView(rootView: view.environmentObject(model).environmentObject(input).environmentObject(TroubleshootingController())
            .environment(\.colorScheme, .dark).frame(width: width, height: height).background(Color(white: 0.12)))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Could not allocate render") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.orderOut(nil)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not render \(name)")
        }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        print("Rendered \(name)")
    }
    try MainActor.assumeIsolated {
        try render(NagaIllustration(), name: "naga-illustration", width: 280, height: 360)
        try render(ButtonsView(), name: "buttons", width: 760, height: 760)
        try render(InputSettingsView(), name: "pointer-and-scrolling", width: 760, height: 680)
        try render(TroubleshootingView(), name: "troubleshooting", width: 780, height: 900)
    }
}
