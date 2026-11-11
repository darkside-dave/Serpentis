import Foundation
import ApplicationServices

extension AppDelegate {
    var modifierPreferencesKey: String { "physicalModifierPreferences" }

    func requestInputPermissions() {
        _ = CGRequestListenEventAccess()
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    func loadModifierPreferences() throws -> ModifierPreferences {
        guard let data = settingsDefaults.data(forKey: modifierPreferencesKey) else { return ModifierPreferences() }
        return try JSONDecoder().decode(ModifierPreferences.self, from: data)
    }

    func storeModifierPreferences(_ preferences: ModifierPreferences) throws {
        let data = try JSONEncoder().encode(preferences)
        settingsDefaults.set(data, forKey: modifierPreferencesKey)
    }

    func saveModifierLayout(_ name: String) {
        modifierPreferences.layouts[name] = modifierPreferences.buttons
        persistModifierPreferences()
    }

    func deleteModifierLayout(_ name: String) {
        modifierPreferences.layouts[name] = nil
        persistModifierPreferences()
    }

    func persistModifierPreferences() {
        do { try storeModifierPreferences(modifierPreferences) }
        catch { model.errorText = "Could not save physical-modifier options: \(error.localizedDescription)" }
        model.physicalModifierButtons = modifierPreferences.buttons
    }
}
