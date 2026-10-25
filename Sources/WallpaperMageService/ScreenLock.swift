import AppKit
import Core

/// Reports when the screen locks and unlocks; the desktop stops drawing and playing sound while it is locked.
/// Distributed notifications are held back while the app is in the background unless delivery is immediate, and an
/// unlock arrives exactly then.
final class ScreenLockObserver: NSObject {
    private let onChange: @MainActor (Bool) -> Void

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        super.init()
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(locked), name: Notification.Name("com.apple.screenIsLocked"),
                           object: nil, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(unlocked), name: Notification.Name("com.apple.screenIsUnlocked"),
                           object: nil, suspensionBehavior: .deliverImmediately)
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    @objc private func locked() { Task { @MainActor [onChange] in onChange(true) } }
    @objc private func unlocked() { Task { @MainActor [onChange] in onChange(false) } }
}

/// Older versions played a video on the lock screen by swapping it into Apple's downloaded Aerials, rendered scenes
/// into video loops for it and set stills of their own. The lock screen now shows the system wallpaper, which
/// WallpaperStills keeps a still of the desktop. This puts Apple's Aerials back and deletes the leftovers. It finds
/// nothing to do on a Mac that never ran such a version, so it runs at every launch.
enum LegacyLockScreen {
    private static let temporaryPrefix = "wallpapermage-lockscreen-"

    static func cleanUp(library: [VideoItem]) {
        restoreAerials()
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: AppPaths.legacyStillsDirectory)
        let temporary = (try? fileManager.contentsOfDirectory(at: fileManager.temporaryDirectory,
                                                              includingPropertiesForKeys: nil)) ?? []
        for file in temporary where file.lastPathComponent.hasPrefix(temporaryPrefix) {
            try? fileManager.removeItem(at: file)
        }
        // A scene's loop (lock-<W>x<H>.mov), its metadata (.json) and an unfinished one lie next to the scene file.
        for folder in Set(library.filter(\.isScene).map { $0.url.deletingLastPathComponent() }) {
            let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files
            where file.lastPathComponent.wholeMatch(of: #/lock-\d+x\d+\.(?:mov|json|partial\.mov)/#) != nil {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    /// Puts Apple's Aerial files back from Backups/. Originals waiting there count even when no record survived, so
    /// nothing can be stranded; whatever fails stays in the record and is tried again at the next launch.
    private static func restoreAerials() {
        let pending = Set(AgentRecordStore.load().aerialSlots).union(AgentRecordStore.backupSlotsOnDisk()).sorted()
        guard !pending.isEmpty else { return }
        let failed = pending.filter { slot in
            let backup = AppPaths.backupsDirectory.appendingPathComponent(slot)
            return FileManager.default.fileExists(atPath: backup.path)
                && (try? place(backup, at: AppPaths.aerialVideosDirectory.appendingPathComponent(slot))) == nil
        }
        AgentRecordStore.update { $0.aerialSlots = failed }
        guard failed.isEmpty else { return }
        // The wallpaper processes keep the swapped files open; restarted, they load Apple's again.
        killall("WallpaperAerialsExtension", "WallpaperAgent")
    }

    /// Moves `file` to `destination`, atomically replacing what is there.
    private static func place(_ file: URL, at destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: file)
        } else {
            try FileManager.default.moveItem(at: file, to: destination)
        }
    }

    private static func killall(_ names: String...) {
        for name in names {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = [name]
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { process.waitUntilExit() }
        }
    }
}
