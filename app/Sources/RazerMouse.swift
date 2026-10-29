// RazerMouse.swift - talks to the Razer Naga V3 Pro using the commands verified in Phases 1-2.
import Foundation
import IOKit
import IOKit.hid

let kRazerVID = 0x1532
let kNagaPIDs: [Int: String] = [0x00E7: "Cable", 0x00E8: "Wireless"]

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

private func hi(_ v: Int) -> UInt8 { UInt8((v >> 8) & 0xFF) }
private func lo(_ v: Int) -> UInt8 { UInt8(v & 0xFF) }

final class RazerMouse {
    let device: IOHIDDevice
    let productID: Int
    private let txn: UInt8 = 0x1F
    private let lock = NSLock()
    var connectionName: String { kNagaPIDs[productID] ?? "USB" }

    init?(device: IOHIDDevice) {
        self.device = device
        self.productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
    }
    deinit { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

    // MARK: - Protocol
    private func makeReport(_ cls: UInt8, _ cmd: UInt8, _ size: UInt8, _ args: [UInt8]) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 90)
        r[1] = txn; r[5] = size; r[6] = cls; r[7] = cmd
        for (i, a) in args.prefix(80).enumerated() { r[8 + i] = a }
        var crc: UInt8 = 0
        for i in 2..<88 { crc ^= r[i] }
        r[88] = crc
        return r
    }

    /// Sends a command and returns the reply if the mouse answered "OK".
    func query(_ cls: UInt8, _ cmd: UInt8, size: UInt8, args: [UInt8] = []) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        var buf = makeReport(cls, cmd, size, args)
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, &buf, buf.count) == kIOReturnSuccess else { return nil }
        usleep(45_000)
        for _ in 0..<20 {
            var out = [UInt8](repeating: 0, count: 90)
            var len = CFIndex(90)
            guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, &out, &len) == kIOReturnSuccess else { return nil }
            if out[0] == 0x01 || out[6] != cls || out[7] != cmd { usleep(25_000); continue }
            return out[0] == 0x02 ? out : nil
        }
        return nil
    }

    // MARK: - Info
    func firmware() -> String? {
        guard let r = query(0x00, 0x81, size: 0x02) else { return nil }
        return "\(r[8]).\(String(format: "%02d", r[9]))"
    }
    func battery() -> Int? {
        guard let r = query(0x07, 0x80, size: 0x02) else { return nil }
        return Int((Double(r[9]) / 255.0 * 100.0).rounded())
    }
    func isCharging() -> Bool? {
        guard let r = query(0x07, 0x84, size: 0x02) else { return nil }
        return r[9] == 1
    }

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
    func pollingRate() -> Int? {
        guard let r = query(0x00, 0x85, size: 0x01) else { return nil }
        return [UInt8(0x01): 1000, 0x02: 500, 0x08: 125][r[8]]
    }
    @discardableResult
    func setPollingRate(_ hz: Int) -> Bool {
        guard let code = [1000: UInt8(0x01), 500: 0x02, 125: 0x08][hz] else { return false }
        return query(0x00, 0x05, size: 0x01, args: [code]) != nil
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
        return Array(r[8..<18]) == args
    }

    // MARK: - Other buttons (found by the discovery test)
    static let otherButtons: [(name: String, id: UInt8, factory: [UInt8])] = [
        ("Wheel Click", 0x03, [0x01, 0x03, 0x00, 0x01, 0x01, 0x03, 0, 0, 0, 0]),
        ("Wheel Tilt Left", 0x34, [0x01, 0x34, 0x00, 0x0E, 0x01, 0x68, 0x00, 0x14, 0, 0]),
        ("Wheel Tilt Right", 0x35, [0x01, 0x35, 0x00, 0x0E, 0x01, 0x69, 0x00, 0x14, 0, 0]),
        ("Button Behind Wheel", 0x39, [0x01, 0x39, 0x00, 0x0C, 0x01, 0x01, 0, 0, 0, 0]),
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
