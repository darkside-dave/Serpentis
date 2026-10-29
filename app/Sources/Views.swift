// Views.swift - the Serpentis main window (SwiftUI).
import SwiftUI
import AppKit

enum PaneSection: String, CaseIterable, Identifiable {
    case buttons = "Buttons", performance = "Performance", lighting = "Lighting", power = "Power", profiles = "Profiles", about = "About"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .buttons: return "square.grid.3x3"
        case .performance: return "speedometer"
        case .lighting: return "lightbulb"
        case .power: return "battery.75"
        case .profiles: return "person.crop.square"
        case .about: return "info.circle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: SerpentisModel
    @LocalState private var section: PaneSection? = .buttons

    var body: some View {
        NavigationSplitView {
            List(PaneSection.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180)
        } detail: {
            VStack(spacing: 0) {
                StatusBar()
                Divider()
                Group {
                    if section == .about {
                        AboutView()
                    } else if !model.connected {
                        Placeholder(icon: "cable.connector", title: "Naga V3 Pro not connected",
                                    text: "Plug in the mouse with the cable or the wireless receiver.")
                    } else if model.asleep {
                        Placeholder(icon: "moon.zzz", title: "Mouse is asleep", text: "Move the mouse to wake it, then click Refresh.")
                    } else if !model.loadedOnce {
                        ProgressView("Reading settings from the mouse…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        switch section ?? .buttons {
                        case .buttons: ButtonsView()
                        case .performance: PerformanceView()
                        case .lighting: LightingView()
                        case .power: PowerView()
                        case .profiles: ProfilesView()
                        case .about: AboutView()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 880, minHeight: 640)
        .alert("Serpentis", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
            Button("OK") { model.errorText = nil }
        } message: { Text(model.errorText ?? "") }
    }
}

struct Placeholder: View {
    let icon: String, title: String, text: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 48)).foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            Text(text).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: SerpentisModel
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "computermouse.fill").foregroundStyle(model.connected ? Color.accentColor : .secondary)
            Text(model.connected ? "Razer Naga V3 Pro — \(model.connection)" : "Not connected").font(.headline)
            Spacer()
            if model.busy > 0 { ProgressView().controlSize(.small) }
            if let b = model.battery {
                Label("\(b)%\(model.charging ? " · charging" : "")", systemImage: model.charging ? "battery.100.bolt" : batteryIcon(b))
                    .foregroundStyle(b < 15 && !model.charging ? .red : .primary)
            }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Re-read settings from the mouse")
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
    func batteryIcon(_ b: Int) -> String { b > 85 ? "battery.100" : b > 60 ? "battery.75" : b > 35 ? "battery.50" : b > 10 ? "battery.25" : "battery.0" }
}

struct PaneHeader: View {
    let title: String, subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Buttons

struct PadButton: View {
    @EnvironmentObject var model: SerpentisModel
    let slot: ButtonSlot
    @Binding var selected: UInt8
    var w: CGFloat = 46, h: CGFloat = 46
    var body: some View {
        let isSel = selected == slot.id
        let custom = !model.isDefault(slot)
        Button { selected = slot.id } label: {
            VStack(spacing: 3) {
                Text(slot.short).font(.system(size: 13, weight: .semibold))
                Circle().fill(custom ? Color.orange : Color.clear).frame(width: 5, height: 5)
            }
            .frame(width: w, height: h)
            .background(RoundedRectangle(cornerRadius: 9).fill(isSel ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(isSel ? Color.accentColor : Color.primary.opacity(0.25), lineWidth: isSel ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(slot.name): \(model.describe(slot))")
    }
}

struct MouseTopView: View {
    @Binding var selected: UInt8
    var body: some View {
        let s = SerpentisModel.slots
        ZStack {
            RoundedRectangle(cornerRadius: 75).fill(Color.primary.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 75).stroke(Color.primary.opacity(0.25), lineWidth: 1.5))
                .frame(width: 180, height: 290).position(x: 90, y: 145)
            Path { p in p.move(to: CGPoint(x: 90, y: 4)); p.addLine(to: CGPoint(x: 90, y: 40)) }
                .stroke(Color.primary.opacity(0.25), lineWidth: 1)
            Path { p in p.move(to: CGPoint(x: 90, y: 104)); p.addLine(to: CGPoint(x: 90, y: 115)) }
                .stroke(Color.primary.opacity(0.25), lineWidth: 1)
            Text("Left").font(.caption).foregroundStyle(.secondary).position(x: 42, y: 30)
            Text("Right").font(.caption).foregroundStyle(.secondary).position(x: 138, y: 30)
            PadButton(slot: s[13], selected: $selected, w: 28, h: 46).position(x: 52, y: 72)
            PadButton(slot: s[12], selected: $selected, w: 36, h: 62).position(x: 90, y: 72)
            PadButton(slot: s[14], selected: $selected, w: 28, h: 46).position(x: 128, y: 72)
            PadButton(slot: s[15], selected: $selected, w: 46, h: 30).position(x: 90, y: 136)
            Text("Top view").font(.caption2).foregroundStyle(.secondary).position(x: 90, y: 255)
        }
        .frame(width: 180, height: 290)
    }
}

struct SidePanelView: View {
    @Binding var selected: UInt8
    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { col in
                        PadButton(slot: SerpentisModel.slots[row * 3 + col], selected: $selected)
                    }
                }
            }
            Text("Side panel").font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.primary.opacity(0.25), lineWidth: 1.5))
    }
}

