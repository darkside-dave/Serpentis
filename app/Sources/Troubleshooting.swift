import AppKit
import SwiftUI
import IOKit
import IOKit.hid

enum DiagnosticConnection: String, Codable { case disconnected, cable, wireless }
enum DiagnosticPermission: String, Codable { case allowed, denied, notDetermined }
enum MouseUtility: String, Codable, CaseIterable {
    case karabiner = "Karabiner-Elements", steerMouse = "SteerMouse"
    static func connectedClient(_ name: String) -> Self? {
        let name = name.lowercased()
        if name.contains("karabiner") { return .karabiner }
        if name.contains("steermouse") { return .steerMouse }
        return nil
    }
}

struct DiagnosticReport: Codable, Equatable {
    var appVersion: String
    var macOSVersion: String
    var connection: DiagnosticConnection
    var inputMonitoring: DiagnosticPermission
    var accessibility: Bool
    var keyboardInterfaces: Int
    var keyboardInterfacesWithoutDriver: Int
    var otherMouseUtilities: [MouseUtility]
    var rawButtonInputObserved: Bool

    var text: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

enum TroubleshootingIssue: String, CaseIterable, Identifiable {
    case buttons = "Buttons do not type", connection = "Mouse not detected", scrolling = "Scrolling or pointer settings", saving = "Settings do not save"
    var id: String { rawValue }
    var steps: [String] {
        switch self {
        case .buttons:
            return ["Click the test field below and press a button with a keyboard assignment. Raw input and typed text are checked separately.",
                    "Quit other mouse utilities. In Karabiner, check every Naga entry, including any entry shown as both a keyboard and mouse.",
                    "If raw input appears but no text is typed, quit Serpentis, turn the mouse off, unplug the receiver and wait 10 seconds. Reconnect it, switch the mouse to 2.4 GHz mode, and test in TextEdit before reopening Serpentis.",
                    "Try the USB cable with the receiver unplugged. If USB works and wireless does not, include that result in your issue.",
                    "For keypad-only failures, check Mouse Keys in Accessibility → Pointer Control and try a regular letter assignment."]
        case .connection:
            return ["Wake the mouse and check that its switch is set to 2.4 GHz for the receiver. Bluetooth is not supported by this app.",
                    "Connect the USB cable directly and unplug the receiver to test one connection at a time.",
                    "Quit other mouse utilities, then reopen Serpentis. Check Input Monitoring if macOS blocks access.",
                    "Click Check mouse after reconnecting. A sleeping mouse can remain connected while settings requests go unanswered."]
        case .scrolling:
            return ["Scroll inversion needs Accessibility permission. After enabling it for Serpentis, quit and reopen the app if scrolling is unchanged.",
                    "Quit SteerMouse and other pointer utilities so they do not override the same settings or hide the mouse's identity.",
                    "Test the wheel and horizontal tilt in a second app. Your trackpad should keep its own scroll direction.",
                    "Sensitivity uses Serpentis's scale: 1000 is normal, and 2000 is twice the speed with acceleration disabled. Reset returns to 1000."]
        case .saving:
            return ["Wake the mouse and wait for the current operation to finish before saving again.",
                    "Check the assignment shown after saving. A confirmed assignment does not guarantee that macOS is receiving the corresponding key presses; use the button test if it does not type.",
                    "Try the USB cable with the wireless receiver unplugged, then save again.",
                    "Save a named layout before using Reset All Buttons. A reset replaces custom assignments with factory defaults."]
        }
    }
}

enum DiagnosticInput {
    static func description(page: UInt32, usage: UInt32, value: Int) -> String? {
        guard value == 0 || value == 1 else { return nil }
        let state = value == 1 ? "pressed" : "released"
        if page == 7, (4...0xE7).contains(usage) { return "\(hidKeyName(UInt8(usage))) \(state)" }
        if page == 9, (1...32).contains(usage) { return "Mouse button \(usage) \(state)" }
        return nil
    }
}

struct ButtonTestState {
    private struct Key: Hashable { let device: UInt64; let page: UInt32; let usage: UInt32 }
    private var held: Set<Key> = []
    private(set) var pressCount = 0

    mutating func record(device: UInt64, page: UInt32, usage: UInt32, value: Int) -> String? {
        guard let description = DiagnosticInput.description(page: page, usage: usage, value: value) else { return nil }
        let key = Key(device: device, page: page, usage: usage)
        if value == 1 {
            guard held.insert(key).inserted else { return nil }
            pressCount += 1
        } else {
            guard held.remove(key) != nil else { return nil }
        }
        return description
    }
}

final class TroubleshootingController: ObservableObject {
    @Published private(set) var report: DiagnosticReport?
    @Published private(set) var checking = false
    @Published private(set) var testing = false
    @Published private(set) var testStatus = "Click Start button test, then click the test field."
    @Published private(set) var signalCount = 0
    private let queue = DispatchQueue(label: "serpentis.diagnostics", qos: .utility)
    private var testManager: IOHIDManager?
    private var testTimer: Timer?
    private var testState = ButtonTestState()

