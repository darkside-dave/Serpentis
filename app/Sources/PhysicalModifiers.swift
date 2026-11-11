import CoreGraphics
import Foundation

struct ModifierPreferences: Codable, Equatable {
    var buttons: Set<UInt8> = []
    var layouts: [String: Set<UInt8>] = [:]
}

enum PhysicalModifier: UInt32, CaseIterable {
    case leftControl = 0xE0, leftShift, leftOption, leftCommand
    case rightControl, rightShift, rightOption, rightCommand

    var flags: CGEventFlags {
        switch self {
        case .leftControl, .rightControl: return .maskControl
        case .leftShift, .rightShift: return .maskShift
        case .leftOption, .rightOption: return .maskAlternate
        case .leftCommand, .rightCommand: return .maskCommand
        }
    }

    static let mask: CGEventFlags = [.maskControl, .maskShift, .maskAlternate, .maskCommand]
    // Quartz's device-dependent left/right modifier bits must not contradict the new flags.
    static let sideMask = CGEventFlags(rawValue: 0x0000201F | 0x00000060)

    static func configuredFlags(_ hidModifiers: UInt8) -> CGEventFlags {
        var flags: CGEventFlags = []
        if hidModifiers & 0x11 != 0 { flags.insert(.maskControl) }
        if hidModifiers & 0x22 != 0 { flags.insert(.maskShift) }
        if hidModifiers & 0x44 != 0 { flags.insert(.maskAlternate) }
        if hidModifiers & 0x88 != 0 { flags.insert(.maskCommand) }
        return flags
    }

    static func flags(forKeyCode keyCode: CGKeyCode) -> CGEventFlags {
        switch keyCode {
        case 0x3B, 0x3E: return .maskControl
        case 0x38, 0x3C: return .maskShift
        case 0x3A, 0x3D: return .maskAlternate
        case 0x37, 0x36: return .maskCommand
        default: return []
        }
    }
}

enum ModifierError: Error, LocalizedError, Equatable {
    case invalidAssignment(UInt8)
    case ambiguousKey(String)
    case permission
    case identification
    case keyboardState
    case interception
    case interrupted
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidAssignment(let id): return "Button \(id) needs a supported keyboard assignment for physical modifiers."
        case .ambiguousKey(let key):
            return "Several buttons emit \(key). They must all use the same physical-modifier option and fixed modifiers, because the mouse does not identify those buttons in its keyboard events."
        case .permission:
            return "Physical modifiers need Input Monitoring and Accessibility permission for Serpentis. Enable both in System Settings, then retry. No global keyboard fallback is used."
        case .identification:
            return "macOS did not provide a reliable mouse event identity. Physical-modifier filtering is unavailable; the keyboard will not be intercepted as a fallback."
        case .keyboardState: return "Could not read the physical keyboard modifier state. Physical-modifier filtering was not enabled."
        case .interception: return "Could not create the mouse keyboard-event filter. Check Accessibility and Input Monitoring permissions."
        case .interrupted: return "macOS interrupted the input filter. Physical modifiers are inactive; retry from the Buttons page."
        case .writeFailed: return "The mouse did not accept all button settings. Refresh and check its assignments before retrying."
        }
    }
}

struct ModifierConfiguration: Equatable {
    var keys: [CGKeyCode: CGEventFlags] = [:]

    init() {}

    init(assignments: [UInt8: [UInt8]], enabledButtons: Set<UInt8>) throws {
        let inverseKeys = Dictionary(uniqueKeysWithValues: macToHID.map { ($0.value, $0.key) })
        for id in enabledButtons {
            guard id != 1, let args = assignments[id], args.count == 10, args[1] == id,
                  args[3] == 2, let keyCode = inverseKeys[args[6]] else {
                throw ModifierError.invalidAssignment(id)
            }
            let modifiers = PhysicalModifier.configuredFlags(args[5])
            for (otherID, other) in assignments where other.count == 10 && other[3] == 2 && other[6] == args[6] {
                guard enabledButtons.contains(otherID),
                      PhysicalModifier.configuredFlags(other[5]) == modifiers else {
                    throw ModifierError.ambiguousKey(hidKeyName(args[6]))
                }
            }
            keys[keyCode] = modifiers
        }
    }
}

final class PhysicalModifierFilter {
    private(set) var configuration: ModifierConfiguration
    let targetSenderIDs: Set<UInt64>
    private var keyboards: [UInt64: Set<PhysicalModifier>] = [:]

    init(configuration: ModifierConfiguration, targetSenderIDs: Set<UInt64>) {
        self.configuration = configuration
        self.targetSenderIDs = targetSenderIDs
    }

    var physicalFlags: CGEventFlags {
        keyboards.values.reduce(into: CGEventFlags()) { flags, keys in
            for key in keys { flags.formUnion(key.flags) }
        }
    }

    func setModifier(_ modifier: PhysicalModifier, down: Bool, keyboard: UInt64, synthetic: Bool = false) {
        guard !synthetic, !targetSenderIDs.contains(keyboard) else { return }
        if down { keyboards[keyboard, default: []].insert(modifier) }
        else { keyboards[keyboard]?.remove(modifier) }
    }

    func removeKeyboard(_ keyboard: UInt64) {
        keyboards[keyboard] = nil
    }

    func disable() {
        configuration = ModifierConfiguration()
        keyboards.removeAll()
    }

    func process(_ event: CGEvent, type: CGEventType, senderID: UInt64?) throws {
        guard !configuration.keys.isEmpty else { return }
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else { return }
        guard event.getIntegerValueField(.eventSourceUnixProcessID) == 0 else { return }
        guard let senderID = senderID, senderID != 0 else { throw ModifierError.identification }
        guard targetSenderIDs.contains(senderID) else { return }
        event.flags = flags(type: type, keyCode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
                            original: event.flags, targetMouse: true, synthetic: false)
    }

    func flags(type: CGEventType, keyCode: CGKeyCode, original: CGEventFlags,
               targetMouse: Bool, synthetic: Bool) -> CGEventFlags {
        guard targetMouse, !synthetic else { return original }
        if type == .flagsChanged {
            let changed = PhysicalModifier.flags(forKeyCode: keyCode)
            if !changed.isEmpty, configuration.keys.values.contains(where: { !$0.intersection(changed).isEmpty }) {
                return original.union(physicalFlags)
            }
            return original
        }
        guard type == .keyDown || type == .keyUp, let configured = configuration.keys[keyCode] else { return original }
        return original.subtracting(PhysicalModifier.mask.union(PhysicalModifier.sideMask))
            .union(configured).union(physicalFlags)
    }
}
