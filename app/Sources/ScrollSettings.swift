import AppKit
import SwiftUI

extension AppDelegate {
    func startScrollTracking() {
        scrollController.refreshSystem()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(systemScrollDirectionChanged(_:)),
            name: Notification.Name(SystemScrollPreference.key), object: nil
        )
        // The distributed preference notification is not a public contract; polling covers missed changes.
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.scrollController.refreshSystem()
        }
    }

    @objc func systemScrollDirectionChanged(_ notification: Notification) {
        DispatchQueue.main.async { self.scrollController.refreshSystem() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        scrollController.refreshSystem(force: true)
    }

    func identifyScrollDevice(_ mouse: RazerMouse) {
        scrollController.beginConnection(mouse)
        model.identifyScrollDevice(mouse) { [weak self] identifier in
            guard let self = self else { return }
            if let identifier = identifier { self.scrollController.connect(mouse, identifier: identifier) }
            else { self.scrollController.identityFailed(mouse) }
        }
    }

    func retryScrollDirection() {
        scrollController.reloadPreferences()
        if let mouse = mouse { identifyScrollDevice(mouse) }
    }

    func stopScrollTracking() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        DistributedNotificationCenter.default().removeObserver(
            self, name: Notification.Name(SystemScrollPreference.key), object: nil
        )
        scrollController.disconnect(wait: true)
    }
}

struct MouseScrollSettingsView: View {
    @EnvironmentObject var model: SerpentisModel

    var body: some View {
        GroupBox("Mouse Scrolling") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Customize vertical scrolling for this mouse", isOn: Binding(
                    get: { model.scrollState.setting.enabled },
                    set: { enabled in
                        var setting = model.scrollState.setting
                        setting.enabled = enabled
                        model.app?.scrollController.setSetting(setting)
                    }
                )).disabled(!model.scrollState.canConfigure)
                Picker("Direction", selection: Binding(
                    get: { model.scrollState.setting.direction },
                    set: { direction in
                        var setting = model.scrollState.setting
                        setting.direction = direction
                        model.app?.scrollController.setSetting(setting)
                    }
                )) {
                    ForEach(ScrollDirection.allCases) { direction in
                        Text(direction.rawValue).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                .disabled(!model.scrollState.canConfigure || !model.scrollState.setting.enabled)
                if let natural = model.scrollState.systemNatural {
                    Text("macOS direction: \(natural ? "Natural" : "Standard") (not changed by Serpentis)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(model.scrollState.status).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Grant Permissions...") { model.app?.requestInputPermissions() }
                    Button("Retry") { model.app?.retryScrollDirection() }
                }
                Text("Vertical only, saved per mouse rather than per profile. Horizontal scrolling and wheel-tilt assignments are unchanged. Keep Serpentis open; turning this off restores macOS behavior.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
