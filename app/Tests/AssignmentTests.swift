import AppKit

struct AssignmentTests {
    func keyCaptureStoresExplicitModifiers() throws {
        let cases: [(NSEvent.ModifierFlags, UInt8)] = [
            ([], 0), (.control, 1), (.shift, 2), (.option, 4), (.command, 8),
            ([.control, .shift], 3), ([.control, .shift, .option, .command], 15),
            ([.capsLock, .numericPad], 0),
        ]
        for (flags, expected) in cases {
            let view = KeyCaptureView(frame: NSRect(x: 0, y: 0, width: 280, height: 44))
            var captures: [(UInt8, UInt8)] = []
            view.onCapture = { captures.append(($0, $1)) }
            let event = try require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: "1", charactersIgnoringModifiers: "1",
                isARepeat: false, keyCode: 0x12
            ))
            view.capture(event)
            try expect(captures.count == 1)
            try expect(captures.first?.0 == 0x1E)
            try expect(captures.first?.1 == expected)
            try expect(view.hidKey == 0x1E)
            try expect(view.hidMods == expected)
        }
    }

    func descriptionsDistinguishBareKeysAndShortcuts() throws {
        let cases: [(UInt8, String)] = [
            (0, "1"), (1, "⌃1"), (2, "⇧1"), (4, "⌥1"), (8, "⌘1"),
            (15, "⌃⌥⇧⌘1"), (0xF0, "⌃⌥⇧⌘1"),
        ]
        for (modifiers, expected) in cases {
            try expect(describeButton(RazerMouse.keyArgs(0x40, mod: modifiers, key: 0x1E)) == expected)
        }
        try expect(describeButton(RazerMouse.mouseArgs(0x40, button: 2)) == "Right Click")
        try expect(describeButton([0x01, 0x40, 0, 0, 0, 0, 0]) == "Disabled")
    }

    func defaultsAcceptBothKeyboardLengthEncodings() throws {
        let model = SerpentisModel()
        for slot in SerpentisModel.slots.prefix(12) {
            model.buttons[slot.id] = slot.factory
            try expect(model.isDefault(slot))
            model.buttons[slot.id] = RazerMouse.keyArgs(slot.id, mod: 0, key: slot.factory[6])
            try expect(model.isDefault(slot))
            model.buttons[slot.id] = RazerMouse.keyArgs(slot.id, mod: 1, key: slot.factory[6])
            try expect(!model.isDefault(slot))
            model.buttons[slot.id] = RazerMouse.mouseArgs(slot.id, button: 4)
            try expect(!model.isDefault(slot))
        }
    }

    func nonKeyboardDefaultsRemainDistinct() throws {
        let model = SerpentisModel()
        for slot in SerpentisModel.slots.dropFirst(12) {
            model.buttons[slot.id] = slot.factory
            try expect(model.isDefault(slot), slot.name)
            model.buttons[slot.id] = RazerMouse.keyArgs(slot.id, mod: 0, key: 0x1E)
            try expect(!model.isDefault(slot), slot.name)
        }
    }

    func dynamicOptionsMarkTheAssignmentAsCustomizedWithoutChangingHardwareData() throws {
        let model = SerpentisModel()
        let slot = SerpentisModel.slots[0]
        model.buttons[slot.id] = slot.factory
        try expect(model.isDefault(slot))
        model.physicalModifierButtons = [slot.id]
        try expect(!model.isDefault(slot))
        try expect(model.describe(slot).contains("physical modifiers"))
        try expect(model.buttons[slot.id] == slot.factory)
        model.physicalModifierButtons = []
        try expect(model.isDefault(slot))
    }

    func capturedAssignmentsAreNotTreatedAsKnownFactoryDefaults() throws {
        let captured = RazerMouse.keyArgs(0x50, mod: 1, key: 0x1E)
        let slot = ButtonSlot(id: 0x50, name: "Detected", short: "50", factory: captured,
                              defaultText: "Captured", factoryKnown: false)
        let model = SerpentisModel()
        model.buttons[slot.id] = captured
        try expect(model.isDefault(slot))
        model.buttons[slot.id] = RazerMouse.keyArgs(slot.id, mod: 0, key: 0x1E)
        try expect(!model.isDefault(slot))
        try expect(!model.describe(slot).contains("Default"))
    }
}
