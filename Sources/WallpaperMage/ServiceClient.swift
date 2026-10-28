import AppKit
import ServiceManagement
import Core

// The UI's only link to the background service (WallpaperMageService): one ServiceSocketClient connection to
// ServiceSocket.path. When nothing answers, the UI launches the nested service app itself (no launchd), sends
// ServiceCommands and publishes the ServiceStatus it reports.

struct ServiceError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

@MainActor final class ServiceClient: ObservableObject {
    static let shared = ServiceClient()

    enum State: Equatable {
        case unknown          // not started
        case connecting       // launching / waiting for the first answer
        case connected
        case unavailable      // the service could not be started or does not answer; see `problem`
    }

    /// Why the service is unavailable. It stays while the client keeps trying, until the service answers.
    enum Problem: Equatable {
        case missing          // the service app is not inside this copy of Wallpaper Mage
        case didNotStart      // it was launched but never answered
        case noAnswer         // it does not answer on its socket
    }

    @Published private(set) var status: ServiceStatus?
    @Published private(set) var problem: Problem?
    @Published private(set) var state: State = .unknown
    /// A restart is under way: from asking the service to quit until a fresh one answers or fails.
    @Published private(set) var isRestarting = false

    private var connection: ServiceSocketClient?
    private var connecting: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var legacyLoginItemChecked = false
    private var quitRequested = false   // the service was asked to quit (restart): its going away is no crash

    /// <WallpaperMage.app>/Contents/Library/LoginItems/WallpaperMageService.app
    private static let serviceApp = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Library/LoginItems/WallpaperMageService.app", isDirectory: true)

    // MARK: Lifecycle

    /// Connects (launching the service if needed) and asks for the status. Idempotent while connecting.
    func start() {
        quitRequested = false
        begin(launch: true)
    }

    private func begin(launch: Bool) {
        retry?.cancel()
        guard connection == nil, connecting == nil else { return }
        if launch { state = .connecting }
        connecting = Task { @MainActor [weak self] in
            await self?.connect(launch: launch)
            if !Task.isCancelled { self?.connecting = nil }
        }
    }

    func stop() {
        retry?.cancel()
        connecting?.cancel()
        connecting = nil
        connection?.close()
        connection = nil
    }

    /// Quits the service, then connects again (which launches a fresh copy).
    func restart() async {
        isRestarting = true
        await quit()
        stop()
        status = nil
        start()
    }

    /// Asks the service to quit and waits until its process has ended (at most 5 s): while it is still running,
    /// opening the service app would only find the old copy.
    func quit() async {
        _ = try? await perform(.quit)
        var waited = 0
        while waited < 50, NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.serviceBundleID)
            .contains(where: { !$0.isTerminated }) {
            waited += 1
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func connect(launch: Bool) async {
        let path = ServiceSocket.path
        if !(await Self.isServing(path)) {
            guard launch else { return retryLater() }
            guard launchService() else { return }
            var waited = 0
            while !(await Self.isServing(path)) {
                waited += 1
                guard waited <= 20, !Task.isCancelled else {
                    return fail(.didNotStart, "it did not answer within 5 seconds")
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        guard !Task.isCancelled else { return }
        let client = ServiceSocketClient(
            onStatus: { data in
                guard let status = ServiceCoding.decode(ServiceStatus.self, from: data) else { return }
                Task { @MainActor in ServiceClient.shared.adopt(status) }
            },
            onDisconnect: {
                Task { @MainActor in ServiceClient.shared.lost() }
            })
        do {
            try await Self.offMain { try client.connect(path: path) }
        } catch {
            return fail(.noAnswer, error.localizedDescription)
        }
        connection = client
        await refreshStatus()
        removeLegacyLoginItem()
    }

    /// False (and `.unavailable`) when the service app cannot be found or opened.
    private func launchService() -> Bool {
        guard FileManager.default.fileExists(atPath: Self.serviceApp.path) else {
            fail(.missing, Self.serviceApp.path)
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: Self.serviceApp, configuration: configuration) { _, error in
            if let error { NSLog("WallpaperMage: couldn’t launch the service: \(error.localizedDescription)") }
        }
        return true
    }

    /// The service opens at login only through its own login item, which the user turns on (Start on Launch,
    /// LoginItem in the service). Older versions registered the service as a login item of this app on every launch;
    /// that one is removed, checked once per launch in the background (a read of its status takes about 15 ms).
    private func removeLegacyLoginItem() {
        guard !legacyLoginItemChecked else { return }
        legacyLoginItemChecked = true
        Task.detached(priority: .utility) {
            let item = SMAppService.loginItem(identifier: AppIdentity.serviceBundleID)
            guard item.status == .enabled || item.status == .requiresApproval else { return }
            do { try await item.unregister() } catch {
                NSLog("WallpaperMage: couldn’t remove the service’s old login item: \(error.localizedDescription)")
            }
        }
    }

    /// Blocking socket calls stay off the main thread.
    private static func offMain(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await Task.detached(priority: .userInitiated) { try body() }.value
    }

    private static func isServing(_ path: String) async -> Bool {
        await Task.detached(priority: .userInitiated) { ServiceSocket.isServing(at: path) }.value
    }

    // MARK: Commands

    @discardableResult
    func perform(_ command: ServiceCommand) async throws -> ServiceStatus {
        guard let connection else { throw ServiceError(String(localized: "The wallpaper service isn’t connected.")) }
        if case .quit = command { quitRequested = true }
        let data = try await connection.send(command: ServiceCoding.encode(command))
        guard let result = ServiceCoding.decode(ServiceStatus.self, from: data) else {
            throw ServiceError(String(localized: "The wallpaper service sent an unreadable answer."))
        }
        adopt(result)
        return result
    }

    func refreshStatus() async {
        do { try await perform(.status) } catch { fail(.noAnswer, error.localizedDescription) }
    }

    // MARK: Connection

    private func adopt(_ new: ServiceStatus) {
        guard connection != nil else { return }   // a push that raced stop()
        status = new
        state = .connected
        problem = nil
        isRestarting = false
        retry?.cancel()
    }

    /// The service went away: relaunch it after a crash, only watch for it while a restart brings it back.
    private func lost() {
        connection = nil
        status = nil
        state = .connecting
        retryLater()
    }

    private func fail(_ problem: Problem, _ detail: String) {
        NSLog("WallpaperMage: wallpaper service unavailable (\(problem)): \(detail)")
        connection?.close()
        connection = nil
        self.problem = problem
        state = .unavailable
        isRestarting = false
        retryLater()
    }

    /// Tries again every 3 s until the service answers.
    private func retryLater() {
        retry?.cancel()
        retry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.state != .connected else { return }
            self.begin(launch: !self.quitRequested)
        }
    }
}
