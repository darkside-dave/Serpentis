// Model.swift - shared state for the Serpentis window. All mouse I/O runs on a background queue.
import SwiftUI
import Combine

struct ButtonSlot: Identifiable, Hashable {
    let id: UInt8
    let name: String
    let short: String
    let factory: [UInt8]
    let defaultText: String
}

final class SerpentisModel: ObservableObject {
    weak var app: AppDelegate?
    @Published var selectedSection: PaneSection? = .buttons
    @Published var connected = false
    @Published var connection = ""
    @Published var connectionIssue = ""
    @Published var asleep = false
    @Published var battery: Int?
    @Published var charging = false
    @Published var firmware = ""
    @Published var dpi: DPIStage?
    @Published var stages: DPIStageSet?
    @Published var polling: Int?
    @Published var lights: [Zone: ZoneLight] = [:]
    @Published var buttons: [UInt8: [UInt8]] = [:]
    @Published var sleepSeconds: Int?
    @Published var lowPowerRaw: UInt8?
    @Published var busy = 0
    @Published var errorText: String?
    @Published var loadedOnce = false
    @Published var layoutNames: [String] = []
    @Published var profileNames: [String] = []

    private let queue = DispatchQueue(label: "serpentis.io")
    private var pendingLight: DispatchWorkItem?
    private var refreshQueue = RefreshQueue()
    private var generation = 0

    static let slots: [ButtonSlot] = {
        var s: [ButtonSlot] = []
        for i in 0..<12 {
            s.append(ButtonSlot(id: RazerMouse.sideButtonIDs[i], name: "Side Button \(i + 1)", short: "\(i + 1)",
                                factory: RazerMouse.defaultArgs(i), defaultText: "Types \(hidKeyName(RazerMouse.defaultKeys[i]))"))
        }
        let shorts = ["Click", "◀", "▶", "Ring", "DPI+", "DPI−", "Mode", "Rear"]
        let texts = ["Middle click", "Scroll left", "Scroll right", "Built-in ring-finger function",
                     "DPI stage up", "DPI stage down", "Cycle wheel mode", "Disabled"]
        for (i, b) in RazerMouse.otherButtons.enumerated() {
            s.append(ButtonSlot(id: b.id, name: b.name, short: shorts[i], factory: b.factory, defaultText: texts[i]))
        }
        return s
    }()
    static func slot(_ id: UInt8) -> ButtonSlot { slots.first { $0.id == id } ?? slots[0] }

    func isDefault(_ s: ButtonSlot) -> Bool {
        guard let cur = buttons[s.id] else { return true }
        if cur == s.factory { return true }
        // a side button set to its own default key (with either length byte) counts as default
        return cur.count >= 7 && s.factory[3] == 0x02 && cur[3] == 0x02 && cur[5] == 0 && cur[6] == s.factory[6]
    }
    func describe(_ s: ButtonSlot) -> String {
        guard buttons[s.id] != nil else { return "…" }
        return isDefault(s) ? "Default (\(s.defaultText.lowercased()))" : describeButton(buttons[s.id])
    }

    // MARK: Refresh
    func deviceChanged() {
        generation += 1
        refreshQueue = RefreshQueue()
        busy = 0; loadedOnce = false; firmware = ""
        dpi = nil; stages = nil; polling = nil; lights = [:]; buttons = [:]
        sleepSeconds = nil; lowPowerRaw = nil; battery = nil; charging = false
        connected = app?.mouse != nil && app?.mouse?.productID != kMouseDockProPID; asleep = false
        connection = app?.mouse?.connectionName ?? ""
        connectionIssue = app?.openFailed == true ? "macOS blocked device access. Enable Serpentis in Input Monitoring, then quit and reopen it." : ""
    }

    func refresh(_ request: MouseRefreshRequest = .all) {
        reloadNames()
        guard let mouse = app?.mouse else {
            if connected { connected = false }
            if asleep { asleep = false }
            if battery != nil { battery = nil }
            return
        }
        guard let next = refreshQueue.enqueue(request) else { return }
        read(next, mouse: mouse, generation: generation)
    }

    private func read(_ request: MouseRefreshRequest, mouse: RazerMouse, generation: Int) {
        busy += 1
        queue.async {
            let snapshot = MouseSnapshot(mouse: mouse, request: request)
            DispatchQueue.main.async {
                guard self.generation == generation, self.app?.mouse === mouse else { return }
                self.busy -= 1
                self.apply(snapshot, request: request)
                if !self.loadedOnce, snapshot.supported, (snapshot.battery != nil || request == .identity), request != .all {
                    _ = self.refreshQueue.enqueue(.all)
                }
                if let next = self.refreshQueue.finish() { self.read(next, mouse: mouse, generation: generation) }
            }
        }
    }