struct KeyCaptureRepresentable: NSViewRepresentable {
    var onCapture: (UInt8, UInt8) -> Void
    func makeNSView(context: Context) -> KeyCaptureView {
        let v = KeyCaptureView(frame: NSRect(x: 0, y: 0, width: 280, height: 44))
        v.onCapture = onCapture
        return v
    }
    func updateNSView(_ nsView: KeyCaptureView, context: Context) { nsView.onCapture = onCapture }
}

enum AssignMode: String, CaseIterable, Identifiable { case standard = "Default", key = "Keyboard Key", mouse = "Mouse Button"; var id: String { rawValue } }

struct ButtonEditor: View {
    @EnvironmentObject var model: SerpentisModel
    let slot: ButtonSlot
    @LocalState private var mode: AssignMode
    @LocalState private var key: UInt8?
    @LocalState private var mods: UInt8 = 0
    @LocalState private var mouseButton: UInt8

    init(slot: ButtonSlot, current: [UInt8]?, isDefault: Bool) {
        self.slot = slot
        var m: AssignMode = .standard
        var k: UInt8? = nil, md: UInt8 = 0, mb: UInt8 = 4
        if let c = current, !isDefault, c.count >= 7 {
            if c[3] == 0x02 { m = .key; k = c[6]; md = c[5] }
            else if c[3] == 0x01 { m = .mouse; mb = c[5] }
        }
        _mode = LocalState(wrappedValue: m); _key = LocalState(wrappedValue: k); _mods = LocalState(wrappedValue: md); _mouseButton = LocalState(wrappedValue: mb)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(slot.name).font(.title2.bold())
                    Spacer()
                    Text("Now: \(model.describe(slot))").foregroundStyle(.secondary)
                }
                Picker("", selection: $mode) { ForEach(AssignMode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                Group {
                    switch mode {
                    case .standard:
                        Text(slot.defaultText).foregroundStyle(.secondary)
                    case .key:
                        HStack(spacing: 14) {
                            KeyCaptureRepresentable { k, m in key = k; mods = m }.frame(width: 280, height: 44)
                            Text(key.map { describeButton([0, 0, 0, 2, 2, mods, $0]) } ?? "Click the box, then press a key or combination")
                                .foregroundStyle(.secondary)
                        }
                    case .mouse:
                        Picker("Mouse button:", selection: $mouseButton) {
                            ForEach([UInt8(2), 3, 4, 5], id: \.self) { b in
                                Text(mouseButtonNames.first { $0.1 == b }?.0 ?? "Button \(b)").tag(b)
                            }
                        }.frame(width: 300)
                    }
                }.frame(minHeight: 46, alignment: .leading)
                HStack {
                    Button("Save to Mouse") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(mode == .key && key == nil)
                    Text("Saved in the mouse's memory").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(10)
        }
    }

    func save() {
        switch mode {
        case .standard: model.setButton(slot.factory)
        case .key: if let k = key { model.setButton(RazerMouse.keyArgs(slot.id, mod: mods, key: k)) }
        case .mouse: model.setButton(RazerMouse.mouseArgs(slot.id, button: mouseButton))
        }
    }
}

struct LayoutsBox: View {
    @EnvironmentObject var model: SerpentisModel
    @LocalState private var name = ""
    var body: some View {
        GroupBox("Layouts") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("New layout name", text: $name).frame(width: 220)
                    Button("Save Current Buttons") {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        if !n.isEmpty { model.saveLayout(n); name = "" }
                    }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    Button("Reset All Buttons to Default") { model.resetAllButtons() }
                }
                if model.layoutNames.isEmpty {
                    Text("No saved layouts yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.layoutNames, id: \.self) { n in
                        HStack {
                            Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
                            Text(n)
                            Spacer()
                            Button("Load") { model.loadLayout(n) }
                            Button(role: .destructive) { model.deleteLayout(n) } label: { Image(systemName: "trash") }
                        }
                    }
                }
                Divider()
                Text("Auto-switch for World of Warcraft").font(.headline)
                HStack(spacing: 24) {
                    Picker("When WoW is in front:", selection: Binding(get: { model.autoWoW }, set: { model.autoWoW = $0 })) {
                        Text("Off").tag("")
                        ForEach(model.layoutNames, id: \.self) { Text($0).tag($0) }
                    }.frame(width: 300)
                    Picker("Otherwise:", selection: Binding(get: { model.autoOther }, set: { model.autoOther = $0 })) {
                        Text("Default (1 – =)").tag("")
                        ForEach(model.layoutNames, id: \.self) { Text($0).tag($0) }
                    }.frame(width: 260).disabled(model.autoWoW.isEmpty)
                }
            }.padding(10)
        }
    }
}

