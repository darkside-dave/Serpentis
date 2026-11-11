import Foundation

struct PersistenceTests {
    private func withSettings(_ test: (AppDelegate, UserDefaults) throws -> Void) throws {
        let suite = "com.davewoods.serpentis.tests.\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppDelegate()
        app.settingsDefaults = defaults
        try test(app, defaults)
    }

    func existingLayoutsLoadWithoutMigration() throws {
        try withSettings { app, defaults in
            let data = Data(#"{"Existing":[[1,64,0,2,1,0,30,0,0,0],[1,3,0,1,1,3,0,0,0,0]]}"#.utf8)
            defaults.set(data, forKey: app.layoutsKey)
            let layouts = app.loadLayouts()
            try expect(layouts["Existing"] == [
                RazerMouse.defaultArgs(0), RazerMouse.otherButtons[0].factory,
            ])
            try expect(defaults.data(forKey: app.layoutsKey) == data)
        }
    }

    func layoutsPreserveAllButtonsAndFixedModifiers() throws {
        try withSettings { app, defaults in
            let assignments = SerpentisModel.slots.map {
                RazerMouse.keyArgs($0.id, mod: 3, key: 0x1E)
            }
            let layouts = ["Default": SerpentisModel.slots.map(\.factory), "Custom": assignments]
            app.storeLayouts(layouts)
            try expect(app.loadLayouts() == layouts)
            let stored = try require(defaults.data(forKey: app.layoutsKey))
            let decoded = try JSONDecoder().decode([String: [[UInt8]]].self, from: stored)
            try expect(decoded == layouts)
        }
    }

    func legacyProfilesAllowAbsentOptionalFields() throws {
        try withSettings { app, defaults in
            let data = Data(#"{"Legacy":{"lights":{}}}"#.utf8)
            defaults.set(data, forKey: app.profilesKey)
            let profile = try require(app.loadProfiles()["Legacy"])
            try expect(profile.stages == nil)
            try expect(profile.pollingRate == nil)
            try expect(profile.lights.isEmpty)
            try expect(defaults.data(forKey: app.profilesKey) == data)
        }
    }

    func profilesPreserveDPIAndRawLightingData() throws {
        try withSettings { app, _ in
            let stages = DPIStageSet(active: 2, stages: [DPIStage(x: 800, y: 900), DPIStage(x: 1600, y: 1700)])
            let light = ZoneLight(effect: [1, 4, 1, 0, 0, 1, 100, 150, 200, 0, 0, 0], brightness: 128)
            app.storeProfiles(["Custom": Profile(stages: stages, pollingRate: 500, lights: ["4": light])])
            let restored = try require(app.loadProfiles()["Custom"])
            try expect(restored.stages == stages)
            try expect(restored.pollingRate == 500)
            try expect(restored.lights["4"] == light)
        }
    }

    func legacySettingsDefaultToFixedShortcutsWithoutRewritingData() throws {
        try withSettings { app, defaults in
            let layouts = Data(#"{"Existing":[[1,64,0,2,1,0,30,0,0,0]]}"#.utf8)
            let profiles = Data(#"{"Legacy":{"lights":{}}}"#.utf8)
            defaults.set(layouts, forKey: app.layoutsKey)
            defaults.set(profiles, forKey: app.profilesKey)
            let preferences = try app.loadModifierPreferences()
            try expect(preferences.buttons.isEmpty && preferences.layouts.isEmpty)
            try expect(defaults.data(forKey: app.layoutsKey) == layouts)
            try expect(defaults.data(forKey: app.profilesKey) == profiles)
            try expect(defaults.data(forKey: app.modifierPreferencesKey) == nil)
        }
    }

    func modifierOptionsRoundTripSeparatelyFromHardwareAssignments() throws {
        try withSettings { app, defaults in
            let layouts = ["Existing": [RazerMouse.defaultArgs(0)]]
            app.storeLayouts(layouts)
            let before = defaults.data(forKey: app.layoutsKey)
            let preferences = ModifierPreferences(buttons: [0x40, 0x34, 2], layouts: [
                "Existing": [0x40], "Extra": [0x55],
            ])
            try app.storeModifierPreferences(preferences)
            try expect(try app.loadModifierPreferences() == preferences)
            try expect(defaults.data(forKey: app.layoutsKey) == before)
            try expect(app.loadLayouts() == layouts)
        }
    }

    func corruptedModifierSettingsReportADecodingError() throws {
        try withSettings { app, defaults in
            defaults.set(Data("not JSON".utf8), forKey: app.modifierPreferencesKey)
            do { _ = try app.loadModifierPreferences() }
            catch is DecodingError { return }
            throw TestFailure(description: "Corrupted modifier options must not be reported as successfully loaded")
        }
    }

    func loadingALegacyLayoutDisablesTheOptInMode() throws {
        try withSettings { app, _ in
            let args = RazerMouse.defaultArgs(0)
            let recorder = ReportRecorder()
            recorder.replies = [ReportRecorder.reply(args: args)]
            app.mouse = recorder.mouse()
            app.model.app = app
            app.model.buttons = [0x40: args]
            app.modifierPreferences.buttons = [0x40]
            app.model.physicalModifierButtons = [0x40]
            app.storeLayouts(["Legacy": [args]])
            app.model.loadLayout("Legacy")
            try waitUntil { app.model.busy == 0 }
            try expect(app.model.errorText == nil)
            try expect(app.model.physicalModifierButtons.isEmpty)
            try expect(try app.loadModifierPreferences().buttons.isEmpty)
        }
    }

    func disablingDoesNotRewriteHardwareBindings() throws {
        try withSettings { app, _ in
            let recorder = ReportRecorder()
            app.mouse = recorder.mouse()
            app.model.app = app
            app.model.buttons = [0x40: RazerMouse.defaultArgs(0)]
            app.modifierPreferences.buttons = [0x40]
            app.model.physicalModifierButtons = [0x40]
            app.model.applyButtonAssignments([], enabledButtons: [])
            try waitUntil { app.model.busy == 0 }
            try expect(app.model.physicalModifierButtons.isEmpty)
            try expect(!recorder.sent.contains { $0[6] == 2 && $0[7] == 0x0C })
        }
    }

    func ambiguousOptionsFailBeforeWritingHardwareOrPreferences() throws {
        try withSettings { app, _ in
            let recorder = ReportRecorder()
            app.mouse = recorder.mouse()
            app.model.app = app
            let args = RazerMouse.defaultArgs(0)
            app.model.buttons = [
                0x40: args, 0x41: RazerMouse.keyArgs(0x41, mod: 0, key: 0x1E),
            ]
            app.model.setButton(args, preservePhysicalModifiers: true)
            try expect(app.model.errorText != nil)
            try expect(recorder.sent.isEmpty)
            try expect(try app.loadModifierPreferences().buttons.isEmpty)
        }
    }

    func rejectedWritesRestoreThePreviousHardwareAssignment() throws {
        try withSettings { app, _ in
            let previous = RazerMouse.defaultArgs(0)
            let next = RazerMouse.keyArgs(0x40, mod: 1, key: 0x1F)
            let recorder = ReportRecorder()
            recorder.replies = [
                ReportRecorder.reply(status: 3, args: next), ReportRecorder.reply(args: previous),
            ]
            app.mouse = recorder.mouse()
            app.model.app = app
            app.model.buttons = [0x40: previous]
            app.model.setButton(next)
            try waitUntil { app.model.busy == 0 }
            try expect(app.model.errorText != nil)
            let writes = recorder.sent.filter { $0[6] == 2 && $0[7] == 0x0C }
            try expect(writes.count == 2)
            try expect(Array(writes[0][8..<18]) == next)
            try expect(Array(writes[1][8..<18]) == previous)
            try expect(try app.loadModifierPreferences().buttons.isEmpty)
        }
    }

    func sharedOutputsCanBeExplicitlyDisabledTogether() throws {
        try withSettings { app, _ in
            let first = RazerMouse.keyArgs(0x40, mod: 0, key: 0x1E)
            let second = RazerMouse.keyArgs(0x41, mod: 0, key: 0x1E)
            let recorder = ReportRecorder()
            recorder.replies = [ReportRecorder.reply(args: first)]
            app.mouse = recorder.mouse()
            app.model.app = app
            app.model.buttons = [0x40: first, 0x41: second]
            app.modifierPreferences.buttons = [0x40, 0x41]
            app.model.physicalModifierButtons = [0x40, 0x41]
            app.model.setButton(first, preservePhysicalModifiers: false, applyToMatchingButtons: true)
            try waitUntil { app.model.busy == 0 }
            try expect(app.model.errorText == nil)
            try expect(app.model.physicalModifierButtons.isEmpty)
            try expect(app.model.modifierStatus == "Physical modifiers off")
            try expect(recorder.sent.filter { $0[6] == 2 && $0[7] == 0x0C }.count == 1)
        }
    }

    func profileStorageDoesNotChangeModifierOptions() throws {
        try withSettings { app, defaults in
            let preferences = ModifierPreferences(buttons: [0x40], layouts: ["Custom": [0x40]])
            try app.storeModifierPreferences(preferences)
            let before = defaults.data(forKey: app.modifierPreferencesKey)
            app.storeProfiles(["Performance": Profile(stages: nil, pollingRate: 500, lights: [:])])
            try expect(app.loadProfiles()["Performance"]?.pollingRate == 500)
            try expect(defaults.data(forKey: app.modifierPreferencesKey) == before)
            try expect(try app.loadModifierPreferences() == preferences)
        }
    }
}
