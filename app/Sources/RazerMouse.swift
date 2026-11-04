// RazerMouse.swift - Naga V3 Pro feature-report protocol.
import Foundation
import IOKit
import IOKit.hid

let kRazerVID = 0x1532
let kMouseDockProPID = 0x00A4
let kNagaPIDs: [Int: String] = [0x00E7: "Cable", 0x00E8: "Wireless"]

enum NagaTransport {
    static let products = Array(kNagaPIDs.keys) + [kMouseDockProPID]
    static func settingsUsage(_ product: Int) -> Int { product == kMouseDockProPID ? 2 : 3 }
    static func priority(_ product: Int) -> Int { product == 0xE7 ? 0 : product == 0xE8 ? 1 : 2 }

    static func pairedNaga(_ report: [UInt8]) -> Bool {
        guard report.count == 90, report[0] == 2, report[1] == 0x3F,
              report[6] == 0, report[7] == 0xBF, report[8] > 0,
              report[8] <= 26, Int(report[5]) >= 1 + 3 * Int(report[8]) else { return false }
        return kNagaPIDs[Int(report[10]) << 8 | Int(report[11])] != nil
    }
}

// Dock interfaces share a USB location; authorize them only after checking the paired PID.
enum NagaDockRegistry {
    private static let lock = NSLock()
    private static var locations: Set<Int> = []
    static func set(_ location: Int, supported: Bool) {
        lock.lock(); defer { lock.unlock() }
        if supported && location != 0 { locations.insert(location) } else { locations.remove(location) }
    }
    static func supports(vendor: Int, product: Int, location: Int = 0) -> Bool {
        guard vendor == kRazerVID else { return false }
        if kNagaPIDs[product] != nil { return true }
        lock.lock(); defer { lock.unlock() }
        return product == kMouseDockProPID && location != 0 && locations.contains(location)
    }
}

enum Zone: UInt8, CaseIterable, Codable {
    case scrollWheel = 0x01, logo = 0x04, sideButtons = 0x05
    var name: String {
        switch self {
        case .scrollWheel: return "Scroll Wheel"
        case .logo: return "Logo"
        case .sideButtons: return "Side Buttons"
        }
    }
}

enum EffectKind { case none, staticColor, breathing, spectrum, other }

struct DPIStage: Codable, Equatable { var x: Int; var y: Int }
struct DPIStageSet: Codable, Equatable { var active: Int; var stages: [DPIStage] }

struct RGB: Codable, Equatable { var r: UInt8; var g: UInt8; var b: UInt8 }

struct ZoneLight: Codable, Equatable {
    var effect: [UInt8]      // raw effect bytes as read from the mouse
    var brightness: UInt8
    var kind: EffectKind {
        guard effect.count > 2 else { return .other }
        switch effect[2] {
        case 0x00: return .none
        case 0x01: return .staticColor
        case 0x02: return .breathing
        case 0x03: return .spectrum
        default: return .other
        }
    }
    var color: RGB? {
        guard effect.count >= 9, kind == .staticColor || kind == .breathing else { return nil }
        return RGB(r: effect[6], g: effect[7], b: effect[8])
    }
}

enum DockEffect: String, CaseIterable {
    case staticColor = "Solid", breathing = "Breathing", spectrum = "Color Cycle"
    case waveForward = "Wave Forward", waveReverse = "Wave Reverse", battery = "Battery Level", off = "Off"
    var usesColor: Bool { self == .staticColor || self == .breathing }
    var id: UInt8 {
        switch self {
        case .off: return 0
        case .staticColor, .battery: return 1
        case .breathing: return 2
        case .spectrum: return 3
        case .waveForward, .waveReverse: return 4
        }
    }
    func arguments(_ color: RGB) -> [UInt8] {
        switch self {
        case .staticColor, .battery: return [1, 0, 1, 0, 0, 1, color.r, color.g, color.b]
        case .breathing: return [1, 0, 2, 1, 0, 1, color.r, color.g, color.b]
        case .waveForward, .waveReverse: return [1, 0, 4, self == .waveForward ? 1 : 2, 0x28, 0]
        case .spectrum, .off: return [1, 0, id, 0, 0, 0]
        }
    }
    static func decode(_ light: ZoneLight) -> Self? {
        guard light.effect.count >= 4 else { return nil }
        switch light.effect[2] {
        case 0: return .off
        case 1: return .staticColor
        case 2: return .breathing
        case 3: return .spectrum
        case 4: return light.effect[3] == 2 ? .waveReverse : .waveForward
        default: return nil
        }
    }
    func matches(_ light: ZoneLight, color: RGB, brightness: UInt8) -> Bool {
        Self.decode(light) == (self == .battery ? .staticColor : self) && light.brightness == brightness && (!(usesColor || self == .battery) || light.color == color)
    }
}

