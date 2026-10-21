import AppKit

// Runs the ported Wallpaper Engine renderer (`wpengine`, built by scripts/build-wpengine.sh) as one child process per
// screen. Each child owns a desktop-level, click-through window (see MacDesktopWindow.mm in the port) and reads the
// global cursor itself for parallax. Pausing is SIGSTOP/SIGCONT: the GPU work stops with the process.

@MainActor final class WPEngineRunner {
    /// Called once when a running child exits on its own (crash, bad scene), not when `stop()` ended it.
    var onUnexpectedExit: (@MainActor () -> Void)?
    private var processes: [Process] = []
    private var generation = 0

    /// Next to the host executable (bundled), `LIVEWALLPAPER_WPENGINE`, or the dev install location.
    static var binaryURL: URL? {
        let manager = FileManager.default
        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("wpengine"))
        }
        if let override = ProcessInfo.processInfo.environment["LIVEWALLPAPER_WPENGINE"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LiveWallpaper/bin/wpengine"))
        return candidates.first { manager.isExecutableFile(atPath: $0.path) }
    }

    var isRunning: Bool { processes.contains { $0.isRunning } }

    /// Starts one child per screen. `projectFolder` is the folder with project.json (and scene.pkg).
    /// Returns false when the binary is missing or a child could not be launched.
    func start(projectFolder: URL, assets: URL?, fps: Int) -> Bool {
        stop()
        guard let binary = Self.binaryURL else { return false }
        generation += 1
        let mine = generation
        let screens = NSScreen.screens
        guard let primary = screens.first else { return false }
        var started: [Process] = []
        for screen in screens {
            let frame = screen.frame
            // GLFW window coordinates: points, origin at the top left of the primary display.
            let geometry = "\(Int(frame.minX))x\(Int(primary.frame.maxY - frame.maxY))x\(Int(frame.width))x\(Int(frame.height))"
            var arguments = ["--window", geometry, "--scaling", "fill", "--no-fullscreen-pause", "--silent",
                             "--fps", String(max(1, min(fps, 120)))]
            if let assets { arguments += ["--assets-dir", assets.path] }
            arguments.append(projectFolder.path)
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["XDG_SESSION_TYPE"] = "x11"   // the port has a single driver, registered under this name
            // Many scenes switch camera parallax on but author an amount of 0 (the mouse then does nothing); give
            // those a usable amount. A scene's own non-zero amount wins. The renderer zooms the scene a little while
            // parallax is on and never shifts a layer past that margin, so a large amount cannot show the scene edge.
            environment["WPENGINE_PARALLAX_FALLBACK"] = "0.35"
            // Scenes are GPU heavy (4000+ px layers with several effect passes each); at full size one can keep the
            // GPU near 100% and starve the window server, which makes the whole desktop lag. Effect buffers at 60%.
            environment["WPENGINE_LAYER_SCALE"] = "0.6"
            process.environment = environment
            process.qualityOfService = .utility   // foreground apps win the CPU when both are busy
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == mine else { return }
                    self.stop()
                    self.onUnexpectedExit?()
                }
            }
            do { try process.run() } catch {
                for other in started { other.terminate() }
                return false
            }
            started.append(process)
        }
        processes = started
        return true
    }

    func stop() {
        generation += 1   // children that die from here on were asked to
        for process in processes where process.isRunning {
            kill(process.processIdentifier, SIGCONT)   // a stopped process cannot handle SIGTERM
            process.terminate()
        }
        processes = []
    }

    func setPaused(_ paused: Bool) {
        for process in processes where process.isRunning {
            kill(process.processIdentifier, paused ? SIGSTOP : SIGCONT)
        }
    }
}
