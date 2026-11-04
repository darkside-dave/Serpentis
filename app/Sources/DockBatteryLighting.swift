import Foundation

struct DockBatteryPalette: Codable, Equatable {
    var low: RGB
    var mediumLow: RGB
    var mediumHigh: RGB
    var high: RGB

    static let defaults = Self(low: RGB(r: 255, g: 59, b: 48), mediumLow: RGB(r: 255, g: 149, b: 0),
                               mediumHigh: RGB(r: 255, g: 204, b: 0), high: RGB(r: 52, g: 199, b: 89))
    static let labels = ["0–24%", "25–49%", "50–74%", "75–100%"]
    var colors: [RGB] { [low, mediumLow, mediumHigh, high] }
    static func band(for level: Int, previous: Int? = nil) -> Int? {
        guard (0...100).contains(level) else { return nil }
        let nominal = min(3, level / 25)
        guard let previous = previous, (0...3).contains(previous) else { return nominal }
        if nominal > previous && level < (previous + 1) * 25 + 2 { return previous }
        if nominal < previous && level > previous * 25 - 2 { return previous }
        return nominal
    }
    func color(for level: Int) -> RGB? {
        Self.band(for: level).map { colors[$0] }
    }
    mutating func set(_ index: Int, color: RGB) {
        switch index {
        case 0: low = color
        case 1: mediumLow = color
        case 2: mediumHigh = color
        case 3: high = color
        default: break
        }
    }
    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "dockBatteryPalette"),
              let palette = try? JSONDecoder().decode(Self.self, from: data) else { return .defaults }
        return palette
    }
}

struct DockBatteryTarget: Equatable {
    let color: RGB
    let brightness: UInt8
    func requiresWrite(applied: Self?, pending: Self?) -> Bool {
        pending != self && (applied != self || pending != nil)
    }
    static func make(level: Int?, palette: DockBatteryPalette, brightness: UInt8) -> Self? {
        guard let level = level, let color = palette.color(for: level) else { return nil }
        return Self(color: color, brightness: brightness)
    }
}

// A cancelled queued update must not overwrite a later manual lighting choice.
final class DockBatteryUpdate {
    private let lock = NSLock()
    private var cancelled = false
    let target: DockBatteryTarget
    init(target: DockBatteryTarget) { self.target = target }
    var active: Bool { lock.lock(); defer { lock.unlock() }; return !cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