struct ButtonsView: View {
    @EnvironmentObject var model: SerpentisModel
    @LocalState private var selected: UInt8 = 0x40
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PaneHeader(title: "Buttons", subtitle: "Click a button to change it. Assignments are saved in the mouse and work even when Serpentis isn't running. An orange dot means a button has been changed.")
                HStack(alignment: .top, spacing: 40) {
                    MouseTopView(selected: $selected)
                    SidePanelView(selected: $selected)
                    Spacer()
                }
                let s = SerpentisModel.slot(selected)
                ButtonEditor(slot: s, current: model.buttons[s.id], isDefault: model.isDefault(s))
                    .id("\(selected)-\(model.buttons[s.id]?.description ?? "")")
                LayoutsBox()
            }.padding(24)
        }
    }
}

// MARK: - Performance

struct PerformanceView: View {
    @EnvironmentObject var model: SerpentisModel
    @LocalState private var values: [Int] = []
    @LocalState private var active = 1
    @LocalState private var x = 1600
    @LocalState private var y = 1600
    @LocalState private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PaneHeader(title: "Performance", subtitle: "DPI steps are what the DPI button cycles through. They're saved in the mouse.")
                HStack(spacing: 24) {
                    VStack(alignment: .leading) {
                        Text("Current DPI").foregroundStyle(.secondary)
                        Text(model.dpi.map { $0.x == $0.y ? "\($0.x)" : "\($0.x) × \($0.y)" } ?? "?").font(.system(size: 34, weight: .bold))
                    }
                    Spacer()
                }
                GroupBox("DPI Steps") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(values.indices, id: \.self) { i in
                            HStack(spacing: 12) {
                                Button { active = i + 1; model.selectStage(i + 1) } label: {
                                    Image(systemName: active == i + 1 ? "largecircle.fill.circle" : "circle")
                                }.buttonStyle(.plain).help("Use this step now")
                                Text("Step \(i + 1)").frame(width: 56, alignment: .leading)
                                Slider(value: Binding(get: { i < values.count ? Double(values[i]) : 100 }, set: { if i < values.count { values[i] = Int(($0 / 50).rounded() * 50) } }), in: 100...30000)
                                    .frame(width: 320)
                                TextField("", value: Binding(get: { i < values.count ? values[i] : 100 }, set: { if i < values.count { values[i] = max(100, min(30000, $0)) } }), format: .number)
                                    .frame(width: 80)
                                Button { values.remove(at: i); active = min(active, max(1, values.count)) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain).disabled(values.count <= 1)
                            }
                        }
                        HStack {
                            Button { values.append(min(30000, (values.last ?? 800) * 2)) } label: { Label("Add Step", systemImage: "plus.circle") }
                                .disabled(values.count >= 5)
                            Spacer()
                            Button("Revert") { load() }
                            Button("Save Steps to Mouse") { model.saveStages(values, active: active) }.buttonStyle(.borderedProminent)
                        }
                    }.padding(10)
                }
                GroupBox("Custom DPI (separate X and Y)") {
                    HStack(spacing: 12) {
                        Text("X (side to side)"); TextField("", value: $x, format: .number).frame(width: 80)
                        Text("Y (up and down)"); TextField("", value: $y, format: .number).frame(width: 80)
                        Button("Apply") { model.setDPI(x, y) }
                        Spacer()
                        Text("Lasts until you press the DPI button").font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }
                GroupBox("Polling Rate") {
                    HStack {
                        Picker("", selection: Binding(get: { model.polling ?? 1000 }, set: { model.setPolling($0) })) {
                            Text("125 Hz").tag(125); Text("500 Hz").tag(500); Text("1000 Hz").tag(1000)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 320)
                        Spacer()
                        Text("How often the mouse reports its position. 1000 Hz is smoothest.").font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }
            }.padding(24)
        }
        .onAppear { if !loaded { load(); loaded = true } }
        .onChange(of: model.stages) { _ in load() }
    }

    func load() {
        if let st = model.stages { values = st.stages.map { $0.x }; active = st.active }
        if let d = model.dpi { x = d.x; y = d.y }
    }
}

