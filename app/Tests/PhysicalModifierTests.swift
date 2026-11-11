import CoreGraphics

struct PhysicalModifierTests {
    private let mouseID: UInt64 = 101
    private let keyboardID: UInt64 = 202

    private func filter(modifiers: UInt8 = 0) throws -> PhysicalModifierFilter {
        let configuration = try ModifierConfiguration(
            assignments: [0x40: RazerMouse.keyArgs(0x40, mod: modifiers, key: 0x1E)],
            enabledButtons: [0x40]
        )
        return PhysicalModifierFilter(configuration: configuration, targetSenderIDs: [mouseID])
    }

    private func event(_ type: CGEventType = .keyDown, keyCode: CGKeyCode = 0x12,
                       flags: CGEventFlags = [], repeating: Bool = false, pid: Int64 = 0) throws -> CGEvent {
        let source = try require(CGEventSource(stateID: .privateState))
        let event = try require(CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: type == .keyDown))
        event.type = type
        event.flags = flags
        event.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeating ? 1 : 0)
        return event
    }

    func allPhysicalModifierCombinations() throws {
        let inputs: [(PhysicalModifier, CGEventFlags)] = [
            (.leftControl, .maskControl), (.leftShift, .maskShift),
            (.leftOption, .maskAlternate), (.leftCommand, .maskCommand),
        ]
        for combination in 0..<16 {
            let filter = try filter()
            var expected: CGEventFlags = []
            for (index, input) in inputs.enumerated() where combination & (1 << index) != 0 {
                filter.setModifier(input.0, down: true, keyboard: keyboardID)
                expected.formUnion(input.1)
            }
            for type: CGEventType in [.keyDown, .keyUp] {
                let event = try event(type)
                try filter.process(event, type: type, senderID: mouseID)
                try expect(event.flags == expected, "combination \(combination), event \(type.rawValue)")
            }
        }
    }

    func fixedAndPhysicalModifiersAreUnited() throws {
        for explicit: UInt8 in [1, 0x10] {
            let filter = try filter(modifiers: explicit)
            filter.setModifier(.rightShift, down: true, keyboard: keyboardID)
            let event = try event(flags: [.maskCommand, .maskAlphaShift])
            try filter.process(event, type: .keyDown, senderID: mouseID)
            try expect(event.flags == [.maskControl, .maskShift, .maskAlphaShift])
        }
        let filter = try filter(modifiers: 15)
        filter.setModifier(.rightControl, down: true, keyboard: keyboardID)
        let event = try event()
        try filter.process(event, type: .keyDown, senderID: mouseID)
        try expect(event.flags == [.maskControl, .maskShift, .maskAlternate, .maskCommand])
    }

    func initialHeldModifiersAffectTheFirstPress() throws {
        let filter = try filter()
        filter.setModifier(.rightOption, down: true, keyboard: keyboardID)
        filter.setModifier(.leftCommand, down: true, keyboard: keyboardID)
        let event = try event()
        try filter.process(event, type: .keyDown, senderID: mouseID)
        try expect(event.flags == [.maskAlternate, .maskCommand])
    }

    func changesDuringHoldPreserveRepeatAndReleaseEvents() throws {
        let filter = try filter()
        let press = try event()
        try filter.process(press, type: .keyDown, senderID: mouseID)
        filter.setModifier(.leftControl, down: true, keyboard: keyboardID)
        let repeatWithControl = try event(repeating: true)
        try filter.process(repeatWithControl, type: .keyDown, senderID: mouseID)
        filter.setModifier(.leftControl, down: false, keyboard: keyboardID)
        let repeatWithoutControl = try event(repeating: true, pid: 0)
        try filter.process(repeatWithoutControl, type: .keyDown, senderID: mouseID)
        let release = try event(.keyUp)
        try filter.process(release, type: .keyUp, senderID: mouseID)
        let events = [press, repeatWithControl, repeatWithoutControl, release]
        try expect(events.map(\.flags) == [[], .maskControl, [], []])
        try expect(events.map(\.type) == [.keyDown, .keyDown, .keyDown, .keyUp])
        try expect(events.map { $0.getIntegerValueField(.keyboardEventAutorepeat) } == [0, 1, 1, 0])
        try expect(events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 0x12 })
    }

    func leftAndRightModifiersHaveIndependentLifetimes() throws {
        let pairs: [(PhysicalModifier, PhysicalModifier, CGEventFlags)] = [
            (.leftControl, .rightControl, .maskControl), (.leftShift, .rightShift, .maskShift),
            (.leftOption, .rightOption, .maskAlternate), (.leftCommand, .rightCommand, .maskCommand),
        ]
        for (left, right, expected) in pairs {
            for order in [[left, right], [right, left]] {
                let filter = try filter()
                for modifier in order { filter.setModifier(modifier, down: true, keyboard: keyboardID) }
                filter.setModifier(order[0], down: false, keyboard: keyboardID)
                let stillHeld = try event()
                try filter.process(stillHeld, type: .keyDown, senderID: mouseID)
                try expect(stillHeld.flags == expected)
                filter.setModifier(order[1], down: false, keyboard: keyboardID)
                let released = try event(.keyUp)
                try filter.process(released, type: .keyUp, senderID: mouseID)
                try expect(released.flags.isEmpty)
            }
        }
    }

    func simultaneousButtonsDoNotReleaseSharedPhysicalModifiers() throws {
        let configuration = try ModifierConfiguration(assignments: [
            0x40: RazerMouse.keyArgs(0x40, mod: 0, key: 0x1E),
            0x41: RazerMouse.keyArgs(0x41, mod: 0, key: 0x1F),
        ], enabledButtons: [0x40, 0x41])
        let filter = PhysicalModifierFilter(configuration: configuration, targetSenderIDs: [mouseID])
        filter.setModifier(.leftControl, down: true, keyboard: keyboardID)
        let events = try [
            event(), event(keyCode: 0x13), event(.keyUp),
            event(keyCode: 0x13, repeating: true), event(.keyUp, keyCode: 0x13),
        ]
        for event in events {
            try filter.process(event, type: event.type, senderID: mouseID)
            try expect(event.flags == .maskControl)
        }
        try expect(filter.physicalFlags == .maskControl)
        try expect(events.map(\.type) == [.keyDown, .keyDown, .keyUp, .keyDown, .keyUp])
    }

    func mouseAndSyntheticModifiersAreNotPhysicalState() throws {
        let filter = try filter()
        filter.setModifier(.leftControl, down: true, keyboard: mouseID)
        filter.setModifier(.leftShift, down: true, keyboard: keyboardID, synthetic: true)
        let synthetic = try event(.flagsChanged, keyCode: 0x37, flags: .maskCommand, pid: 99)
        try filter.process(synthetic, type: .flagsChanged, senderID: nil)
        try expect(filter.physicalFlags.isEmpty)
        let mouse = try event()
        try filter.process(mouse, type: .keyDown, senderID: mouseID)
        try expect(mouse.flags.isEmpty)
    }

    func syntheticKeyboardEventsAreUntouched() throws {
        let filter = try filter()
        filter.setModifier(.leftControl, down: true, keyboard: keyboardID)
        for type: CGEventType in [.keyDown, .keyUp, .flagsChanged] {
            let event = try event(type, flags: .maskAlternate, repeating: true, pid: 123)
            try filter.process(event, type: type, senderID: nil)
            try expect(event.flags == .maskAlternate)
            try expect(event.getIntegerValueField(.eventSourceUnixProcessID) == 123)
            try expect(event.getIntegerValueField(.keyboardEventAutorepeat) == 1)
        }
    }

    func physicalKeyboardAndOtherDevicesAreUntouchedEvenForTheSameKey() throws {
        let filter = try filter()
        filter.setModifier(.leftControl, down: true, keyboard: keyboardID)
        for sender in [keyboardID, 303] {
            for type: CGEventType in [.keyDown, .keyUp, .flagsChanged] {
                let event = try event(type, flags: [.maskCommand, .maskAlphaShift], repeating: true)
                try filter.process(event, type: type, senderID: sender)
                try expect(event.flags == [.maskCommand, .maskAlphaShift])
                try expect(event.type == type)
                try expect(event.getIntegerValueField(.keyboardEventKeycode) == 0x12)
                try expect(event.getIntegerValueField(.keyboardEventAutorepeat) == 1)
            }
        }
    }

    func unconfiguredMouseKeysKeepTheirFixedBehavior() throws {
        let filter = try filter()
        filter.setModifier(.leftControl, down: true, keyboard: keyboardID)
        for type: CGEventType in [.keyDown, .keyUp] {
            let event = try event(type, keyCode: 0x13, flags: .maskShift)
            try filter.process(event, type: type, senderID: mouseID)
            try expect(event.flags == .maskShift)
        }
    }

    func allRemappableCategoriesUseTheSameFilter() throws {
        let ids = RazerMouse.sideButtonIDs + RazerMouse.otherButtons.map(\.id) + RazerMouse.discoverableButtonIDs
        for id in ids {
            let configuration = try ModifierConfiguration(
                assignments: [id: RazerMouse.keyArgs(id, mod: 0, key: 0x1E)], enabledButtons: [id]
            )
            let filter = PhysicalModifierFilter(configuration: configuration, targetSenderIDs: [mouseID])
            filter.setModifier(.leftOption, down: true, keyboard: keyboardID)
            let pulse = try [event(), event(.keyUp)]
            for event in pulse { try filter.process(event, type: event.type, senderID: mouseID) }
            try expect(pulse.map(\.flags) == [.maskAlternate, .maskAlternate], "button \(id)")
            try expect(pulse.map(\.type) == [.keyDown, .keyUp])
            try expect(pulse.allSatisfy { $0.getIntegerValueField(.keyboardEventAutorepeat) == 0 })
        }
    }

    func ambiguousHardwareOutputsAreRejected() throws {
        let assignments = [
            UInt8(0x40): RazerMouse.keyArgs(0x40, mod: 0, key: 0x1E),
            UInt8(0x41): RazerMouse.keyArgs(0x41, mod: 0, key: 0x1E),
        ]
        try expectModifierError(.ambiguousKey("1")) {
            _ = try ModifierConfiguration(assignments: assignments, enabledButtons: [0x40])
        }
        let shared = try ModifierConfiguration(assignments: assignments, enabledButtons: [0x40, 0x41])
        let filter = PhysicalModifierFilter(configuration: shared, targetSenderIDs: [mouseID])
        filter.setModifier(.rightCommand, down: true, keyboard: keyboardID)
        let event = try event()
        try filter.process(event, type: .keyDown, senderID: mouseID)
        try expect(event.flags == .maskCommand)
        var differentModifiers = assignments
        differentModifiers[0x41] = RazerMouse.keyArgs(0x41, mod: 1, key: 0x1E)
        try expectModifierError(.ambiguousKey("1")) {
            _ = try ModifierConfiguration(assignments: differentModifiers, enabledButtons: [0x40, 0x41])
        }
    }

    func leftClickAndNonKeyboardActionsCannotEnableTheOption() throws {
        let cases: [(UInt8, [UInt8])] = [
            (1, RazerMouse.keyArgs(1, mod: 0, key: 0x1E)),
            (0x40, RazerMouse.mouseArgs(0x40, button: 2)),
            (0x40, [1, 0x40, 0, 0, 0, 0, 0, 0, 0, 0]),
            (0x40, RazerMouse.keyArgs(0x40, mod: 0, key: 0xFF)),
        ]
        for (id, args) in cases {
            try expectModifierError(.invalidAssignment(id)) {
                _ = try ModifierConfiguration(assignments: [id: args], enabledButtons: [id])
            }
            let fixed = try ModifierConfiguration(assignments: [id: args], enabledButtons: [])
            try expect(fixed.keys.isEmpty)
        }
    }

    func missingIdentityDoesNotBecomeGlobalInterception() throws {
        let filter = try filter()
        filter.setModifier(.leftControl, down: true, keyboard: keyboardID)
        let event = try event(flags: .maskAlternate)
        try expectModifierError(.identification) {
            try filter.process(event, type: .keyDown, senderID: nil)
        }
        try expect(event.flags == .maskAlternate)
    }

    func mouseModifierReleaseDoesNotClearAPhysicallyHeldModifier() throws {
        let filter = try filter(modifiers: 1)
        filter.setModifier(.leftControl, down: true, keyboard: keyboardID)
        filter.setModifier(.rightControl, down: true, keyboard: keyboardID)
        filter.setModifier(.leftControl, down: false, keyboard: keyboardID)
        let release = try event(.flagsChanged, keyCode: 0x3B)
        try filter.process(release, type: .flagsChanged, senderID: mouseID)
        try expect(release.flags == .maskControl)
        try expect(release.type == .flagsChanged)
        try expect(release.getIntegerValueField(.keyboardEventKeycode) == 0x3B)
    }

    func keyboardDisconnectionOnlyRemovesThatKeyboard() throws {
        let filter = try filter()
        filter.setModifier(.leftControl, down: true, keyboard: keyboardID)
        filter.setModifier(.rightControl, down: true, keyboard: 303)
        filter.removeKeyboard(keyboardID)
        let stillHeld = try event()
        try filter.process(stillHeld, type: .keyDown, senderID: mouseID)
        try expect(stillHeld.flags == .maskControl)
        filter.removeKeyboard(303)
        let released = try event(.keyUp)
        try filter.process(released, type: .keyUp, senderID: mouseID)
        try expect(released.flags.isEmpty)
    }

    func stoppingDuringHoldDoesNotInventKeyOrModifierReleases() throws {
        let filter = try filter(modifiers: 2)
        filter.setModifier(.leftControl, down: true, keyboard: keyboardID)
        let down = try event()
        try filter.process(down, type: .keyDown, senderID: mouseID)
        try expect(down.flags == [.maskControl, .maskShift])
        filter.disable()
        let up = try event(.keyUp, flags: .maskShift)
        try filter.process(up, type: .keyUp, senderID: nil)
        try expect(up.flags == .maskShift)
        try expect(up.type == .keyUp)
        try expect(filter.physicalFlags.isEmpty)
    }

    func mouseAndScrollActionsAreNotTransformed() throws {
        let filter = try filter()
        filter.setModifier(.leftControl, down: true, keyboard: keyboardID)
        for type: CGEventType in [.rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel] {
            let event = try event(type, flags: .maskAlternate)
            try filter.process(event, type: type, senderID: nil)
            try expect(event.flags == .maskAlternate)
            try expect(event.type == type)
        }
    }
}
