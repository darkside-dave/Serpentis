import CoreGraphics
import CryptoKit
import Foundation

enum ScrollDirection: String, Codable, CaseIterable, Identifiable {
    case standard = "Standard"
    case natural = "Natural"
    var id: String { rawValue }
    var isNatural: Bool { self == .natural }
}

struct ScrollSetting: Codable, Equatable {
    var enabled = false
    var direction: ScrollDirection = .standard
}

struct ScrollPreferences: Codable, Equatable {
    var devices: [String: ScrollSetting] = [:]
}

struct ScrollConfiguration: Equatable {
    let systemNatural: Bool
    let desiredNatural: Bool
    var shouldInvert: Bool { systemNatural != desiredNatural }
}

enum ScrollError: Error, LocalizedError, Equatable {
    case deviceIdentity
    case eventIdentity
    case permission
    case interception
    case interrupted
    case invalidDelta
    case systemPreference
    case preferencesUnavailable

    var errorDescription: String? {
        switch self {
        case .deviceIdentity:
            return "A stable mouse serial number could not be read. Per-mouse scrolling is unavailable; no model-wide fallback is used."
        case .eventIdentity:
            return "macOS did not provide the mouse event identity APIs. Custom scrolling is unavailable; unidentified events remain unchanged."
        case .permission:
            return "Custom scrolling needs Input Monitoring and Accessibility permission for Serpentis. Grant both in System Settings, then retry."
        case .interception:
            return "The modifiable scroll event tap could not be created. Check Input Monitoring and Accessibility permissions."
        case .interrupted:
            return "macOS interrupted custom scrolling. Events now follow the system setting; use Retry to enable it again."
        case .invalidDelta:
            return "A scroll delta could not be safely inverted. Custom scrolling has stopped without changing that event."
        case .systemPreference:
            return "The system natural-scrolling preference could not be read. Custom scrolling is inactive."
        case .preferencesUnavailable:
            return "Per-mouse scrolling preferences are unavailable. Retry after correcting the stored preferences."
        }
    }
}

func scrollDeviceIdentifier(serial: String) throws -> String {
    let serial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !serial.isEmpty, serial.utf8.allSatisfy({ (0x20...0x7E).contains($0) }),
          serial.contains(where: { $0 != "0" }) else { throw ScrollError.deviceIdentity }
    return SHA256.hash(data: Data("razer-naga:\(serial)".utf8))
        .map { String(format: "%02x", $0) }.joined()
}

struct SystemScrollPreference {
    static let key = "com.apple.swipescrolldirection"

    static func decode(_ value: Any?) throws -> Bool {
        // macOS uses natural scrolling when no explicit global preference exists.
        guard let value = value else { return true }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ScrollError.systemPreference
        }
        return number.boolValue
    }

    static func read() throws -> Bool {
        guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw ScrollError.systemPreference
        }
        return try decode(CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication,
                                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
    }
}

struct ScrollEventFilter {
    let targetSenderIDs: Set<UInt64>

    func process(_ event: CGEvent, senderID: UInt64?, configuration: ScrollConfiguration) throws {
        guard event.type == .scrollWheel, configuration.shouldInvert,
              event.getIntegerValueField(.eventSourceUnixProcessID) == 0,
              let senderID = senderID, senderID != 0, targetSenderIDs.contains(senderID) else { return }

        let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let pixels = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let fixed = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1)
        // Quartz line deltas are 16-bit; preserve the exact 32-bit 16.16 fraction.
        guard lines != Int64(Int16.min) else { throw ScrollError.invalidDelta }
        for value in [lines, pixels, fixed] {
            guard value != Int64.min, value != Int64(Int32.min) else { throw ScrollError.invalidDelta }
        }
        // Setting line deltas can recompute the other representations.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -lines)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -pixels)
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed)
    }
}

struct ScrollPreferencesStore {
    static let key = "mouseScrollPreferences"
    let defaults: UserDefaults

    func load() throws -> ScrollPreferences {
        guard let value = defaults.object(forKey: Self.key) else { return ScrollPreferences() }
        guard let data = value as? Data else { throw ScrollError.preferencesUnavailable }
        return try JSONDecoder().decode(ScrollPreferences.self, from: data)
    }

    func save(_ preferences: ScrollPreferences) throws {
        defaults.set(try JSONEncoder().encode(preferences), forKey: Self.key)
    }
}
