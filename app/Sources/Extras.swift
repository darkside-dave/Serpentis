// Extras.swift - other buttons, power settings, separate X/Y DPI.
import AppKit

extension AppDelegate {
    // MARK: Other buttons
    func otherButtonsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(label("Saved in the mouse — works without this app"))
        menu.addItem(.separator())
        for b in RazerMouse.otherButtons {
            let cur = buttonCache[b.id]
            let isDefault = cur == b.factory
            let sub = NSMenu()
            sub.addItem(item("Default", #selector(otherDefault(_:)), tag: Int(b.id), checked: isDefault))
            sub.addItem(item("Choose Key…", #selector(otherChooseKey(_:)), tag: Int(b.id), checked: !isDefault && cur?[3] == 0x02))
            let mm = NSMenu()
            for (name, mb) in mouseButtonNames where mb != 1 {
                mm.addItem(item(name, #selector(otherMouse(_:)), rep: NSNumber(value: mb), tag: Int(b.id),
                                checked: !isDefault && cur?[3] == 0x01 && cur?[5] == mb))
            }
            let mi = submenu("Mouse Button", mm); mi.state = (!isDefault && cur?[3] == 0x01) ? .on : .off
            sub.addItem(mi)
            let shown = isDefault ? "Default" : describeButton(cur)
            menu.addItem(submenu("\(b.name):   \(shown)", sub))
        }
        menu.addItem(.separator())
        menu.addItem(item("Reset These to Default", #selector(resetOtherButtons)))
        return menu
    }

    func otherFactory(_ id: Int) -> [UInt8]? { RazerMouse.otherButtons.first { Int($0.id) == id }?.factory }
    func otherName(_ id: Int) -> String { RazerMouse.otherButtons.first { Int($0.id) == id }?.name ?? "Button" }

    @objc func otherDefault(_ s: NSMenuItem) { if let f = otherFactory(s.tag) { writeButton(f) } }

    @objc func otherMouse(_ s: NSMenuItem) {
        guard let mb = (s.representedObject as? NSNumber)?.uint8Value else { return }
        writeButton(RazerMouse.mouseArgs(UInt8(s.tag), button: mb))
    }

    @objc func otherChooseKey(_ s: NSMenuItem) {
        let a = NSAlert()
        a.messageText = otherName(s.tag)
        a.informativeText = "Click the box, then press the key or combination (for example ⇧F or ⌃3)."
        let v = KeyCaptureView(frame: NSRect(x: 0, y: 0, width: 260, height: 44))
        a.accessoryView = v
        let save = a.addButton(withTitle: "Save to Mouse"); save.keyEquivalent = ""
        let cancel = a.addButton(withTitle: "Cancel"); cancel.keyEquivalent = ""
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = v
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let k = v.hidKey else { message("No key was pressed", "Nothing was changed."); return }
        writeButton(RazerMouse.keyArgs(UInt8(s.tag), mod: v.hidMods, key: k))
    }

    @objc func resetOtherButtons() {
        guard let m = mouse else { return }
        var failed = 0
        for b in RazerMouse.otherButtons { if !m.setButton(b.factory) { failed += 1 } }
        loadButtons()
        if failed > 0 { message("\(failed) button(s) didn't reset", "Try again with the cable plugged in.") }
    }

    // MARK: Power
    func powerMenu() -> NSMenu {
        let menu = NSMenu()
        let sleep = mouse?.sleepTimer()
        let sm = NSMenu()
        for mins in [1, 2, 3, 5, 10, 15] {
            sm.addItem(item("\(mins) minute\(mins == 1 ? "" : "s")", #selector(setSleep(_:)), tag: mins * 60, checked: sleep == mins * 60))
        }
        let sleepTitle = sleep.map { $0 % 60 == 0 ? "\($0 / 60) min" : "\($0) sec" } ?? "?"
        menu.addItem(submenu("Sleep When Idle: \(sleepTitle)", sm))

        let lp = mouse?.lowPowerThreshold()
        let lm = NSMenu()
        for pct in [5, 10, 15, 20, 25] {
            let raw = UInt8((Double(pct) * 255 / 100).rounded())
            let on = lp.map { abs(Int($0) - Int(raw)) <= 1 } ?? false
            lm.addItem(item("At \(pct)% battery", #selector(setLowPower(_:)), tag: pct, checked: on))
        }
        let lpTitle = lp.map { "\(Int((Double($0) / 255 * 100).rounded()))%" } ?? "?"
        menu.addItem(submenu("Low-Power Mode: \(lpTitle)", lm))
        menu.addItem(label("Low-power mode dims lighting to save battery"))
        return menu
    }

    @objc func setSleep(_ s: NSMenuItem) {
        guard let m = mouse else { return }
        if !(m.setSleepTimer(s.tag) && m.sleepTimer() == s.tag) { message("The mouse didn't accept that", "Nothing was changed.") }
    }

    @objc func setLowPower(_ s: NSMenuItem) {
        guard let m = mouse else { return }
        let raw = UInt8((Double(s.tag) * 255 / 100).rounded())
        if !(m.setLowPowerThreshold(raw) && m.lowPowerThreshold() == raw) { message("The mouse didn't accept that", "Nothing was changed.") }
    }

    // MARK: Separate X / Y DPI
    @objc func customDPIXY() {
        guard let m = mouse else { return }
        let cur = m.dpi() ?? DPIStage(x: 1600, y: 1600)
        let a = NSAlert()
        a.messageText = "Custom DPI"
        a.informativeText = "X is left–right speed, Y is up–down speed (100–30000).\nThis lasts until you press the DPI button or pick a step."
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        func row(_ t: String, _ v: Int) -> NSTextField {
            let l = NSTextField(labelWithString: t); l.widthAnchor.constraint(equalToConstant: 24).isActive = true
            let f = NSTextField(string: "\(v)"); f.widthAnchor.constraint(equalToConstant: 100).isActive = true
            let r = NSStackView(views: [l, f]); r.orientation = .horizontal
            stack.addArrangedSubview(r)
            return f
        }
        let fx = row("X:", cur.x), fy = row("Y:", cur.y)
        stack.setFrameSize(stack.fittingSize)
        a.accessoryView = stack
        a.addButton(withTitle: "Apply"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = fx
        guard a.runModal() == .alertFirstButtonReturn,
              let x = Int(fx.stringValue.trimmingCharacters(in: .whitespaces)),
              let y = Int(fy.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
        let cx = max(100, min(30000, x)), cy = max(100, min(30000, y))
        if !(m.setDPI(cx, cy) && m.dpi() == DPIStage(x: cx, y: cy)) {
            message("The mouse didn't confirm that", "It may only accept certain steps. Try again or tell Claude.")
        }
    }
}
