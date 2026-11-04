import Foundation

struct MouseRefreshRequest: Equatable {
    struct Fields: OptionSet {
        let rawValue: Int
        static let battery = Fields(rawValue: 1 << 0)
        static let performance = Fields(rawValue: 1 << 1)
        static let lighting = Fields(rawValue: 1 << 2)
        static let power = Fields(rawValue: 1 << 3)
        static let firmware = Fields(rawValue: 1 << 4)
        static let identity = Fields(rawValue: 1 << 5)
        static let dockLighting = Fields(rawValue: 1 << 6)
        static let wheel = Fields(rawValue: 1 << 7)
    }
    var fields: Fields = []
    var buttonIDs: Set<UInt8> = []
    var isEmpty: Bool { fields.isEmpty && buttonIDs.isEmpty }
    static let wheel = Self(fields: .wheel)
    static let dockLighting = Self(fields: .dockLighting)
    static let identity = Self(fields: .identity)
    static let battery = Self(fields: .battery)
    static let performance = Self(fields: .performance)
    static let lighting = Self(fields: .lighting)
    static let power = Self(fields: .power)
    static var buttons: Self { Self(buttonIDs: Set(SerpentisModel.slots.map { $0.id })) }
    static var all: Self { Self(fields: [.battery, .performance, .lighting, .power, .firmware, .dockLighting, .wheel], buttonIDs: buttons.buttonIDs) }
    static let menu = Self(fields: [.battery, .performance, .power, .firmware])
    mutating func merge(_ other: Self) {
        fields.formUnion(other.fields)
        buttonIDs.formUnion(other.buttonIDs)
    }
}

struct RefreshQueue {
    private(set) var running = false
    private var pending = MouseRefreshRequest()

    mutating func enqueue(_ request: MouseRefreshRequest) -> MouseRefreshRequest? {
        guard !request.isEmpty else { return nil }
        if running { pending.merge(request); return nil }
        running = true
        return request
    }

    mutating func finish() -> MouseRefreshRequest? {
        guard !pending.isEmpty else { running = false; return nil }
        let request = pending
        pending = MouseRefreshRequest()
        return request
    }
}

struct MouseSnapshot {
    var supported = false
    var battery: Int?
    var charging = false
    var firmware: String?
    var dpi: DPIStage?
    var stages: DPIStageSet?
    var polling: Int?
    var pollingRates = PollingProtocol.standardRates
    var dockLight: ZoneLight?
    var wheelMode: WheelMode?
    var smartReel: Bool?
    var lights: [Zone: ZoneLight] = [:]
    var buttons: [UInt8: [UInt8]] = [:]
    var sleepSeconds: Int?
    var lowPowerRaw: UInt8?

    init(mouse: RazerMouse?, dock: RazerMouse?, request: MouseRefreshRequest) {
        if request.fields.contains(.dockLighting) { dockLight = dock?.dockLight() }
        guard let mouse = mouse else { return }
        supported = mouse.supportsNaga()
        guard supported else { return }
        if request.fields.contains(.battery) {
            battery = mouse.battery()
            guard battery != nil else { return }
            charging = mouse.isCharging() ?? false
        }
        if request.fields.contains(.firmware) { firmware = mouse.firmware() }
        if request.fields.contains(.performance) {
            dpi = mouse.dpi(); stages = mouse.dpiStages()
            if let configuration = mouse.pollingConfiguration() { polling = configuration.rate; pollingRates = configuration.rates }
        }
        if request.fields.contains(.wheel) { wheelMode = mouse.wheelMode(); smartReel = mouse.smartReel() }
        if request.fields.contains(.lighting) {
            for zone in Zone.allCases { if let light = mouse.light(zone) { lights[zone] = light } }
        }
        for id in request.buttonIDs.sorted() { if let args = mouse.button(id) { buttons[id] = args } }
        if request.fields.contains(.power) {
            sleepSeconds = mouse.sleepTimer(); lowPowerRaw = mouse.lowPowerThreshold()
        }
    }
}
