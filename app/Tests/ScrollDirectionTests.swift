import AppKit
import CoreGraphics
import Foundation

private final class ScrollDriverRecorder: ScrollTapDriving {
    struct Request {
        let configuration: ScrollConfiguration
        let mouse: RazerMouse
        let onError: (Error) -> Void
        let completion: (Result<Void, Error>) -> Void
    }

    var requests: [Request] = []
    var stops: [Bool] = []
    var deferred = false
    var error: Error?
    var record: (String) -> Void = { _ in }

    func configure(_ configuration: ScrollConfiguration, mouse: RazerMouse,
                   onError: @escaping (Error) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        record("configure")
        requests.append(Request(configuration: configuration, mouse: mouse, onError: onError, completion: completion))
        if !deferred {
            if let error = error { completion(.failure(error)) }
            else { completion(.success(())) }
        }
    }

    func stop(wait: Bool) { record("stop"); stops.append(wait) }
}

private final class TestInputTapSession: InputTapSession {
    var source: CFRunLoopSource?
    var startedOnWorker = false
    var stoppedOnWorker = false
    var shouldFail = false

    func start() throws {
        startedOnWorker = !Thread.isMainThread
        if shouldFail { throw ScrollError.interception }
        var context = CFRunLoopSourceContext(version: 0, info: nil, retain: nil, release: nil,
                                            copyDescription: nil, equal: nil, hash: nil,
                                            schedule: nil, cancel: nil, perform: { _ in })
        let source = try require(CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context))
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    }

    func stop() {
        stoppedOnWorker = !Thread.isMainThread
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        source = nil
    }
}

struct ScrollDirectionTests {
    private let filter = ScrollEventFilter(targetSenderIDs: [101, 102])
    private let inverted = ScrollConfiguration(systemNatural: true, desiredNatural: false)
    private let preservedFields: [CGEventField] = [
        .scrollWheelEventDeltaAxis2, .scrollWheelEventDeltaAxis3,
        .scrollWheelEventPointDeltaAxis2, .scrollWheelEventPointDeltaAxis3,
        .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis3,
        .scrollWheelEventIsContinuous, .scrollWheelEventScrollPhase,
        .scrollWheelEventMomentumPhase, .scrollWheelEventScrollCount,
        .eventSourceUnixProcessID, .eventSourceUserData, .eventSourceUserID,
        .eventSourceGroupID, .eventSourceStateID,
    ]

