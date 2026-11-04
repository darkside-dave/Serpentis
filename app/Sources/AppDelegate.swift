// AppDelegate.swift - the menu-bar app.
import AppKit
import SwiftUI
import IOKit
import IOKit.hid
import UserNotifications

final class LightAction: NSObject {
    let zones: [Zone]; let kind: EffectKind; let color: RGB?; let brightness: UInt8?
    init(_ zones: [Zone], _ kind: EffectKind, color: RGB? = nil, brightness: UInt8? = nil) {
        self.zones = zones; self.kind = kind; self.color = color; self.brightness = brightness
    }
}

struct Profile: Codable {
    var stages: DPIStageSet?
    var pollingRate: Int?
    var lights: [String: ZoneLight]
}

let presetColors: [(String, RGB)] = [
    ("Red", RGB(r: 255, g: 0, b: 0)), ("Orange", RGB(r: 255, g: 100, b: 0)), ("Yellow", RGB(r: 255, g: 220, b: 0)),
    ("Green", RGB(r: 0, g: 255, b: 0)), ("Cyan", RGB(r: 0, g: 255, b: 255)), ("Blue", RGB(r: 0, g: 0, b: 255)),
    ("Purple", RGB(r: 160, g: 0, b: 255)), ("Pink", RGB(r: 255, g: 0, b: 140)), ("White", RGB(r: 255, g: 255, b: 255)),
]
let brightnessLevels: [(String, UInt8)] = [("Off", 0), ("25%", 64), ("50%", 128), ("75%", 191), ("100%", 255)]

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let model = SerpentisModel()
    let input = MouseInputController()
    let troubleshooting = TroubleshootingController()
    var window: NSWindow?
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var manager: IOHIDManager!
    var mouse: RazerMouse?
    var dock: RazerMouse?
    var openFailed = false
    var lights: [Zone: ZoneLight] = [:]
    var battery: Int?
    var charging = false
    var warnedLow = false
    var timer: Timer?
    private var dockTimer: Timer?
    var colorZones: [Zone] = []
    var colorKind: EffectKind = .staticColor
    var buttonCache: [UInt8: [UInt8]] = [:]
    var lastAutoLayout: String?
    private var pendingRescan: DispatchWorkItem?

    // MARK: - Startup
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "Serpentis")
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu
        model.app = self
        migrateFromNagaControl()
        setupMainMenu()
        input.start()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        startHID()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 65, repeats: true) { [weak self] _ in self?.refreshBattery() }
        timer?.tolerance = 5
        updateTitle()
        if !CommandLine.arguments.contains("--hidden") { DispatchQueue.main.async { self.openWindow() } }
    }

    func startHID() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, NagaTransport.products.sorted().map {
            [kIOHIDVendorIDKey: kRazerVID, kIOHIDProductIDKey: $0,
             kIOHIDPrimaryUsagePageKey: 1, kIOHIDPrimaryUsageKey: NagaTransport.settingsUsage($0)]
        } as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOHIDDeviceCallback = { ctx, _, _, _ in
            guard let ctx = ctx else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            me.pendingRescan?.cancel()
            let work = DispatchWorkItem { [weak me] in me?.rescan() }
            me.pendingRescan = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, cb, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, cb, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        rescan()
    }

    func rescan() {
        let devs = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        let candidates = devs.filter {
            let feat = (IOHIDDeviceGetProperty($0, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int) ?? 0
            let pid = (IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? Int) ?? 0
            return feat >= 90 && NagaTransport.products.contains(pid)
        }
        let preferred = candidates.sorted {
            let a = (IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? Int) ?? 0
            let b = (IOHIDDeviceGetProperty($1, kIOHIDProductIDKey as CFString) as? Int) ?? 0
            return NagaTransport.priority(a) < NagaTransport.priority(b)
        }.first
        let dockDevice = candidates.first { (IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? Int) == kMouseDockProPID }
        let sameMouse = mouse.map { current in preferred.map { CFEqual(current.device, $0) } ?? false } ?? (preferred == nil)
        let sameDock = dock.map { current in dockDevice.map { CFEqual(current.device, $0) } ?? false } ?? (dockDevice == nil)
        if sameMouse && sameDock { return }
        if let previous = mouse, previous.productID == kMouseDockProPID {
            NagaDockRegistry.set(previous.locationID, supported: false)
        }
        dockTimer?.invalidate(); dockTimer = nil
        mouse = nil; dock = nil
        openFailed = false
        lights = [:]
        buttonCache = [:]
        lastAutoLayout = nil
        battery = nil
        if let p = preferred {
            if let m = RazerMouse(device: p) {
                mouse = m
                if m.productID == kMouseDockProPID {
                    dockTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                        self?.model.refresh(.identity)
                    }
                    dockTimer?.tolerance = 1
                }
            } else {
                openFailed = true
            }
        }
        if let device = dockDevice {
            dock = mouse?.productID == kMouseDockProPID ? mouse : RazerMouse(device: device)
        }
        model.deviceChanged()
        updateTitle()
        model.refresh()
        input.devicesChanged()
    }

    func reloadLights() { model.refresh(.lighting) }

    // MARK: - Battery / status bar
    func refreshBattery() { model.refresh(.battery) }

    func updateBattery(_ value: Int?, charging: Bool) {
        battery = value
        self.charging = charging
        if let b = battery {
            if charging || b >= 20 { warnedLow = false }
            if b < 15 && !charging && !warnedLow {
                warnedLow = true
                notify("Naga battery low", "Battery is at \(b)%. Plug in the cable or dock to charge.")
            }
        }
        updateTitle()
    }

    func updateTitle() {
        guard let button = statusItem?.button else { return }
        if mouse == nil { button.title = ""; return }
        if let b = battery { button.title = (charging ? " ⚡" : " ") + "\(b)%" } else { button.title = " –" }
    }

    func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: - Menu helpers
    func item(_ title: String, _ action: Selector?, rep: Any? = nil, tag: Int = 0, checked: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self; i.representedObject = rep; i.tag = tag; i.state = checked ? .on : .off
        return i
    }
    func label(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }
    func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.submenu = sub; return i
    }

    // MARK: - Build menu each time it opens
    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refresh(.menu)
        buildMenu(menu)
    }

    func buildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Open Serpentis…", #selector(openWindow)))
        menu.addItem(item("Troubleshooting…", #selector(openTroubleshooting)))
        menu.addItem(.separator())
        let inputMenu = NSMenu()
        inputMenu.addItem(item("Disable Mouse Acceleration", #selector(toggleAcceleration), checked: input.disableAcceleration))
        inputMenu.addItem(item("Invert Scrolling", #selector(toggleScrollInversion), checked: input.invertScrolling))
        inputMenu.addItem(label("Naga only · while Serpentis is running"))
        if input.needsAccessibility { inputMenu.addItem(item("Open Accessibility Settings…", #selector(openInputAccessibility))) }
        menu.addItem(submenu("Pointer & Scrolling", inputMenu))
        menu.addItem(.separator())
        guard model.connected else {
            if openFailed {
                menu.addItem(label("Naga found, but macOS blocked access"))
                menu.addItem(item("Open Input Monitoring Settings…", #selector(openPrivacy)))
            } else {
                menu.addItem(label(mouse?.productID == kMouseDockProPID ? "Mouse Dock Pro found — waiting for a paired Naga V3 Pro" : "Naga V3 Pro not connected"))
            }
            addFooter(menu); return
        }
        menu.addItem(label("Razer Naga V3 Pro — \(model.connection)"))
        guard let b = battery else {
            menu.addItem(label(model.busy > 0 ? "Reading mouse settings…" : "Mouse asleep or out of range — move it to wake"))
            addFooter(menu); return
        }
        menu.addItem(label("Battery: \(b)%\(charging ? " (charging)" : "")"))
        menu.addItem(.separator())

        // DPI
        let cur = model.dpi
        let stages = model.stages
        menu.addItem(label("DPI: \(cur.map { $0.x == $0.y ? "\($0.x)" : "\($0.x) × \($0.y)" } ?? "?")"))
        if let st = stages {
            for (i, s) in st.stages.enumerated() {
                let on = st.active == i + 1 && cur?.x == s.x
                menu.addItem(item("    Step \(i + 1):  \(s.x)", #selector(selectStage(_:)), tag: i + 1, checked: on))
            }
        }
        menu.addItem(item("    Custom DPI (X / Y)…", #selector(customDPIXY)))
        menu.addItem(item("    Edit DPI Steps…", #selector(editStages)))
        menu.addItem(.separator())

        // Polling
        let rate = model.polling
        let pm = NSMenu()
        for hz in model.pollingRates { pm.addItem(item("\(hz) Hz", #selector(setRate(_:)), tag: hz, checked: rate == hz)) }
        menu.addItem(submenu("Polling Rate: \(rate.map { "\($0) Hz" } ?? "?")", pm))

        // Lighting
        let lm = NSMenu()
        lm.addItem(submenu("All Zones", lightingMenu(Zone.allCases)))
        lm.addItem(.separator())
        for z in Zone.allCases { lm.addItem(submenu(z.name, lightingMenu([z]))) }
        menu.addItem(submenu("Lighting", lm))
        menu.addItem(submenu("Side Buttons", sideButtonsMenu()))
        menu.addItem(submenu("Other Buttons", otherButtonsMenu()))
        menu.addItem(submenu("Power", powerMenu()))
        menu.addItem(.separator())

        // Profiles
        let profiles = loadProfiles()
        let prm = NSMenu()
        prm.addItem(item("Save Current Settings as Profile…", #selector(saveProfile)))
        if !profiles.isEmpty {
            prm.addItem(.separator())
            prm.addItem(label("Load:"))
            for name in profiles.keys.sorted() { prm.addItem(item("    \(name)", #selector(loadProfile(_:)), rep: name)) }
            let dm = NSMenu()
            for name in profiles.keys.sorted() { dm.addItem(item(name, #selector(deleteProfile(_:)), rep: name)) }
            prm.addItem(.separator())
            prm.addItem(submenu("Delete Profile", dm))
        }
        menu.addItem(submenu("Profiles", prm))
        addFooter(menu)
    }

    func addFooter(_ menu: NSMenu) {
        menu.addItem(.separator())
        menu.addItem(item("Start at Login", #selector(toggleLogin), checked: FileManager.default.fileExists(atPath: launchAgentURL.path)))
        menu.addItem(label("Serpentis \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")\((model.firmware.isEmpty ? nil : model.firmware).map { " · firmware \($0)" } ?? "")"))
        let q = NSMenuItem(title: "Quit Serpentis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(q)
    }

    func lightingMenu(_ zones: [Zone]) -> NSMenu {
        let ls = zones.compactMap { lights[$0] }
        let allSame: (ZoneLight) -> Bool = { l in ls.count == zones.count && ls.allSatisfy { $0.kind == l.kind && $0.color == l.color } }
        let menu = NSMenu()
        let spectrumOn = ls.count == zones.count && ls.allSatisfy { $0.kind == .spectrum }
        menu.addItem(item("Color Cycle", #selector(applyLight(_:)), rep: LightAction(zones, .spectrum), checked: spectrumOn))

        for (title, kind) in [("Solid Color", EffectKind.staticColor), ("Breathing", EffectKind.breathing)] {
            let sub = NSMenu()
            for (name, c) in presetColors {
                let on = allSame(ZoneLight(effect: [0, 0, kind == .staticColor ? 1 : 2, 0, 0, 0, c.r, c.g, c.b], brightness: 0))
                sub.addItem(item(name, #selector(applyLight(_:)), rep: LightAction(zones, kind, color: c), checked: on))
            }
            sub.addItem(.separator())
            sub.addItem(item("Custom Color…", #selector(customColor(_:)), rep: LightAction(zones, kind)))
            let anyOn = ls.count == zones.count && ls.allSatisfy { $0.kind == kind }
            let i = submenu(title, sub); i.state = anyOn ? .on : .off
            menu.addItem(i)
        }
        menu.addItem(.separator())
        let bvals = Set(ls.map { $0.brightness })
        let bTitle = bvals.count == 1 ? "Brightness: \(Int((Double(bvals.first!) / 255 * 100).rounded()))%" : "Brightness"
        let bm = NSMenu()
        for (name, v) in brightnessLevels {
            bm.addItem(item(name, #selector(applyLight(_:)), rep: LightAction(zones, .other, brightness: v), checked: bvals == [v]))
        }
        menu.addItem(submenu(bTitle, bm))
        return menu
    }

    // MARK: - DPI actions
    @objc func selectStage(_ sender: NSMenuItem) { model.selectStage(sender.tag) }

    func askNumber(_ title: String, _ info: String, _ initial: String) -> Int? {
        let a = NSAlert(); a.messageText = title; a.informativeText = info
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24)); f.stringValue = initial
        a.accessoryView = f
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return Int(f.stringValue.trimmingCharacters(in: .whitespaces))
    }

    func message(_ title: String, _ info: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = info
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    @objc func customDPI() {
        guard mouse != nil else { return }
        guard let value = askNumber("Custom DPI", "Enter a DPI from 100 to 30000.", "\(model.dpi?.x ?? 1600)") else { return }
        model.setDPI(value, value)
    }

    @objc func editStages() {
        guard mouse != nil, let cur = model.stages else { return }
        let a = NSAlert()
        a.messageText = "DPI Steps"
        a.informativeText = "The top-left DPI buttons cycle through these.\nLeave a box empty to remove that step. Range: 100–30000."
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        var fields: [NSTextField] = []
        for i in 0..<5 {
            let l = NSTextField(labelWithString: "Step \(i + 1):")
            l.widthAnchor.constraint(equalToConstant: 60).isActive = true
            let f = NSTextField(string: i < cur.stages.count ? "\(cur.stages[i].x)" : "")
            f.widthAnchor.constraint(equalToConstant: 100).isActive = true
            let row = NSStackView(views: [l, f]); row.orientation = .horizontal
            stack.addArrangedSubview(row); fields.append(f)
        }
        stack.setFrameSize(stack.fittingSize)
        a.accessoryView = stack
        a.addButton(withTitle: "Save to Mouse"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let vals = fields.compactMap { Int($0.stringValue.trimmingCharacters(in: .whitespaces)) }.map { max(100, min(30000, $0)) }
        guard !vals.isEmpty else { message("Need at least one step", "Nothing was changed."); return }
        model.saveStages(vals, active: cur.active)
    }

    @objc func setRate(_ sender: NSMenuItem) { model.setPolling(sender.tag) }

    // MARK: - Lighting actions
    @objc func applyLight(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? LightAction else { return }
        if let brightness = action.brightness {
            model.setBrightness(action.zones, Double(brightness) / 255 * 100)
        } else {
            model.setEffect(action.zones, action.kind, action.color ?? RGB(r: 255, g: 255, b: 255))
        }
    }

    @objc func customColor(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? LightAction else { return }
        colorZones = a.zones; colorKind = a.kind
        let p = NSColorPanel.shared
        p.showsAlpha = false
        p.isContinuous = true
        if let c = lights[a.zones[0]]?.color {
            p.color = NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
        }
        p.setTarget(self)
        p.setAction(#selector(colorChanged(_:)))
        p.title = "Naga Color — " + (a.zones.count > 1 ? "All Zones" : a.zones[0].name)
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    @objc func colorChanged(_ sender: Any?) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(applyPanelColor), object: nil)
        perform(#selector(applyPanelColor), with: nil, afterDelay: 0.12)
    }

    @objc func applyPanelColor() {
        guard mouse != nil, let c = NSColorPanel.shared.color.usingColorSpace(.sRGB) else { return }
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        let rgb = RGB(r: byte(c.redComponent), g: byte(c.greenComponent), b: byte(c.blueComponent))
        model.setEffect(colorZones, colorKind, rgb)
    }

    // MARK: - Profiles
    let profilesKey = "profiles"
    func loadProfiles() -> [String: Profile] {
        guard let d = UserDefaults.standard.data(forKey: profilesKey),
              let p = try? JSONDecoder().decode([String: Profile].self, from: d) else { return [:] }
        return p
    }
    func storeProfiles(_ p: [String: Profile]) {
        if let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: profilesKey) }
    }

    @objc func saveProfile() {
        guard mouse != nil, model.loadedOnce, model.busy == 0 else { return }
        let a = NSAlert(); a.messageText = "Save Profile"; a.informativeText = "Name for the current DPI steps, polling rate and lighting:"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24)); a.accessoryView = f
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = f.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.saveProfile(name)
    }

    @objc func loadProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        model.loadProfile(name)
    }

    @objc func deleteProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var all = loadProfiles(); all[name] = nil; storeProfiles(all)
    }

    // MARK: - Login item / privacy
    var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.davewoods.serpentis.plist")
    }
    @objc func toggleLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: launchAgentURL.path) {
            try? fm.removeItem(at: launchAgentURL)
        } else {
            try? fm.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist: [String: Any] = ["Label": "com.davewoods.serpentis",
                                        "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath, "--args", "--hidden"],
                                        "RunAtLoad": true]
            if let d = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? d.write(to: launchAgentURL)
            }
        }
    }
    @objc func openPrivacy() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(u) }
    }

    @objc func toggleAcceleration() { input.setDisableAcceleration(!input.disableAcceleration) }
    @objc func toggleScrollInversion() { input.setInvertScrolling(!input.invertScrolling) }
    @objc func openInputAccessibility() { input.openAccessibility() }
    func applicationWillTerminate(_ notification: Notification) { model.stopDockBatteryLighting(); model.pollingMonitor.stop(); troubleshooting.stopTest(); input.stop() }

    // MARK: - Window
    @objc func openWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Serpentis"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: ContentView().environmentObject(model).environmentObject(input).environmentObject(troubleshooting))
            w.setContentSize(NSSize(width: 980, height: 720))
            w.center()
            w.setFrameAutosaveName("SerpentisMain")
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if model.busy == 0 { model.refresh() }
    }
    @objc func openTroubleshooting() {
        model.selectedSection = .troubleshooting
        openWindow()
    }
    func windowWillClose(_ notification: Notification) {
        model.pollingMonitor.stop()
        troubleshooting.stopTest()
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow(); return true
    }
    func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Serpentis", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Serpentis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
    @objc func showAbout() { openWindow() }

    // MARK: - One-time move of settings from the old NagaControl app
    func migrateFromNagaControl() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromNagaControl") else { return }
        if let old = UserDefaults(suiteName: "com.davewoods.nagacontrol") {
            for key in ["profiles", "buttonLayouts", "autoLayoutWoW", "autoLayoutOther"] {
                if d.object(forKey: key) == nil, let v = old.object(forKey: key) { d.set(v, forKey: key) }
            }
        }
        let fm = FileManager.default
        let oldAgent = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.davewoods.nagacontrol.plist")
        if fm.fileExists(atPath: oldAgent.path) {
            try? fm.removeItem(at: oldAgent)
            if !fm.fileExists(atPath: launchAgentURL.path) { toggleLogin() }
        }
        d.set(true, forKey: "migratedFromNagaControl")
    }
}
