// SideButtons.swift - hardware button remapping (saved in the mouse's own memory).
import AppKit

// macOS virtual key code -> USB HID key code
let macToHID: [UInt16: UInt8] = [
    0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09, 0x05: 0x0A, 0x04: 0x0B, 0x22: 0x0C,
    0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F, 0x2E: 0x10, 0x2D: 0x11, 0x1F: 0x12, 0x23: 0x13, 0x0C: 0x14, 0x0F: 0x15,
    0x01: 0x16, 0x11: 0x17, 0x20: 0x18, 0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B, 0x10: 0x1C, 0x06: 0x1D,
    0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22, 0x16: 0x23, 0x1A: 0x24, 0x1C: 0x25, 0x19: 0x26, 0x1D: 0x27,
    0x24: 0x28, 0x35: 0x29, 0x33: 0x2A, 0x30: 0x2B, 0x31: 0x2C, 0x1B: 0x2D, 0x18: 0x2E, 0x21: 0x2F, 0x1E: 0x30,
    0x2A: 0x31, 0x29: 0x33, 0x27: 0x34, 0x32: 0x35, 0x2B: 0x36, 0x2F: 0x37, 0x2C: 0x38,
    0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, 0x60: 0x3E, 0x61: 0x3F, 0x62: 0x40, 0x64: 0x41, 0x65: 0x42,
    0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45, 0x69: 0x68, 0x6B: 0x69, 0x71: 0x6A, 0x6A: 0x6B, 0x40: 0x6C, 0x4F: 0x6D,
    0x50: 0x6E, 0x5A: 0x6F,
    0x73: 0x4A, 0x74: 0x4B, 0x75: 0x4C, 0x77: 0x4D, 0x79: 0x4E, 0x7C: 0x4F, 0x7B: 0x50, 0x7D: 0x51, 0x7E: 0x52,
    0x47: 0x53, 0x4B: 0x54, 0x43: 0x55, 0x4E: 0x56, 0x45: 0x57, 0x4C: 0x58, 0x53: 0x59, 0x54: 0x5A, 0x55: 0x5B,
    0x56: 0x5C, 0x57: 0x5D, 0x58: 0x5E, 0x59: 0x5F, 0x5B: 0x60, 0x5C: 0x61, 0x52: 0x62, 0x41: 0x63, 0x51: 0x67,
]

func hidKeyName(_ k: UInt8) -> String {
    switch k {
    case 0x04...0x1D: return String(Character(UnicodeScalar(UInt8(65) + k - 0x04)))
    case 0x1E...0x26: return "\(k - 0x1D)"
    case 0x27: return "0"
    case 0x3A...0x45: return "F\(k - 0x39)"
    case 0x68...0x6F: return "F\(k - 0x68 + 13)"
    case 0x59...0x61: return "Num \(k - 0x58)"
    default:
        let names: [UInt8: String] = [0x28: "Return", 0x29: "Esc", 0x2A: "Delete", 0x2B: "Tab", 0x2C: "Space", 0x2D: "-",
            0x2E: "=", 0x2F: "[", 0x30: "]", 0x31: "\\", 0x33: ";", 0x34: "'", 0x35: "`", 0x36: ",", 0x37: ".", 0x38: "/",
            0x4A: "Home", 0x4B: "Page Up", 0x4C: "Fwd Delete", 0x4D: "End", 0x4E: "Page Down", 0x4F: "→", 0x50: "←",
            0x51: "↓", 0x52: "↑", 0x53: "Clear", 0x54: "Num /", 0x55: "Num *", 0x56: "Num -", 0x57: "Num +",
            0x58: "Num Enter", 0x62: "Num 0", 0x63: "Num .", 0x67: "Num ="]
        return names[k] ?? String(format: "Key 0x%02X", k)
    }
}

let mouseButtonNames: [(String, UInt8)] = [("Left Click", 1), ("Right Click", 2), ("Middle Click", 3), ("Back (Button 4)", 4), ("Forward (Button 5)", 5)]

func describeButton(_ a: [UInt8]?) -> String {
    guard let a = a, a.count >= 7 else { return "?" }
    switch a[3] {
    case 0x02:
        var parts: [String] = []
        let m = a[5]
        if m & 0x11 != 0 { parts.append("⌃") }
        if m & 0x44 != 0 { parts.append("⌥") }
        if m & 0x22 != 0 { parts.append("⇧") }
        if m & 0x88 != 0 { parts.append("⌘") }
        return parts.joined() + hidKeyName(a[6])
    case 0x01:
        return mouseButtonNames.first { $0.1 == a[5] }?.0 ?? "Mouse \(a[5])"
    case 0x00: return "Disabled"
    default: return String(format: "Special (0x%02X)", a[3])
    }
}