    private func event(lines: Int64 = 2, pixels: Int64 = 23, fixed: Double = 1.25, pid: Int64 = 0) throws -> CGEvent {
        let source = try require(CGEventSource(stateID: .privateState))
        let event = try require(CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 3,
                                       wheel1: 0, wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: lines)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 7)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis3, value: -8)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: pixels)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 43)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis3, value: -45)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0.375)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3, value: -1.75)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollCount, value: 3)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
        event.setIntegerValueField(.eventSourceUserData, value: 1234)
        event.flags = [.maskControl, .maskAlternate]
        event.timestamp = 12345678
        event.location = CGPoint(x: 87, y: 126)
        return event
    }

    private func withSettings(_ test: (UserDefaults) throws -> Void) throws {
        let suite = "com.davewoods.serpentis.scroll.tests.\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try test(defaults)
    }

    private func expectError(_ expected: ScrollError, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch let error as ScrollError { try expect(error == expected); return }
        throw TestFailure(description: "Expected \(expected), but the operation succeeded")
    }

    func allSystemAndDesiredDirections() throws {
        for system in [false, true] {
            for desired in [false, true] {
                let event = try event()
                let before = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                try filter.process(event, senderID: 101, configuration: ScrollConfiguration(
                    systemNatural: system, desiredNatural: desired
                ))
                try expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == (system != desired ? -before : before))
            }
        }
    }

    func deltaRepresentationsAreInvertedExactly() throws {
        for (lines, pixels, fixed): (Int64, Int64, Double) in [
            (2, 23, 1.25), (-3, -31, -2.375), (0, 0, 0),
            (0, 1, 0.125), (0, -1, -0.0625), (1, -4, -0.75),
        ] {
            let event = try event(lines: lines, pixels: pixels, fixed: fixed)
            let before = [
                event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1),
            ]
            try filter.process(event, senderID: 101, configuration: inverted)
            try expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -before[0])
            try expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -before[1])
            try expect(event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1) == -before[2])
            try expect(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) == -fixed)
        }
    }

    func horizontalAxesAndMetadataArePreserved() throws {
        let event = try event()
        let original = event
        let fields = preservedFields.map { event.getIntegerValueField($0) }
        let flags = event.flags, location = event.location, timestamp = event.timestamp
        try filter.process(event, senderID: 102, configuration: inverted)
        try expect(event === original, "the original event must be modified rather than replaced")
        try expect(preservedFields.map { event.getIntegerValueField($0) } == fields)
        try expect(event.flags == flags && event.location == location && event.timestamp == timestamp)
        try expect(event.type == .scrollWheel)
    }

    func otherDevicesAndUnknownOriginsAreUntouched() throws {
        // Distinct IDs stand for a trackpad, another mouse and an unidentified source.
        for sender: UInt64? in [202, 303, nil, 0] {
            let event = try event()
            let before = try require(event.data) as Data
            try filter.process(event, senderID: sender, configuration: inverted)
            try expect(try require(event.data) as Data == before)
        }
        let unidentified = ScrollEventFilter(targetSenderIDs: [])
        let event = try event()
        let before = try require(event.data) as Data
        try unidentified.process(event, senderID: 101, configuration: inverted)
        try expect(try require(event.data) as Data == before)
    }

    func syntheticScrollEventsAreUntouched() throws {
        for pid: Int64 in [1, 42, Int64(ProcessInfo.processInfo.processIdentifier)] {
            let event = try event(pid: pid)
            let before = try require(event.data) as Data
            try filter.process(event, senderID: 101, configuration: inverted)
            try expect(try require(event.data) as Data == before)
        }
    }

    func pointerClicksAndKeyboardActionsAreUntouched() throws {
        for type: CGEventType in [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown,
                                  .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                  .keyDown, .keyUp, .flagsChanged] {
            let event = try event()
            event.type = type
            let before = try require(event.data) as Data
            try filter.process(event, senderID: 101, configuration: inverted)
            try expect(try require(event.data) as Data == before, "event type \(type.rawValue)")
        }
    }

    func horizontalTiltKeepsItsPhysicalDirection() throws {
        let event = try event(lines: 0, pixels: 0, fixed: 0)
        let before = try require(event.data) as Data
        try filter.process(event, senderID: 101, configuration: inverted)
        try expect(try require(event.data) as Data == before)
    }

    func keyboardTiltRemapsKeepTheirModifierBehavior() throws {
        for id: UInt8 in [0x34, 0x35] {
            let configuration = try ModifierConfiguration(
                assignments: [id: RazerMouse.keyArgs(id, mod: 1, key: 0x1E)], enabledButtons: [id]
            )
            let keyboard = PhysicalModifierFilter(configuration: configuration, targetSenderIDs: [101])
            keyboard.setModifier(.leftShift, down: true, keyboard: 202)
            for down in [true, false] {
                let source = try require(CGEventSource(stateID: .privateState))
                let event = try require(CGEvent(keyboardEventSource: source, virtualKey: 0x12, keyDown: down))
                event.flags = []
                event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
                try keyboard.process(event, type: event.type, senderID: 101)
                let before = try require(event.data) as Data
                try filter.process(event, senderID: 101, configuration: inverted)
                try expect(try require(event.data) as Data == before)
                try expect(event.flags == [.maskControl, .maskShift])
            }
        }
    }

    func unsafeDeltasFailWithoutPartialChanges() throws {
        for (field, minimum): (CGEventField, Int64) in [
            (.scrollWheelEventDeltaAxis1, Int64(Int16.min)),
            (.scrollWheelEventPointDeltaAxis1, Int64(Int32.min)),
            (.scrollWheelEventFixedPtDeltaAxis1, Int64(Int32.min)),
        ] {
            let event = try event()
            event.setIntegerValueField(field, value: minimum)
            let before = try require(event.data) as Data
            try expectError(.invalidDelta) { try filter.process(event, senderID: 101, configuration: inverted) }
            try expect(try require(event.data) as Data == before)
        }
    }

    func systemPreferenceHasAnExplicitDefaultAndRejectsInvalidValues() throws {
        try expect(try SystemScrollPreference.decode(nil))
        try expect(try SystemScrollPreference.decode(NSNumber(value: true)))
        try expect(!(try SystemScrollPreference.decode(NSNumber(value: false))))
        for value: Any in ["true", NSNumber(value: 2), Data()] {
            try expectError(.systemPreference) { _ = try SystemScrollPreference.decode(value) }
        }
    }

    func firmwareSerialIdentifiesTheMouseAcrossTransports() throws {
        var identifiers: [String] = []
        for product in [0x00E7, 0x00E8] {
            let recorder = ReportRecorder()
            recorder.replies = [ReportRecorder.reply(reportClass: 0, command: 0x82, args: Array("TEST-MOUSE-A".utf8))]
            let serial = try require(recorder.mouse(productID: product).serial())
            try expect(serial == "TEST-MOUSE-A")
            identifiers.append(try scrollDeviceIdentifier(serial: serial))
            try expect(recorder.sent.count == 1, "identity lookup must not change hardware settings")
        }
        try expect(identifiers[0] == identifiers[1])
        try expect(try scrollDeviceIdentifier(serial: "TEST-MOUSE-B") != identifiers[0])
        for serial in ["", "  ", "0000000000", "bad\nserial"] {
            try expectError(.deviceIdentity) { _ = try scrollDeviceIdentifier(serial: serial) }
        }
    }

    func invalidSerialRepliesDoNotBecomeSharedDeviceIdentities() throws {
        for bytes: [UInt8] in [[], [0], [0xFF], [0x01, 0x02]] {
            let recorder = ReportRecorder()
            recorder.replies = [ReportRecorder.reply(reportClass: 0, command: 0x82, args: bytes)]
            try expect(recorder.mouse().serial() == nil)
        }
        let recorder = ReportRecorder()
        recorder.replies = [Array(ReportRecorder.reply(reportClass: 0, command: 0x82, args: [65]).prefix(20))]
        try expect(recorder.mouse().serial() == nil)
    }

    func preferencesArePerMouseAndSurviveRestartAndReconnect() throws {
        try withSettings { defaults in
            let a = try scrollDeviceIdentifier(serial: "TEST-MOUSE-A")
            let b = try scrollDeviceIdentifier(serial: "TEST-MOUSE-B")
            let first = ReportRecorder().mouse(), second = ReportRecorder().mouse()
            let driver = ScrollDriverRecorder()
            let controller = ScrollDirectionController(defaults: defaults, driver: driver, readSystemNatural: { true })
            controller.beginConnection(first); controller.connect(first, identifier: a)
            try expect(!controller.state.setting.enabled && driver.requests.isEmpty)
            controller.setSetting(ScrollSetting(enabled: true, direction: .standard))
            controller.disconnect()
            controller.beginConnection(second); controller.connect(second, identifier: b)
            try expect(!controller.state.setting.enabled)
            controller.setSetting(ScrollSetting(enabled: true, direction: .natural))
            controller.disconnect(wait: true)
            let newDriver = ScrollDriverRecorder()
            let restarted = ScrollDirectionController(defaults: defaults, driver: newDriver, readSystemNatural: { true })
            restarted.beginConnection(first); restarted.connect(first, identifier: a)
            try expect(restarted.state.setting == ScrollSetting(enabled: true, direction: .standard))
            try expect(try require(newDriver.requests.last).configuration.shouldInvert)
            restarted.disconnect()
            restarted.beginConnection(second); restarted.connect(second, identifier: b)
            try expect(restarted.state.setting == ScrollSetting(enabled: true, direction: .natural))
            try expect(!(try require(newDriver.requests.last).configuration.shouldInvert))
            try expect(driver.stops.last == true, "shutdown must finish stopping its own tap")
            let encoded = try require(defaults.data(forKey: ScrollPreferencesStore.key))
            try expect(!(String(data: encoded, encoding: .utf8) ?? "").contains("TEST-MOUSE"))
        }
    }

    func settingsApplyImmediatelyAfterReadingTheSystemPreference() throws {
        try withSettings { defaults in
            var system = false
            var calls: [String] = []
            let driver = ScrollDriverRecorder()
            driver.record = { calls.append($0) }
            let controller = ScrollDirectionController(defaults: defaults, driver: driver, readSystemNatural: {
                calls.append("read"); return system
            })
            let mouse = ReportRecorder().mouse()
            controller.beginConnection(mouse); controller.connect(mouse, identifier: "test-device")
            calls = []
            controller.setSetting(ScrollSetting(enabled: true, direction: .standard))
            try expect(calls == ["read", "configure"])
            try expect(!(try require(driver.requests.last).configuration.shouldInvert))
            let storedChoice = defaults.data(forKey: ScrollPreferencesStore.key)
            system = true; calls = []
            controller.refreshSystem()
            try expect(calls == ["read", "configure"])
            try expect(try require(driver.requests.last).configuration.shouldInvert)
            try expect(defaults.data(forKey: ScrollPreferencesStore.key) == storedChoice,
                       "system changes must not persist a computed inversion flag")
            calls = []
            controller.setSetting(ScrollSetting(enabled: true, direction: .natural))
            try expect(calls == ["read", "configure"])
            try expect(!(try require(driver.requests.last).configuration.shouldInvert))
            calls = []; controller.refreshSystem()
            try expect(calls == ["read"], "unchanged polling must not restart the tap")
        }
    }

    func disableDisconnectAndStaleCallbacksCannotReactivateScrolling() throws {
        try withSettings { defaults in
            let driver = ScrollDriverRecorder()
            driver.deferred = true
            let controller = ScrollDirectionController(defaults: defaults, driver: driver, readSystemNatural: { true })
            let mouse = ReportRecorder().mouse()
            controller.beginConnection(mouse); controller.connect(mouse, identifier: "test-device")
            controller.setSetting(ScrollSetting(enabled: true, direction: .standard))
            controller.setSetting(ScrollSetting(enabled: true, direction: .natural))
            driver.requests[1].completion(.success(()))
            let active = controller.state
            driver.requests[0].completion(.failure(ScrollError.interrupted))
            driver.requests[0].onError(ScrollError.interrupted)
            try expect(controller.state == active)
            controller.setSetting(ScrollSetting(enabled: false, direction: .natural))
            let disabled = controller.state
            driver.requests[1].onError(ScrollError.interrupted)
            try expect(controller.state == disabled && driver.stops.last == false)
            controller.setSetting(ScrollSetting(enabled: true, direction: .natural))
            controller.disconnect(wait: true)
            let disconnected = controller.state
            driver.requests[2].completion(.success(()))
            driver.requests[2].onError(ScrollError.interrupted)
            try expect(controller.state == disconnected && !controller.state.canConfigure)
            try expect(driver.stops.last == true)
        }
    }

    func permissionAndInterruptionFailuresAreVisibleAndRetriable() throws {
        try withSettings { defaults in
            let driver = ScrollDriverRecorder()
            driver.error = ScrollError.permission
            let controller = ScrollDirectionController(defaults: defaults, driver: driver, readSystemNatural: { true })
            let mouse = ReportRecorder().mouse()
            controller.beginConnection(mouse); controller.connect(mouse, identifier: "test-device")
            controller.setSetting(ScrollSetting(enabled: true, direction: .standard))
            try expect(controller.state.error == ScrollError.permission.localizedDescription)
            try expect(controller.state.setting.enabled, "keep the user's choice, not a false active state")
            driver.error = nil
            controller.refreshSystem(force: true)
            try expect(controller.state.error == nil && controller.state.status.contains("active"))
            driver.stop(wait: false)
            driver.requests.last?.onError(ScrollError.interrupted)
            try expect(controller.state.error == ScrollError.interrupted.localizedDescription)
            controller.refreshSystem(force: true)
            try expect(controller.state.error == nil && controller.state.status.contains("active"))
        }
    }

    func systemReadFailuresStopFilteringWithoutAnInventedDirection() throws {
        try withSettings { defaults in
            var fail = false
            let driver = ScrollDriverRecorder()
            let controller = ScrollDirectionController(defaults: defaults, driver: driver, readSystemNatural: {
                if fail { throw ScrollError.systemPreference }
                return true
            })
            let mouse = ReportRecorder().mouse()
            controller.beginConnection(mouse); controller.connect(mouse, identifier: "test-device")
            controller.setSetting(ScrollSetting(enabled: true, direction: .standard))
            let requests = driver.requests.count, stops = driver.stops.count
            fail = true; controller.refreshSystem()
            try expect(driver.requests.count == requests && driver.stops.count == stops + 1)
            try expect(controller.state.systemNatural == nil)
            try expect(controller.state.error == ScrollError.systemPreference.localizedDescription)
            fail = false; controller.refreshSystem()
            try expect(driver.requests.count == requests + 1 && controller.state.error == nil)
        }
    }

    func corruptPreferencesAreNotOverwrittenByDefaults() throws {
        for invalid: Any in [Data("invalid JSON".utf8), "wrong storage type"] {
            try withSettings { defaults in
                defaults.set(invalid, forKey: ScrollPreferencesStore.key)
                let before = defaults.object(forKey: ScrollPreferencesStore.key) as? NSObject
                let driver = ScrollDriverRecorder()
                let controller = ScrollDirectionController(defaults: defaults, driver: driver, readSystemNatural: { true })
                try expect(controller.state.error != nil)
                let mouse = ReportRecorder().mouse()
                controller.beginConnection(mouse); controller.connect(mouse, identifier: "test-device")
                controller.setSetting(ScrollSetting(enabled: true, direction: .natural))
                try expect(!controller.state.canConfigure && driver.requests.isEmpty)
                try expect((defaults.object(forKey: ScrollPreferencesStore.key) as? NSObject) == before)
            }
        }
    }

    func missingIdentityCannotConfigureAnyOtherDevice() throws {
        try withSettings { defaults in
            let driver = ScrollDriverRecorder()
            let controller = ScrollDirectionController(defaults: defaults, driver: driver, readSystemNatural: { true })
            let mouse = ReportRecorder().mouse(), stale = ReportRecorder().mouse()
            controller.beginConnection(mouse)
            controller.connect(mouse, identifier: "")
            try expect(!controller.state.canConfigure)
            controller.identityFailed(mouse)
            try expect(!controller.state.canConfigure && controller.state.status == ScrollError.deviceIdentity.localizedDescription)
            controller.connect(stale, identifier: "not-current")
            controller.setSetting(ScrollSetting(enabled: true, direction: .natural))
            try expect(driver.requests.isEmpty && defaults.object(forKey: ScrollPreferencesStore.key) == nil)
        }
    }

    func legacyProfilesAndLayoutChangesLeaveScrollSettingsAlone() throws {
        try withSettings { defaults in
            let app = AppDelegate()
            app.settingsDefaults = defaults; app.model.app = app
            let profile = Data(#"{"Existing":{"lights":{}}}"#.utf8)
            let layout = Data(#"{"Existing":[[1,64,0,2,1,0,30,0,0,0]]}"#.utf8)
            defaults.set(profile, forKey: app.profilesKey)
            defaults.set(layout, forKey: app.layoutsKey)
            let driver = ScrollDriverRecorder()
            let controller = ScrollDirectionController(defaults: defaults, driver: driver, readSystemNatural: { true })
            let recorder = ReportRecorder(), mouse = recorder.mouse()
            app.mouse = mouse
            controller.beginConnection(mouse); controller.connect(mouse, identifier: "test-device")
            try expect(!controller.state.setting.enabled && defaults.object(forKey: ScrollPreferencesStore.key) == nil)
            controller.setSetting(ScrollSetting(enabled: true, direction: .natural))
            let before = try require(defaults.data(forKey: ScrollPreferencesStore.key))
            app.model.loadProfile("Existing")
            try waitUntil { app.model.busy == 0 }
            app.storeLayouts(["Other": [RazerMouse.defaultArgs(1)]])
            try expect(defaults.data(forKey: app.profilesKey) == profile)
            try expect(defaults.data(forKey: ScrollPreferencesStore.key) == before)
            try expect(controller.state.setting == ScrollSetting(enabled: true, direction: .natural))
            try expect(driver.requests.count == 1)
        }
    }

    func foregroundAndSystemNotificationsReadBeforeUpdatingConfiguration() throws {
        try withSettings { defaults in
            let driver = ScrollDriverRecorder()
            var system = true
            var calls: [String] = []
            driver.record = { calls.append($0) }
            let controller = ScrollDirectionController(defaults: defaults, driver: driver, readSystemNatural: {
                calls.append("read"); return system
            })
            let app = AppDelegate(), mouse = ReportRecorder().mouse()
            app.scrollController = controller
            controller.beginConnection(mouse); controller.connect(mouse, identifier: "test-device")
            controller.setSetting(ScrollSetting(enabled: true, direction: .standard))
            calls = []; system = false
            app.appActivated(Notification(name: NSWorkspace.didActivateApplicationNotification))
            try expect(calls == ["read", "configure"], "refresh must run even without auto-layout configuration")
            calls = []; system = true
            app.systemScrollDirectionChanged(Notification(name: Notification.Name(SystemScrollPreference.key)))
            try waitUntil { calls.count >= 2 }
            try expect(calls == ["read", "configure"])
            calls = []
            app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            try expect(calls == ["read", "configure"])
            app.stopScrollTracking()
            try expect(driver.stops.last == true)
        }
    }

    func liveDriverRejectsMissingDeviceWithoutCapturingInput() throws {
        let driver = ScrollEventTap()
        var completed = false
        var reported: Error?
        driver.configure(inverted, mouse: ReportRecorder().mouse(), onError: { reported = $0 }, completion: {
            if case .failure(let error) = $0 { reported = error }
            completed = true
        })
        try waitUntil { completed }
        try expect(reported as? ScrollError == .eventIdentity)
        driver.stop(wait: true)
    }

    func staleIdentityReadsCannotAttachAReplacedMouse() throws {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let old = RazerMouse(productID: 0x00E7, transport: RazerReportTransport(
            send: { _ in started.signal(); release.wait(); return true },
            receive: { ReportRecorder.reply(reportClass: 0, command: 0x82, args: Array("OLD-MOUSE".utf8)) },
            wait: { _ in }
        ))
        let recorder = ReportRecorder()
        recorder.replies = [ReportRecorder.reply(reportClass: 0, command: 0x82, args: Array("NEW-MOUSE".utf8))]
        let current = recorder.mouse()
        let app = AppDelegate()
        app.model.app = app; app.mouse = old
        var oldCompleted = false
        var currentIdentifier: String?
        app.model.identifyScrollDevice(old) { _ in oldCompleted = true }
        let ready = started.wait(timeout: .now() + 2)
        guard ready == .success else {
            release.signal()
            throw TestFailure(description: "Identity read did not start")
        }
        app.mouse = current
        app.model.identifyScrollDevice(current) { currentIdentifier = $0 }
        release.signal()
        try waitUntil { currentIdentifier != nil && app.model.busy == 0 }
        try expect(!oldCompleted)
        try expect(try currentIdentifier == scrollDeviceIdentifier(serial: "NEW-MOUSE"))
    }

    func sharedTapWorkerStopsAndCanRestartAfterFailure() throws {
        let worker = EventTapThread()
        let failed = TestInputTapSession()
        failed.shouldFail = true
        try expectError(.interception) { try worker.start(name: "Serpentis test tap") { failed } }
        try expect(failed.startedOnWorker && failed.stoppedOnWorker)
        for _ in 0..<2 {
            let session = TestInputTapSession()
            try worker.start(name: "Serpentis test tap") { session }
            try expect(session.startedOnWorker)
            worker.stop()
            try expect(session.stoppedOnWorker && session.source == nil)
        }
    }
}