enum WheelMode: UInt8, CaseIterable {
    case tactile = 0, freeSpin = 1, precisionTactile = 2
    var name: String {
        switch self {
        case .tactile: return "Tactile"
        case .freeSpin: return "Free Spin"
        case .precisionTactile: return "Precision Tactile"
        }
    }
}

enum WheelProtocol {
    static func smartReelArguments(_ enabled: Bool) -> [UInt8] {
        [1, enabled ? 1 : 0] + [UInt8](repeating: 0, count: 78)
    }
    static func confirm(mode: WheelMode, read: () -> WheelMode?,
                        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                        pause: () -> Void = { usleep(100_000) }) -> Bool {
        let deadline = now() + 2.5
        repeat {
            if read() == mode { return true }
            pause()
        } while now() < deadline
        return false
    }
    static func boolean(_ value: UInt8) -> Bool? {
        value == 0 ? false : value == 1 ? true : nil
    }
}

enum PollingProtocol {
    static let standardRates = [125, 500, 1000]
    static let dockRates = [125, 250, 500, 1000, 2000, 4000, 8000]
    static let standardCodes: [Int: UInt8] = [125: 8, 500: 2, 1000: 1]
    static let dockCodes: [Int: UInt8] = [125: 0x40, 250: 0x20, 500: 0x10, 1000: 8, 2000: 4, 4000: 2, 8000: 1]
    static func decode(_ code: UInt8, extended: Bool) -> Int? {
        (extended ? dockCodes : standardCodes).first { $0.value == code }?.key
    }
}

private func hi(_ v: Int) -> UInt8 { UInt8((v >> 8) & 0xFF) }
private func lo(_ v: Int) -> UInt8 { UInt8(v & 0xFF) }

final class RazerMouse {
    let device: IOHIDDevice
    let productID: Int
    let locationID: Int
    private let txn: UInt8 = 0x1F
    private let lock = NSLock()
    private let batteryLock = NSLock()
    private var batteryCache = BatteryTelemetryCache()
    var connectionName: String { productID == kMouseDockProPID ? "Mouse Dock Pro" : kNagaPIDs[productID] ?? "USB" }