/// A box that records the next key combination pressed.
final class KeyCaptureView: NSView {
    var hidKey: UInt8?
    var hidMods: UInt8 = 0
    var onCapture: ((UInt8, UInt8) -> Void)?
    let label = NSTextField(labelWithString: "Press a key or combination…")
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        label.alignment = .center
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.frame = bounds.insetBy(dx: 8, dy: (bounds.height - 22) / 2)
        label.autoresizingMask = [.width]
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { capture(e) }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); DispatchQueue.main.async { self.window?.makeFirstResponder(self) } }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.type == .keyDown && window?.firstResponder === self { capture(e); return true }
        return false
    }
    func capture(_ e: NSEvent) {
        guard let k = macToHID[e.keyCode] else { label.stringValue = "That key isn't supported — try another"; return }
        var m: UInt8 = 0
        let f = e.modifierFlags
        if f.contains(.control) { m |= 0x01 }
        if f.contains(.shift) { m |= 0x02 }
        if f.contains(.option) { m |= 0x04 }
        if f.contains(.command) { m |= 0x08 }
        hidKey = k; hidMods = m
        onCapture?(k, m)
        label.stringValue = describeButton([0, 0, 0, 2, 2, m, k])
    }
}

extension AppDelegate {
    var layoutsKey: String { "buttonLayouts" }
    var autoWoWKey: String { "autoLayoutWoW" }
    var autoOtherKey: String { "autoLayoutOther" }

    func loadButtons() {
        guard let m = mouse else { return }
        for id in RazerMouse.sideButtonIDs + RazerMouse.otherButtons.map({ $0.id }) { if let a = m.button(id) { buttonCache[id] = a } }
    }