    static func hasEventDriver(_ entry: io_registry_entry_t, depth: Int = 0) -> Bool {
        guard depth < 6 else { return false }
        if IOObjectConformsTo(entry, "IOHIDEventService") != 0 || IOObjectConformsTo(entry, "AppleUserHIDEventService") != 0 { return true }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        var child = IOIteratorNext(iterator)
        while child != 0 {
            let found = hasEventDriver(child, depth: depth + 1)
            IOObjectRelease(child)
            if found { return true }
            child = IOIteratorNext(iterator)
        }
        return false
    }

    private static func connectedUtilities(_ entry: io_registry_entry_t, depth: Int = 0) -> Set<MouseUtility> {
        guard depth < 6 else { return [] }
        var utilities: Set<MouseUtility> = []
        if let creator = IORegistryEntryCreateCFProperty(entry, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
           let utility = MouseUtility.connectedClient(creator) { utilities.insert(utility) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return utilities }
        defer { IOObjectRelease(iterator) }
        var child = IOIteratorNext(iterator)
        while child != 0 {
            utilities.formUnion(connectedUtilities(child, depth: depth + 1))
            IOObjectRelease(child)
            child = IOIteratorNext(iterator)
        }
        return utilities
    }

    func check() {
        guard !checking else { return }
        checking = true
        let apps = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() }
        let utilities = MouseUtility.allCases.filter { utility in
            apps.contains { id in
                switch utility {
                case .karabiner: return id.hasPrefix("org.pqrs.karabiner")
                case .steerMouse: return id.hasPrefix("jp.plentycom") && id.contains("steermouse")
                }
            }
        }
        let access: DiagnosticPermission
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: access = .allowed
        case kIOHIDAccessTypeDenied: access = .denied
        default: access = .notDetermined
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let accessibility = AXIsProcessTrusted()
        queue.async {
            var iterator: io_iterator_t = 0
            var connection = DiagnosticConnection.disconnected
            var keyboards = 0, missing = 0
            var detectedUtilities = Set(utilities)
            if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS {
                defer { IOObjectRelease(iterator) }
                var device = IOIteratorNext(iterator)
                while device != 0 {
                    func number(_ key: String) -> Int? {
                        (IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
                    }
                    if number(kIOHIDVendorIDKey) == kRazerVID, let product = number(kIOHIDProductIDKey), kNagaPIDs[product] != nil {
                        detectedUtilities.formUnion(Self.connectedUtilities(device))
                        if product == 0xE7 { connection = .cable }
                        else if connection != .cable { connection = .wireless }
                        if number(kIOHIDPrimaryUsagePageKey) == 1 && number(kIOHIDPrimaryUsageKey) == 6 {
                            keyboards += 1
                            if !Self.hasEventDriver(device) { missing += 1 }
                        }
                    }
                    IOObjectRelease(device)
                    device = IOIteratorNext(iterator)
                }
            }
            let report = DiagnosticReport(appVersion: version, macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                connection: connection, inputMonitoring: access, accessibility: accessibility,
                keyboardInterfaces: keyboards, keyboardInterfacesWithoutDriver: missing,
                otherMouseUtilities: MouseUtility.allCases.filter { detectedUtilities.contains($0) }, rawButtonInputObserved: false)
            DispatchQueue.main.async {
                var updated = report
                updated.rawButtonInputObserved = self.signalCount > 0
                self.report = updated
                self.checking = false
            }
        }
    }

    func startTest() {
        stopTest()
        signalCount = 0
        testState = ButtonTestState()
        if var report = report { report.rawButtonInputObserved = false; self.report = report }
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            testStatus = "Allow Input Monitoring for Serpentis, then quit and reopen it before testing."
            return
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        let matches = kNagaPIDs.keys.sorted().flatMap { product in
            [2, 6].map { usage in [kIOHIDVendorIDKey: kRazerVID, kIOHIDProductIDKey: product,
                                  kIOHIDPrimaryUsagePageKey: 1, kIOHIDPrimaryUsageKey: usage] }
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard let context = context, result == kIOReturnSuccess else { return }
            let controller = Unmanaged<TroubleshootingController>.fromOpaque(context).takeUnretainedValue()
            guard controller.testing else { return }
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element)
            let amount = IOHIDValueGetIntegerValue(value)
            guard DiagnosticInput.description(page: page, usage: usage, value: amount) != nil else { return }
            let device = IOHIDElementGetDevice(element)
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id) == KERN_SUCCESS,
                  let description = controller.testState.record(device: id, page: page, usage: usage, value: amount) else { return }
            controller.signalCount = controller.testState.pressCount
            controller.testStatus = "Raw input: \(description). Check whether text appears in the field."
            if controller.signalCount > 0, controller.report?.rawButtonInputObserved == false { controller.report?.rawButtonInputObserved = true }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        testManager = manager
        let result = IOHIDManagerOpen(manager, 0)
        guard result == kIOReturnSuccess else {
            stopTest()
            testStatus = "Mouse input is unavailable. Quit other mouse utilities and check Input Monitoring, then reopen Serpentis."
            return
        }
        testing = true
        testStatus = "Listening for 15 seconds. Click the test field and press a mapped mouse button."
        testTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in self?.stopTest() }
    }