// MARK: - Lighting

struct ZoneEditor: View {
    @EnvironmentObject var model: SerpentisModel
    let title: String
    let zones: [Zone]
    @LocalState private var kind: EffectKind = .spectrum
    @LocalState private var color: Color = .red
    @LocalState private var brightness: Double = 33
    @LocalState private var loaded = false

    var body: some View {
        GroupBox(title) {
            HStack(alignment: .center, spacing: 20) {
                Picker("", selection: $kind) {
                    Text("Color Cycle").tag(EffectKind.spectrum)
                    Text("Solid").tag(EffectKind.staticColor)
                    Text("Breathing").tag(EffectKind.breathing)
                    Text("Off").tag(EffectKind.none)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 340)
                .onChange(of: kind) { k in if loaded { model.setEffect(zones, k, rgb(color)) } }
                ColorPicker("Color", selection: $color, supportsOpacity: false)
                    .disabled(!(kind == .staticColor || kind == .breathing))
                    .onChange(of: color) { c in if loaded && (kind == .staticColor || kind == .breathing) { model.scheduleColor(zones, kind, rgb(c)) } }
                HStack {
                    Image(systemName: "sun.min")
                    Slider(value: $brightness, in: 0...100, onEditingChanged: { editing in if !editing { model.setBrightness(zones, brightness) } })
                        .frame(width: 140)
                    Image(systemName: "sun.max")
                    Text("\(Int(brightness))%").frame(width: 40, alignment: .trailing).monospacedDigit()
                }.disabled(kind == .none)
                Spacer()
            }.padding(8)
        }
        .onAppear { load() }
    }

    func load() {
        loaded = false
        if let l = model.lights[zones[0]] {
            kind = l.brightness == 0 ? .none : (l.kind == .other ? .spectrum : l.kind)
            if let c = l.color { color = Color(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, opacity: 1) }
            brightness = (Double(l.brightness) / 255 * 100).rounded()
        }
        DispatchQueue.main.async { loaded = true }
    }
    func rgb(_ c: Color) -> RGB {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .red
        func b(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        return RGB(r: b(n.redComponent), g: b(n.greenComponent), b: b(n.blueComponent))
    }
}

struct LightingPreview: View {
    @EnvironmentObject var model: SerpentisModel
    func fill(_ z: Zone) -> AnyShapeStyle {
        guard let l = model.lights[z], l.brightness > 0 else { return AnyShapeStyle(Color.primary.opacity(0.08)) }
        let op = 0.35 + 0.65 * Double(l.brightness) / 255
        if let c = l.color { return AnyShapeStyle(Color(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, opacity: op)) }
        return AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center).opacity(op))
    }
    var body: some View {
        HStack(spacing: 40) {
            ZStack {
                RoundedRectangle(cornerRadius: 50).stroke(Color.primary.opacity(0.25), lineWidth: 1.5).frame(width: 110, height: 180)
                Capsule().fill(fill(.scrollWheel)).frame(width: 18, height: 36).offset(y: -55)
                Image(systemName: "seal.fill").font(.system(size: 30)).foregroundStyle(fill(.logo)).offset(y: 40)
            }
            VStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { _ in
                    HStack(spacing: 5) { ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 4).fill(fill(.sideButtons)).frame(width: 20, height: 20) } }
                }
            }.padding(10).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.25), lineWidth: 1.5))
            Text("Preview (approximate)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LightingView: View {
    @EnvironmentObject var model: SerpentisModel
    @LocalState private var linked = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PaneHeader(title: "Lighting", subtitle: "The Naga V3 Pro has three lighting zones.")
                LightingPreview()
                Toggle("Use the same lighting for all zones", isOn: $linked)
                if linked {
                    ZoneEditor(title: "All Zones", zones: Zone.allCases)
                } else {
                    ForEach(Zone.allCases, id: \.self) { z in ZoneEditor(title: z.name, zones: [z]) }
                }
            }.padding(24)
        }
    }
}