    private func apply(_ value: MouseSnapshot, request: MouseRefreshRequest) {
        if let mouse = app?.mouse, mouse.productID == kMouseDockProPID {
            NagaDockRegistry.set(mouse.locationID, supported: value.supported)
            app?.input.devicesChanged()
        }
        if connected != value.supported { connected = value.supported }
        guard value.supported else {
            connectionIssue = "Mouse Dock Pro is connected, but it did not confirm a paired Naga V3 Pro. Wake the mouse and click Refresh."
            loadedOnce = false; buttons = [:]; lights = [:]; battery = nil
            dpi = nil; stages = nil; firmware = ""; polling = nil
            sleepSeconds = nil; lowPowerRaw = nil; charging = false
            app?.buttonCache = [:]; app?.lights = [:]; app?.updateBattery(nil, charging: false)
            return
        }
        if !connectionIssue.isEmpty { connectionIssue = "" }
        if request.fields.contains(.battery) {
            if battery != value.battery { battery = value.battery }
            if charging != value.charging { charging = value.charging }
            if asleep != (value.battery == nil) { asleep = value.battery == nil }
            app?.updateBattery(value.battery, charging: value.charging)
            guard value.battery != nil else { return }
        }
        if let v = value.firmware, firmware != v { firmware = v }
        if request.fields.contains(.performance) {
            if dpi != value.dpi { dpi = value.dpi }
            if stages != value.stages { stages = value.stages }
            if polling != value.polling { polling = value.polling }
        }
        if request.fields.contains(.lighting), lights != value.lights { lights = value.lights }
        var merged = buttons
        for (id, args) in value.buttons { merged[id] = args }
        if buttons != merged { buttons = merged }
        if request.fields.contains(.power) {
            if sleepSeconds != value.sleepSeconds { sleepSeconds = value.sleepSeconds }
            if lowPowerRaw != value.lowPowerRaw { lowPowerRaw = value.lowPowerRaw }
        }
        if request == .all, !loadedOnce { loadedOnce = true }
        app?.lights = lights; app?.buttonCache = buttons
    }

    func reloadNames() {
        let layouts = (app?.loadLayouts().keys.sorted()) ?? []
        let profiles = (app?.loadProfiles().keys.sorted()) ?? []
        if layoutNames != layouts { layoutNames = layouts }
        if profileNames != profiles { profileNames = profiles }
    }

    /// Serializes setting changes with background reads.
    func run(_ failure: String, refresh request: MouseRefreshRequest = .all, _ work: @escaping (RazerMouse) -> Bool) {
        guard let mouse = app?.mouse else { errorText = "The mouse isn't connected."; return }
        let generation = self.generation
        busy += 1
        queue.async {
            let ok = mouse.supportsNaga() && work(mouse)
            DispatchQueue.main.async {
                guard self.generation == generation, self.app?.mouse === mouse else { return }
                self.busy -= 1
                if !ok { self.errorText = failure }
                self.refresh(request)
            }
        }
    }

    // MARK: Buttons
    func setButton(_ args: [UInt8]) {
        run("The mouse did not confirm the saved assignment. Check the button in Troubleshooting before retrying.", refresh: MouseRefreshRequest(buttonIDs: args.count > 1 ? [args[1]] : [])) { $0.setButton(args) }
    }
    func resetAllButtons() {
        run("Some buttons didn't reset. Try again with the cable plugged in.", refresh: .buttons) { m in
            var ok = true
            for s in Self.slots { if !m.setButton(s.factory) { ok = false } }
            return ok
        }
    }

    // MARK: Layouts & auto-switch
    func saveLayout(_ name: String) {
        guard let app = app else { return }
        let list = Self.slots.map { buttons[$0.id] ?? $0.factory }
        var all = app.loadLayouts(); all[name] = list; app.storeLayouts(all)
        reloadNames()
    }
    func loadLayout(_ name: String) {
        guard let list = app?.loadLayouts()[name] else { return }
        run("Some buttons in that layout weren't accepted.", refresh: .buttons) { m in
            var ok = true
            for a in list where a.count == 10 { if !m.setButton(a) { ok = false } }
            return ok
        }
    }
    func deleteLayout(_ name: String) {
        guard let app = app else { return }
        var all = app.loadLayouts(); all[name] = nil; app.storeLayouts(all)
        if autoWoW == name { autoWoW = "" }
        if autoOther == name { autoOther = "" }
        reloadNames()
    }
    var autoWoW: String {
        get { UserDefaults.standard.string(forKey: "autoLayoutWoW") ?? "" }
        set {
            objectWillChange.send()
            if newValue.isEmpty { UserDefaults.standard.removeObject(forKey: "autoLayoutWoW") } else { UserDefaults.standard.set(newValue, forKey: "autoLayoutWoW") }
            app?.lastAutoLayout = nil
        }
    }
    var autoOther: String {
        get { UserDefaults.standard.string(forKey: "autoLayoutOther") ?? "" }
        set {
            objectWillChange.send()
            if newValue.isEmpty { UserDefaults.standard.removeObject(forKey: "autoLayoutOther") } else { UserDefaults.standard.set(newValue, forKey: "autoLayoutOther") }
            app?.lastAutoLayout = nil
        }
    }

