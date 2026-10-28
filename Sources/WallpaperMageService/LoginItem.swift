import Foundation
import ServiceManagement

/// Start on Launch: the service's own login item (`SMAppService.mainApp` of the service's bundle, listed in System
/// Settings > General > Login Items under Open at Login), so the service, not Settings, opens when the user logs in.
/// Off until the user turns it on, in Settings > General or the menu bar. macOS keeps the registration and there is
/// no copy of the choice that could disagree with it; `refresh` picks up a change made in System Settings.
///
/// Every read of the registration is a call to the system that takes about 15 ms, so only `init` and `set` (a user's
/// click, whose reply has to carry the result) read on the main thread; `refresh` reads in the background.
@MainActor final class LoginItem {
    /// Whether the service opens at login, as of the last read.
    private(set) var isEnabled: Bool
    /// Called when a `refresh` found that the registration changed.
    var onChange: (() -> Void)?

    /// Counts `set` calls, so a background read that started before one cannot overwrite its result.
    private var generation = 0
    private var isReading = false

    init() { isEnabled = Self.readIsEnabled() }

    /// Reads the registration again in the background; `onChange` follows when it changed.
    func refresh() {
        guard !isReading else { return }
        isReading = true
        let generation = self.generation
        Task.detached(priority: .userInitiated) { [weak self] in
            let enabled = Self.readIsEnabled()
            await self?.adopt(enabled, readAt: generation)
        }
    }

    /// Turns opening at login on or off; returns a user-facing message when that failed. When macOS wants the user
    /// to allow it first, System Settings opens at Login Items instead.
    func set(_ enabled: Bool) -> String? {
        generation += 1
        let service = SMAppService.mainApp
        var failure: Error?
        do {
            switch (enabled, service.status) {
            case (true, .enabled), (false, .notRegistered), (false, .notFound): break
            case (true, _): try service.register()
            case (false, _): try service.unregister()
            }
        } catch {
            failure = error
        }
        let status = service.status
        isEnabled = status == .enabled
        if enabled, status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return nil
        }
        guard let failure, isEnabled != enabled else { return nil }
        NSLog("WallpaperMageService: couldn’t \(enabled ? "register" : "unregister") the login item: \(failure.localizedDescription)")
        return String(localized: "Couldn’t change whether Wallpaper Mage starts when you log in. \(failure.localizedDescription)")
    }

    private func adopt(_ enabled: Bool, readAt generation: Int) {
        isReading = false
        guard generation == self.generation, enabled != isEnabled else { return }
        isEnabled = enabled
        onChange?()
    }

    private nonisolated static func readIsEnabled() -> Bool { SMAppService.mainApp.status == .enabled }
}