    init?(device: IOHIDDevice) {
        self.device = device
        self.locationID = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int) ?? 0
        self.productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
    }
    deinit { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

    // MARK: - Protocol
    private func makeReport(_ cls: UInt8, _ cmd: UInt8, _ size: UInt8, _ args: [UInt8], transaction: UInt8) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 90)
        r[1] = transaction; r[5] = size; r[6] = cls; r[7] = cmd
        for (i, a) in args.prefix(80).enumerated() { r[8 + i] = a }
        var crc: UInt8 = 0
        for i in 2..<88 { crc ^= r[i] }
        r[88] = crc
        return r
    }

    /// Sends a command and returns the reply if the mouse answered "OK".
    func query(_ cls: UInt8, _ cmd: UInt8, size: UInt8, args: [UInt8] = [], acceptUnsupported: Bool = false) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        if productID == kMouseDockProPID, cmd < 0x80, !checkPairedMouse() { return nil }
        return exchange(cls, cmd, size: size, args: args, transaction: txn, acceptUnsupported: acceptUnsupported)
    }

    func supportsNaga() -> Bool {
        guard productID == kMouseDockProPID else { return kNagaPIDs[productID] != nil }
        lock.lock(); defer { lock.unlock() }
        return checkPairedMouse()
    }

    private func checkPairedMouse() -> Bool {
        guard let reply = exchange(0, 0xBF, size: 0x1F, args: [], transaction: 0x3F) else { return false }
        return NagaTransport.pairedNaga(reply)
    }

    private func exchange(_ cls: UInt8, _ cmd: UInt8, size: UInt8, args: [UInt8], transaction: UInt8, acceptUnsupported: Bool = false) -> [UInt8]? {
        var buf = makeReport(cls, cmd, size, args, transaction: transaction)
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, &buf, buf.count) == kIOReturnSuccess else { return nil }
        usleep(45_000)
        for _ in 0..<20 {
            var out = [UInt8](repeating: 0, count: 90)
            var len = CFIndex(90)
            guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, &out, &len) == kIOReturnSuccess else { return nil }
            if out[0] == 0x00 || out[0] == 0x01 || out[1] != transaction || out[6] != cls || out[7] != cmd { usleep(25_000); continue }
            guard len == 90 else { return nil }
            return out[0] == 0x02 || (acceptUnsupported && out[0] == 0x05) ? out : nil
        }
        return nil
    }

    // MARK: - Info
    func firmware() -> String? {
        guard let r = query(0x00, 0x81, size: 0x02) else { return nil }
        return "\(r[8]).\(String(format: "%02d", r[9]))"
    }
    private func batteryTelemetry() -> BatteryTelemetry? {
        batteryLock.lock(); defer { batteryLock.unlock() }
        let time = ProcessInfo.processInfo.systemUptime
        if batteryCache.needsRead(at: time) {
            var telemetry: BatteryTelemetry?
            if let r = query(0x07, 0x80, size: 0x02) {
                let level = Int((Double(r[9]) / 255.0 * 100.0).rounded())
                let charging = query(0x07, 0x84, size: 0x02).map { $0[9] == 1 }
                telemetry = BatteryTelemetry(level: level, charging: charging)
            }
            batteryCache.record(telemetry, at: ProcessInfo.processInfo.systemUptime)
        }
        return batteryCache.value
    }
    func battery() -> Int? { batteryTelemetry()?.level }
    func isCharging() -> Bool? { batteryTelemetry()?.charging }

    // MARK: - DPI
    func dpi() -> DPIStage? {
        guard let r = query(0x04, 0x85, size: 0x07, args: [0x00]) else { return nil }
        return DPIStage(x: Int(r[9]) << 8 | Int(r[10]), y: Int(r[11]) << 8 | Int(r[12]))
    }
    @discardableResult
    func setDPI(_ x: Int, _ y: Int) -> Bool {
        let x = max(100, min(30000, x)), y = max(100, min(30000, y))
        return query(0x04, 0x05, size: 0x07, args: [0x00, hi(x), lo(x), hi(y), lo(y), 0, 0]) != nil
    }
    func dpiStages() -> DPIStageSet? {
        guard let r = query(0x04, 0x86, size: 0x26, args: [0x01]) else { return nil }
        let count = min(Int(r[10]), 5)
        var stages: [DPIStage] = []
        for i in 0..<count {
            let o = 11 + i * 7
            stages.append(DPIStage(x: Int(r[o + 1]) << 8 | Int(r[o + 2]), y: Int(r[o + 3]) << 8 | Int(r[o + 4])))
        }
        return DPIStageSet(active: Int(r[9]), stages: stages)
    }
    @discardableResult
    func setDPIStages(_ s: DPIStageSet) -> Bool {
        let list = Array(s.stages.prefix(5))
        guard !list.isEmpty else { return false }
        let active = max(1, min(list.count, s.active))
        var args: [UInt8] = [0x01, UInt8(active), UInt8(list.count)]
        for (i, st) in list.enumerated() {
            let x = max(100, min(30000, st.x)), y = max(100, min(30000, st.y))
            args += [UInt8(i + 1), hi(x), lo(x), hi(y), lo(y), 0, 0]
        }
        return query(0x04, 0x06, size: 0x26, args: args) != nil
    }

    // MARK: - Polling rate
    func pollingConfiguration() -> (rate: Int, rates: [Int])? {
        if productID == kMouseDockProPID {
            guard let r = query(0, 0xC0, size: 1, acceptUnsupported: true) else { return nil }
            if r[0] == 2 {
                guard let rate = PollingProtocol.decode(r[9], extended: true) else { return nil }
                return (rate, PollingProtocol.dockRates)
            }
        }
        guard let r = query(0, 0x85, size: 1), let rate = PollingProtocol.decode(r[8], extended: false) else { return nil }
        return (rate, PollingProtocol.standardRates)
    }
    func pollingRate() -> Int? { pollingConfiguration()?.rate }
    @discardableResult
    func setPollingRate(_ hz: Int) -> Bool {
        guard let configuration = pollingConfiguration(), configuration.rates.contains(hz) else { return false }
        if productID == kMouseDockProPID, configuration.rates == PollingProtocol.dockRates {
            guard let code = PollingProtocol.dockCodes[hz], query(0, 0x40, size: 2, args: [0, code]) != nil else { return false }
        } else {
            guard let code = PollingProtocol.standardCodes[hz], query(0, 5, size: 1, args: [code]) != nil else { return false }
        }
        return pollingRate() == hz
    }

    // Naga V3 Pro uses the v2 wheel-mode command and an 80-byte Smart Reel payload.
    func wheelMode() -> WheelMode? {
        guard let r = query(2, 0xB0, size: 2, args: [1]), r[5] >= 2 else { return nil }
        return WheelMode(rawValue: r[9])
    }
    func smartReel() -> Bool? {
        guard let r = query(2, 0x97, size: 2, args: [1]), r[5] >= 2 else { return nil }
        return WheelProtocol.boolean(r[9])
    }
    func setWheelMode(_ mode: WheelMode) -> Bool {
        _ = query(2, 0x30, size: 2, args: [1, mode.rawValue])
        return WheelProtocol.confirm(mode: mode, read: { self.wheelMode() })
    }
    func setSmartReel(_ enabled: Bool) -> Bool {
        return query(2, 0x17, size: 0x50, args: WheelProtocol.smartReelArguments(enabled)) != nil && smartReel() == enabled
    }

    // Dock lighting addresses the accessory itself, independently of the paired mouse.
    private func dockQuery(_ cmd: UInt8, size: UInt8, args: [UInt8]) -> [UInt8]? {
        guard productID == kMouseDockProPID else { return nil }
        lock.lock(); defer { lock.unlock() }
        return exchange(0x0F, cmd, size: size, args: args, transaction: 0xFF)
    }
    func dockLight() -> ZoneLight? {
        guard let b = dockQuery(0x84, size: 3, args: [1, 0x0F]),
              let e = dockQuery(0x82, size: 12, args: [1, 0]) else { return nil }
        // The dock echoes LED 0x0F even when its lighting zone was requested as 0x00.
        return ZoneLight(effect: Array(e[8..<20]), brightness: b[10])
    }
    func setDockLight(_ effect: DockEffect, color: RGB, brightness: UInt8) -> Bool {
        let args = effect.arguments(color)
        guard dockQuery(2, size: UInt8(args.count), args: args) != nil,
              dockQuery(4, size: 3, args: [1, 0, brightness]) != nil,
              let actual = dockLight() else { return false }
        return effect.matches(actual, color: color, brightness: brightness)
    }

    // MARK: - Lighting
    func light(_ z: Zone) -> ZoneLight? {
        guard let b = query(0x0F, 0x84, size: 0x03, args: [0x01, z.rawValue]),
              let e = query(0x0F, 0x82, size: 0x0C, args: [0x01, z.rawValue]) else { return nil }
        return ZoneLight(effect: Array(e[8..<20]), brightness: b[10])
    }
    @discardableResult
    func setBrightness(_ z: Zone, _ v: UInt8) -> Bool {
        query(0x0F, 0x04, size: 0x03, args: [0x01, z.rawValue, v]) != nil
    }
    @discardableResult
    func setStatic(_ z: Zone, _ c: RGB) -> Bool {
        query(0x0F, 0x02, size: 0x09, args: [0x01, z.rawValue, 0x01, 0x00, 0x00, 0x01, c.r, c.g, c.b]) != nil
    }
    @discardableResult
    func setBreathing(_ z: Zone, _ c: RGB) -> Bool {
        query(0x0F, 0x02, size: 0x09, args: [0x01, z.rawValue, 0x02, 0x01, 0x00, 0x01, c.r, c.g, c.b]) != nil
    }
    @discardableResult
    func setSpectrum(_ z: Zone) -> Bool {
        query(0x0F, 0x02, size: 0x06, args: [0x01, z.rawValue, 0x03, 0x00, 0x00, 0x00]) != nil
    }
    @discardableResult
    func restore(_ z: Zone, _ l: ZoneLight) -> Bool {
        var a = l.effect
        guard a.count >= 2 else { return false }
        a[0] = 0x01; a[1] = z.rawValue
        let ok1 = query(0x0F, 0x02, size: 0x0C, args: a) != nil
        let ok2 = setBrightness(z, l.brightness)
        return ok1 && ok2
    }

    // MARK: - Side buttons (decoded from Synapse captures)
    // args: [profile 0x01, button id, layer 0x00, type, length, data...]
    static let sideButtonIDs: [UInt8] = (0..<12).map { UInt8(0x40 + $0) }
    static let defaultKeys: [UInt8] = [0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2D, 0x2E]
    static func defaultArgs(_ index: Int) -> [UInt8] {
        [0x01, sideButtonIDs[index], 0x00, 0x02, 0x01, 0x00, defaultKeys[index], 0, 0, 0]
    }
    static func keyArgs(_ id: UInt8, mod: UInt8, key: UInt8) -> [UInt8] { [0x01, id, 0x00, 0x02, 0x02, mod, key, 0, 0, 0] }
    static func mouseArgs(_ id: UInt8, button: UInt8) -> [UInt8] { [0x01, id, 0x00, 0x01, 0x01, button, 0, 0, 0, 0] }

    func button(_ id: UInt8) -> [UInt8]? {
        guard let r = query(0x02, 0x8C, size: 0x0A, args: [0x01, id, 0x00]) else { return nil }
        return Array(r[8..<18])
    }
    @discardableResult
    func setButton(_ args: [UInt8]) -> Bool {
        guard args.count == 10, let r = query(0x02, 0x0C, size: 0x0A, args: args) else { return false }
        return Array(r[8..<18]) == args && button(args[1]) == args
    }

    // MARK: - Body controls
    // Physical IDs follow the Naga V3 Pro press-validated map linked in docs/PROTOCOL.md.
    // Factory assignments are listed in docs/PROTOCOL.md.
    static let otherButtons: [(name: String, id: UInt8, factory: [UInt8])] = [
        ("Wheel Click", 0x03, [0x01, 0x03, 0x00, 0x01, 0x01, 0x03, 0, 0, 0, 0]),
        ("Wheel Tilt Left", 0x34, [0x01, 0x34, 0x00, 0x0E, 0x01, 0x68, 0x00, 0x14, 0, 0]),
        ("Wheel Tilt Right", 0x35, [0x01, 0x35, 0x00, 0x0E, 0x01, 0x69, 0x00, 0x14, 0, 0]),
        ("Ring / Pinky Button", 0x39, [0x01, 0x39, 0x00, 0x0C, 0x01, 0x39, 0, 0, 0, 0]),
        ("Top-left Front (DPI Up)", 0x0B, [0x01, 0x0B, 0x00, 0x06, 0x01, 0x01, 0, 0, 0, 0]),
        ("Top-left Rear (DPI Down)", 0x0C, [0x01, 0x0C, 0x00, 0x06, 0x01, 0x02, 0, 0, 0, 0]),
        ("Front Button Behind Wheel", 0x6A, [0x01, 0x6A, 0x00, 0x12, 0x01, 0x01, 0, 0, 0, 0]),
        ("Rear Button Behind Wheel", 0x80, [0x01, 0x80, 0x00, 0x00, 0x01, 0x00, 0, 0, 0, 0]),
    ]

    // MARK: - Power
    func sleepTimer() -> Int? {
        guard let r = query(0x07, 0x83, size: 0x02) else { return nil }
        return Int(r[8]) << 8 | Int(r[9])
    }
    @discardableResult
    func setSleepTimer(_ seconds: Int) -> Bool {
        let s = max(60, min(900, seconds))
        return query(0x07, 0x03, size: 0x02, args: [hi(s), lo(s)]) != nil
    }
    func lowPowerThreshold() -> UInt8? {
        guard let r = query(0x07, 0x81, size: 0x01) else { return nil }
        return r[8]
    }
    @discardableResult
    func setLowPowerThreshold(_ raw: UInt8) -> Bool {
        query(0x07, 0x01, size: 0x01, args: [raw]) != nil
    }
}
