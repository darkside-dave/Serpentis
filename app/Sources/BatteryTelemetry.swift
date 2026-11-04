import Foundation

struct BatteryTelemetry: Equatable {
    let level: Int
    let charging: Bool?
}

struct BatteryTelemetryCache {
    static let refreshInterval: TimeInterval = 60
    static let retryInterval: TimeInterval = 5
    private var lastAttempt: TimeInterval?
    private(set) var value: BatteryTelemetry?

    func needsRead(at time: TimeInterval) -> Bool {
        guard let lastAttempt = lastAttempt else { return true }
        return time - lastAttempt >= (value == nil ? Self.retryInterval : Self.refreshInterval)
    }
    mutating func record(_ value: BatteryTelemetry?, at time: TimeInterval) {
        self.value = value; lastAttempt = time
    }
}