// MARK: - Power

struct PowerView: View {
    @EnvironmentObject var model: SerpentisModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PaneHeader(title: "Power", subtitle: "Battery and power-saving settings, saved in the mouse.")
                GroupBox {
                    HStack(spacing: 20) {
                        Image(systemName: model.charging ? "battery.100.bolt" : "battery.75").font(.system(size: 40))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(model.battery ?? 0)%").font(.system(size: 30, weight: .bold))
                            ProgressView(value: Double(model.battery ?? 0), total: 100).frame(width: 260)
                            Text(model.charging ? "Charging" : "On battery").foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(10)
                }
                GroupBox("Sleep When Idle") {
                    HStack {
                        Picker("", selection: Binding(get: { model.sleepSeconds ?? 300 }, set: { model.setSleep($0) })) {
                            ForEach([1, 2, 3, 5, 10, 15], id: \.self) { Text("\($0) minute\($0 == 1 ? "" : "s")").tag($0 * 60) }
                        }.labelsHidden().frame(width: 200)
                        Spacer()
                        Text("The mouse sleeps after this long without use, to save battery. Move it to wake it.").font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }
                GroupBox("Low-Power Mode") {
                    HStack {
                        Picker("", selection: Binding(get: { lowPercent }, set: { model.setLowPower($0) })) {
                            ForEach([5, 10, 15, 20, 25], id: \.self) { Text("At \($0)% battery").tag($0) }
                        }.labelsHidden().frame(width: 200)
                        Spacer()
                        Text("Below this level the mouse dims its lighting to last longer.").font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }
            }.padding(24)
        }
    }
    var lowPercent: Int {
        guard let r = model.lowPowerRaw else { return 5 }
        let p = Int((Double(r) / 255 * 100).rounded())
        return [5, 10, 15, 20, 25].min { abs($0 - p) < abs($1 - p) } ?? 5
    }
}

// MARK: - Profiles

struct ProfilesView: View {
    @EnvironmentObject var model: SerpentisModel
    @LocalState private var name = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PaneHeader(title: "Profiles", subtitle: "A profile stores DPI steps, polling rate and lighting in Serpentis, so you can switch setups quickly. Button assignments are saved separately as Layouts on the Buttons page.")
                GroupBox {
                    HStack {
                        TextField("New profile name", text: $name).frame(width: 240)
                        Button("Save Current Settings") {
                            let n = name.trimmingCharacters(in: .whitespaces)
                            if !n.isEmpty { model.saveProfile(n); name = "" }
                        }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                    }.padding(10)
                }
                if model.profileNames.isEmpty {
                    Text("No saved profiles yet.").foregroundStyle(.secondary)
                } else {
                    GroupBox {
                        VStack(spacing: 10) {
                            ForEach(model.profileNames, id: \.self) { n in
                                HStack {
                                    Image(systemName: "person.crop.square").foregroundStyle(.secondary)
                                    Text(n)
                                    Spacer()
                                    Button("Load") { model.loadProfile(n) }
                                    Button(role: .destructive) { model.deleteProfile(n) } label: { Image(systemName: "trash") }
                                }
                            }
                        }.padding(10)
                    }
                }
            }.padding(24)
        }
    }
}

// MARK: - About

struct AboutView: View {
    @EnvironmentObject var model: SerpentisModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "computermouse.fill").font(.system(size: 64)).foregroundStyle(Color.accentColor)
            Text("Serpentis").font(.system(size: 34, weight: .bold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")").foregroundStyle(.secondary)
            if model.connected && !model.firmware.isEmpty { Text("Mouse firmware \(model.firmware) · \(model.connection)").foregroundStyle(.secondary) }
            Text("Control for the Razer Naga V3 Pro on macOS — no Razer software needed.")
            HStack(spacing: 20) {
                Link("Project page & updates", destination: URL(string: "https://github.com/darkside-dave/Serpentis")!)
                Link("Support Serpentis on Ko-fi ☕", destination: URL(string: "https://ko-fi.com/darkside_dave")!)
            }.padding(.top, 6)
            Text("Unofficial. Not affiliated with, authorized or endorsed by Razer Inc.\nRazer and Naga are trademarks of Razer Inc., used only to identify compatible hardware.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