    // MARK: Performance
    func selectStage(_ n: Int) {
        run("The mouse didn't accept that DPI step.", refresh: .performance) { m in
            guard var st = m.dpiStages(), n >= 1, n <= st.stages.count else { return false }
            st.active = n
            guard m.setDPIStages(st) else { return false }
            let s = st.stages[n - 1]
            return m.setDPI(s.x, s.y)
        }
    }
    func saveStages(_ values: [Int], active: Int) {
        let new = DPIStageSet(active: max(1, min(active, values.count)), stages: values.map { DPIStage(x: $0, y: $0) })
        run("The mouse didn't confirm the new DPI steps. Your old steps should still be in place.", refresh: .performance) { m in
            guard m.setDPIStages(new), m.dpiStages() == new else { return false }
            let s = new.stages[new.active - 1]
            return m.setDPI(s.x, s.y)
        }
    }
    func setDPI(_ x: Int, _ y: Int) {
        let cx = max(100, min(30000, x)), cy = max(100, min(30000, y))
        run("The mouse didn't confirm that DPI.", refresh: .performance) { m in m.setDPI(cx, cy) && m.dpi() == DPIStage(x: cx, y: cy) }
    }
    func setPolling(_ hz: Int) { run("The mouse didn't accept that polling rate.", refresh: .performance) { $0.setPollingRate(hz) } }

    // MARK: Lighting
    func setEffect(_ zones: [Zone], _ kind: EffectKind, _ color: RGB) {
        let before = lights
        run("The mouse didn't accept that lighting change.", refresh: .lighting) { m in
            var ok = true
            for z in zones {
                switch kind {
                case .spectrum: ok = m.setSpectrum(z) && ok
                case .staticColor: ok = m.setStatic(z, color) && ok
                case .breathing: ok = m.setBreathing(z, color) && ok
                case .none: ok = m.setBrightness(z, 0) && ok
                default: break
                }
                if kind != .none, (before[z]?.brightness ?? 0) == 0 { m.setBrightness(z, 128) }
            }
            return ok
        }
    }
    /// For color pickers: waits until the color stops changing briefly before sending it.
    func scheduleColor(_ zones: [Zone], _ kind: EffectKind, _ color: RGB) {
        pendingLight?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.setEffect(zones, kind, color) }
        pendingLight = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }
    func setBrightness(_ zones: [Zone], _ percent: Double) {
        let v = UInt8(max(0, min(255, (percent / 100 * 255).rounded())))
        run("The mouse didn't accept that brightness.", refresh: .lighting) { m in zones.allSatisfy { m.setBrightness($0, v) } }
    }

    // MARK: Power
    func setSleep(_ seconds: Int) { run("The mouse didn't accept that sleep time.", refresh: .power) { m in m.setSleepTimer(seconds) && m.sleepTimer() == seconds } }
    func setLowPower(_ percent: Int) {
        let raw = UInt8((Double(percent) * 255 / 100).rounded())
        run("The mouse didn't accept that setting.", refresh: .power) { m in m.setLowPowerThreshold(raw) && m.lowPowerThreshold() == raw }
    }

    // MARK: Profiles (stored in Serpentis)
    func saveProfile(_ name: String) {
        guard let app = app else { return }
        var ls: [String: ZoneLight] = [:]
        for (z, l) in lights { ls["\(z.rawValue)"] = l }
        var all = app.loadProfiles()
        all[name] = Profile(stages: stages, pollingRate: polling, lights: ls)
        app.storeProfiles(all)
        reloadNames()
    }
    func loadProfile(_ name: String) {
        guard let p = app?.loadProfiles()[name] else { return }
        run("Part of that profile wasn't accepted.") { m in
            var ok = true
            if let st = p.stages, st.active >= 1, st.active <= st.stages.count {
                ok = m.setDPIStages(st) && ok
                let s = st.stages[st.active - 1]; m.setDPI(s.x, s.y)
            }
            if let r = p.pollingRate { ok = m.setPollingRate(r) && ok }
            for z in Zone.allCases { if let l = p.lights["\(z.rawValue)"] { ok = m.restore(z, l) && ok } }
            return ok
        }
    }
    func deleteProfile(_ name: String) {
        guard let app = app else { return }
        var all = app.loadProfiles(); all[name] = nil; app.storeProfiles(all)
        reloadNames()
    }
}