    func sideButtonsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(label("Saved in the mouse — works without this app"))
        menu.addItem(.separator())
        for (i, id) in RazerMouse.sideButtonIDs.enumerated() {
            let cur = buttonCache[id]
            let isDefault = cur.map { $0[3] == 0x02 && $0[5] == 0 && $0[6] == RazerMouse.defaultKeys[i] } ?? false
            let sub = NSMenu()
            sub.addItem(item("Default (\(hidKeyName(RazerMouse.defaultKeys[i])))", #selector(buttonDefault(_:)), tag: i, checked: isDefault))
            sub.addItem(item("Choose Key…", #selector(buttonChooseKey(_:)), tag: i, checked: !isDefault && cur?[3] == 0x02))
            let mm = NSMenu()
            for (name, b) in mouseButtonNames {
                mm.addItem(item(name, #selector(buttonMouse(_:)), rep: NSNumber(value: b), tag: i, checked: cur?[3] == 0x01 && cur?[5] == b))
            }
            let mi = submenu("Mouse Button", mm); mi.state = cur?[3] == 0x01 ? .on : .off
            sub.addItem(mi)
            menu.addItem(submenu("Button \(i + 1):   \(describeButton(cur))", sub))
        }
        menu.addItem(.separator())
        menu.addItem(item("Reset All to Default (1 – =)", #selector(resetAllButtons)))
        menu.addItem(.separator())

        // Layouts
        let layouts = loadLayouts()
        let lm = NSMenu()
        lm.addItem(item("Save Current Buttons as Layout…", #selector(saveLayout)))
        if !layouts.isEmpty {
            lm.addItem(.separator())
            lm.addItem(label("Load:"))
            for n in layouts.keys.sorted() { lm.addItem(item("    \(n)", #selector(loadLayout(_:)), rep: n)) }
            let dm = NSMenu()
            for n in layouts.keys.sorted() { dm.addItem(item(n, #selector(deleteLayout(_:)), rep: n)) }
            lm.addItem(.separator())
            lm.addItem(submenu("Delete Layout", dm))
        }
        menu.addItem(submenu("Layouts", lm))

        // Auto-switch
        let am = NSMenu()
        let wow = UserDefaults.standard.string(forKey: autoWoWKey)
        let other = UserDefaults.standard.string(forKey: autoOtherKey)
        am.addItem(item("Off", #selector(setAutoWoW(_:)), rep: "", checked: wow == nil))
        am.addItem(label("When WoW is in front, use:"))
        for n in layouts.keys.sorted() { am.addItem(item("    \(n)", #selector(setAutoWoW(_:)), rep: n, checked: wow == n)) }
        am.addItem(label("Otherwise use:"))
        am.addItem(item("    Default (1 – =)", #selector(setAutoOther(_:)), rep: "", checked: other == nil))
        for n in layouts.keys.sorted() { am.addItem(item("    \(n)", #selector(setAutoOther(_:)), rep: n, checked: other == n)) }
        if layouts.isEmpty { am.addItem(label("    (save a layout first)")) }
        menu.addItem(submenu("Auto-Switch for WoW", am))
        return menu
    }

    func writeButton(_ args: [UInt8]) {
        guard let m = mouse else { return }
        if m.setButton(args) {
            buttonCache[args[1]] = m.button(args[1]) ?? args
        } else {
            message("The mouse didn't accept that", "Nothing was changed. If you're on wireless, try with the cable plugged in and tell Claude.")
        }
    }

    @objc func buttonDefault(_ s: NSMenuItem) { writeButton(RazerMouse.defaultArgs(s.tag)) }

    @objc func buttonMouse(_ s: NSMenuItem) {
        guard let b = (s.representedObject as? NSNumber)?.uint8Value else { return }
        if b == 1 {
            let a = NSAlert(); a.messageText = "Make this side button a Left Click?"
            a.informativeText = "Your main left button keeps working either way."
            a.addButton(withTitle: "Yes"); a.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        writeButton(RazerMouse.mouseArgs(RazerMouse.sideButtonIDs[s.tag], button: b))
    }

    @objc func buttonChooseKey(_ s: NSMenuItem) {
        let i = s.tag
        let a = NSAlert()
        a.messageText = "Side Button \(i + 1)"
        a.informativeText = "Click the box, then press the key or combination (for example ⇧F or ⌃3)."
        let v = KeyCaptureView(frame: NSRect(x: 0, y: 0, width: 260, height: 44))
        a.accessoryView = v
        let save = a.addButton(withTitle: "Save to Mouse"); save.keyEquivalent = ""
        let cancel = a.addButton(withTitle: "Cancel"); cancel.keyEquivalent = ""
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = v
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let k = v.hidKey else { message("No key was pressed", "Nothing was changed."); return }
        writeButton(RazerMouse.keyArgs(RazerMouse.sideButtonIDs[i], mod: v.hidMods, key: k))
    }

    @objc func resetAllButtons() {
        guard let m = mouse else { return }
        var failed = 0
        for i in 0..<12 { if !m.setButton(RazerMouse.defaultArgs(i)) { failed += 1 } }
        loadButtons()
        if failed > 0 { message("\(failed) button(s) didn't reset", "Try again with the cable plugged in.") }
    }

    // MARK: Layouts
    func loadLayouts() -> [String: [[UInt8]]] {
        guard let d = UserDefaults.standard.data(forKey: layoutsKey),
              let l = try? JSONDecoder().decode([String: [[UInt8]]].self, from: d) else { return [:] }
        return l
    }
    func storeLayouts(_ l: [String: [[UInt8]]]) {
        if let d = try? JSONEncoder().encode(l) { UserDefaults.standard.set(d, forKey: layoutsKey) }
    }

    @objc func saveLayout() {
        guard mouse != nil else { return }
        let a = NSAlert(); a.messageText = "Save Button Layout"; a.informativeText = "Name for the current 12 side-button assignments:"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24)); a.accessoryView = f
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = f.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        loadButtons()
        var list = RazerMouse.sideButtonIDs.enumerated().map { buttonCache[$0.element] ?? RazerMouse.defaultArgs($0.offset) }
        list += RazerMouse.otherButtons.map { buttonCache[$0.id] ?? $0.factory }
        var all = loadLayouts(); all[name] = list; storeLayouts(all)
    }

    func applyLayout(_ list: [[UInt8]], completion: (() -> Void)? = nil) {
        guard let m = mouse else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for args in list where args.count == 10 { m.setButton(args) }
            DispatchQueue.main.async { self.loadButtons(); completion?() }
        }
    }

    @objc func loadLayout(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String, let l = loadLayouts()[n] else { return }
        applyLayout(l)
    }
    @objc func deleteLayout(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String else { return }
        var all = loadLayouts(); all[n] = nil; storeLayouts(all)
        if UserDefaults.standard.string(forKey: autoWoWKey) == n { UserDefaults.standard.removeObject(forKey: autoWoWKey) }
        if UserDefaults.standard.string(forKey: autoOtherKey) == n { UserDefaults.standard.removeObject(forKey: autoOtherKey) }
    }

    // MARK: Auto-switch
    @objc func setAutoWoW(_ s: NSMenuItem) {
        let n = s.representedObject as? String ?? ""
        if n.isEmpty { UserDefaults.standard.removeObject(forKey: autoWoWKey) } else { UserDefaults.standard.set(n, forKey: autoWoWKey) }
        lastAutoLayout = nil
    }
    @objc func setAutoOther(_ s: NSMenuItem) {
        let n = s.representedObject as? String ?? ""
        if n.isEmpty { UserDefaults.standard.removeObject(forKey: autoOtherKey) } else { UserDefaults.standard.set(n, forKey: autoOtherKey) }
        lastAutoLayout = nil
    }

    @objc func appActivated(_ note: Notification) {
        guard mouse != nil, let wowLayout = UserDefaults.standard.string(forKey: autoWoWKey),
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        let name = (app.localizedName ?? "").lowercased(), bid = (app.bundleIdentifier ?? "").lowercased()
        let isWoW = name.contains("world of warcraft") || name == "wow" || bid.contains("worldofwarcraft") || bid.contains("blizzard.wow")
        let target = isWoW ? wowLayout : (UserDefaults.standard.string(forKey: autoOtherKey) ?? "__default__")
        guard target != lastAutoLayout else { return }
        lastAutoLayout = target
        let list = target == "__default__" ? (0..<12).map { RazerMouse.defaultArgs($0) } : (loadLayouts()[target] ?? [])
        applyLayout(list)
    }
}
