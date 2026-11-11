import Foundation

protocol ScrollTapDriving: AnyObject {
    // Both callbacks are delivered on the main queue.
    func configure(_ configuration: ScrollConfiguration, mouse: RazerMouse,
                   onError: @escaping (Error) -> Void, completion: @escaping (Result<Void, Error>) -> Void)
    func stop(wait: Bool)
}

struct ScrollState: Equatable {
    var setting = ScrollSetting()
    var systemNatural: Bool?
    var canConfigure = false
    var status = "Mouse disconnected"
    var error: String?
}

// Preference and UI state belong to the main thread; the driver owns its input queue.
final class ScrollDirectionController {
    private let store: ScrollPreferencesStore
    private let readSystemNatural: () throws -> Bool
    private let driver: ScrollTapDriving
    private let onChange: (ScrollState) -> Void
    private var preferences: ScrollPreferences?
    private var mouse: RazerMouse?
    private var identifier: String?
    private var revision = 0
    private(set) var state = ScrollState()

    init(defaults: UserDefaults, driver: ScrollTapDriving = ScrollEventTap(),
         readSystemNatural: @escaping () throws -> Bool = SystemScrollPreference.read,
         onChange: @escaping (ScrollState) -> Void = { _ in }) {
        store = ScrollPreferencesStore(defaults: defaults)
        self.driver = driver
        self.readSystemNatural = readSystemNatural
        self.onChange = onChange
        reloadPreferences()
    }

    func reloadPreferences() {
        do {
            preferences = try store.load()
            state.error = nil
        } catch {
            preferences = nil
            revision += 1
            driver.stop(wait: false)
            state.canConfigure = false
            report("Could not load per-mouse scrolling preferences: \(error.localizedDescription)")
        }
    }

    func beginConnection(_ mouse: RazerMouse) {
        disconnect()
        self.mouse = mouse
        state.status = "Reading this mouse's scrolling identity..."
        publish()
    }

    func connect(_ mouse: RazerMouse, identifier: String) {
        guard self.mouse === mouse else { return }
        guard !identifier.isEmpty else { identityFailed(mouse); return }
        self.identifier = identifier
        guard let preferences = preferences else {
            report(ScrollError.preferencesUnavailable.localizedDescription)
            return
        }
        state.setting = preferences.devices[identifier] ?? ScrollSetting()
        state.canConfigure = true
        refreshSystem(force: true)
    }

    func identityFailed(_ mouse: RazerMouse) {
        guard self.mouse === mouse else { return }
        state.status = ScrollError.deviceIdentity.localizedDescription
        state.canConfigure = false
        publish()
    }

    func setSetting(_ setting: ScrollSetting) {
        guard let identifier = identifier, mouse != nil, var preferences = preferences else {
            report(ScrollError.preferencesUnavailable.localizedDescription)
            return
        }
        preferences.devices[identifier] = setting
        do { try store.save(preferences) }
        catch { report("Could not save mouse scrolling preferences: \(error.localizedDescription)"); return }
        self.preferences = preferences
        state.setting = setting
        refreshSystem(force: true)
    }

    func refreshSystem(force: Bool = false) {
        let natural: Bool
        do { natural = try readSystemNatural() }
        catch {
            revision += 1
            driver.stop(wait: false)
            state.systemNatural = nil
            report(error.localizedDescription)
            return
        }
        guard force || state.systemNatural != natural else { return }
        state.systemNatural = natural
        synchronize()
    }

    private func synchronize() {
        revision += 1
        let request = revision
        guard preferences != nil else { publish(); return }
        state.error = nil
        guard let mouse = mouse, let identifier = identifier,
              let natural = state.systemNatural else { publish(); return }
        guard state.setting.enabled else {
            driver.stop(wait: false)
            state.status = "Custom scrolling off - following macOS"
            publish()
            return
        }
        state.status = "Applying \(state.setting.direction.rawValue.lowercased()) vertical scrolling..."
        publish()
        let configuration = ScrollConfiguration(systemNatural: natural, desiredNatural: state.setting.direction.isNatural)
        driver.configure(configuration, mouse: mouse, onError: { [weak self] error in
            guard let self = self, self.revision == request, self.identifier == identifier else { return }
            self.report(error.localizedDescription)
        }, completion: { [weak self] result in
            guard let self = self, self.revision == request, self.identifier == identifier else { return }
            switch result {
            case .success:
                self.state.status = "\(self.state.setting.direction.rawValue) vertical scrolling active (hardware validation required)"
                self.publish()
            case .failure(let error): self.report(error.localizedDescription)
            }
        })
    }

    func disconnect(wait: Bool = false) {
        revision += 1
        mouse = nil
        identifier = nil
        driver.stop(wait: wait)
        state.setting = ScrollSetting()
        state.canConfigure = false
        state.status = "Mouse disconnected"
        state.error = nil
        publish()
    }

    private func report(_ message: String) {
        guard state.status != message || state.error != message else { return }
        state.status = message
        state.error = message
        publish()
    }

    private func publish() { onChange(state) }
}