    func stopTest() {
        let wasTesting = testing
        testing = false
        testTimer?.invalidate(); testTimer = nil
        if let manager = testManager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, 0)
        }
        testManager = nil
        if wasTesting {
            testStatus = signalCount > 0 ? "Raw button input received. If no text appeared, follow the reconnect steps above." : "No button input received. Check the connection and Input Monitoring, then try again."
        }
    }

    func copyReport() {
        guard let report = report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.text, forType: .string)
    }
}

struct TroubleshootingView: View {
    @EnvironmentObject var model: SerpentisModel
    @EnvironmentObject var diagnostics: TroubleshootingController
    @EnvironmentObject var input: MouseInputController
    @LocalState private var issue: TroubleshootingIssue = .buttons
    @LocalState private var testText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader(title: "Troubleshooting", subtitle: "Check the connection and test button input without changing mouse settings.")
                HStack {
                    Button("Check mouse") { diagnostics.check(); model.refresh(); input.refresh() }
                        .disabled(diagnostics.checking)
                    if diagnostics.checking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Input Monitoring settings") { model.app?.openPrivacy() }
                    Button("Accessibility settings") { input.openAccessibility() }
                }
                if let report = diagnostics.report {
                    GroupBox("Connection and permissions") {
                        VStack(alignment: .leading, spacing: 10) {
                            row("Connection", report.connection == .disconnected ? "No supported Naga detected" : report.connection == .cable ? "USB cable" : "Wireless receiver", ok: report.connection != .disconnected)
                            row("Input Monitoring", report.inputMonitoring == .allowed ? "Allowed" : "Permission needed for the button test", ok: report.inputMonitoring == .allowed)
                            row("Accessibility", report.accessibility ? "Allowed" : "Needed when using scroll inversion", ok: report.accessibility || !input.invertScrolling)
                            row("Keyboard input", report.keyboardInterfaces == 0 ? "No keyboard interface detected" : report.keyboardInterfacesWithoutDriver > 0 ? "A keyboard interface has no macOS input driver. Try a clean reconnect." : "macOS keyboard drivers attached", ok: report.keyboardInterfaces > 0 && report.keyboardInterfacesWithoutDriver == 0)
                            row("Other mouse utilities", report.otherMouseUtilities.isEmpty ? "None detected" : report.otherMouseUtilities.map { $0.rawValue }.joined(separator: ", ") + " detected; check their Naga exclusions.", ok: report.otherMouseUtilities.isEmpty)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                Picker("Problem", selection: $issue) {
                    ForEach(TroubleshootingIssue.allCases) { Text($0.rawValue).tag($0) }
                }.frame(maxWidth: 430)
                GroupBox(issue.rawValue) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(issue.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1).").foregroundStyle(.secondary).frame(width: 18)
                                Text(step).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if issue == .buttons {
                    GroupBox("Button test") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Button(diagnostics.testing ? "Stop button test" : "Start button test") {
                                    if diagnostics.testing { diagnostics.stopTest() }
                                    else { testText = ""; diagnostics.startTest() }
                                }
                                Text("Naga only · stops after 15 seconds").font(.caption).foregroundStyle(.secondary)
                            }
                            TextField("Click here, then press a mapped mouse button", text: $testText).textFieldStyle(.roundedBorder)
                            Text(diagnostics.testStatus).font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                DisclosureGroup("Diagnostic report") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The report includes connection and permission status. It excludes device serials, account names, file paths, button assignments and typed text.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let report = diagnostics.report {
                            Text(report.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Button("Copy report") { diagnostics.copyReport() }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
            }.padding(24)
        }
        .onAppear { diagnostics.check() }
        .onDisappear { diagnostics.stopTest(); testText = "" }
        .onChange(of: issue) { _ in diagnostics.stopTest(); testText = "" }
    }

    private func row(_ title: String, _ detail: String, ok: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(ok ? .green : .orange)
            Text(title).fontWeight(.medium).frame(width: 135, alignment: .leading)
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
