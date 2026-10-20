import Foundation
import Combine
import Core

// Owner: STEAM. The Steam sign-in wizard backend (SPEC3.md section 4): installs Valve's SteamCMD itself, signs the
// user in through a pseudo-terminal, checks that the account owns Wallpaper Engine, signs out, and fetches the
// shared assets. The views (SteamWizardView.swift, owner SETTINGS) consume `SteamSetupModel` only.
//
// Rules (non-negotiable, SPEC3.md 0 and 4.1):
//  - SteamCMD is downloaded from Valve at the user's request, never bundled or re-hosted.
//  - The password and Steam Guard code travel only through the pty to steamcmd. They are never in argv, in the
//    environment, in a file, in UserDefaults, in the log, or in any @Published property. Captured output is
//    scrubbed of ANSI codes and of every occurrence of the secret before anything else sees it.
//  - Only the user's own account, only Valve's SteamCMD. No anonymous login, no third-party downloaders.
// This file is a stub with the final types and signatures. `SteamPromptClassifier` is pure and must stay free of
// AppKit/SwiftUI so the Linux harness can test it (SPEC3.md 4.4 has the test vectors).

enum SteamArch: String, Equatable {
    case arm64, x86_64, universal, unknown
}

struct SteamToolsInfo: Equatable {
    var path: String                 // absolute path of steamcmd.sh (the launcher) to run
    var arch: SteamArch              // of the real binary, from `lipo -archs`
    var managedByApp: Bool           // installed by this app into AppPaths.steamToolsDirectory
}

enum SteamInstallStep: Equatable {
    case downloading(fraction: Double?)   // nil = size unknown
    case extracting
    case firstRun(note: String)           // SteamCMD updates itself on its first start; can take minutes
    case checking                         // lipo + Rosetta test
}

enum SteamToolsState: Equatable {
    case unknown
    case missing                          // nothing usable found
    case installing(SteamInstallStep)
    case rosettaRequired                  // x86_64-only binary, Apple silicon Mac, Rosetta not installed
    case ready(SteamToolsInfo)
    case failed(SteamSetupError)
}

enum SteamCodeKind: Equatable {
    case email                            // "a code was sent to your email"
    case authenticator                    // Steam Mobile app code
    case unknown                          // a Steam Guard prompt we could not classify: ask for "the code"
}

enum SteamSignInStep: Equatable {
    case starting                         // steamcmd launched, waiting for the first prompt
    case working(String)                  // after the password / code was sent: "Signing in…"
    case needsCode(SteamCodeKind, previousWasWrong: Bool)
    case needsMobileApproval              // "approve the sign-in in the Steam Mobile app"; the app keeps waiting
    case unrecognizedPrompt(lastLines: String)   // fallback: nothing matched for 20 s; text is scrubbed
}

enum SteamAccountState: Equatable {
    case unknown
    case checking
    case signedOut                        // no cached login
    case signingIn(SteamSignInStep)
    case signedIn(username: String)       // steamcmd accepted its cached login token
}

enum SteamOwnershipState: Equatable {
    case unknown
    case checking
    case owned
    case notOwned
    case couldNotCheck(String)            // user-facing reason; downloads may still work
}

enum SteamAssetsState: Equatable {
    case unknown
    case notFetched
    case discovering                      // reading app info to find the depot
    case needsConfirmation(downloadBytes: Int64, depotName: String)   // shown before the big download
    case fetching(fraction: Double?)
    case ready(folder: String)
    case unavailable(String)              // discovery found no usable depot (UNVERIFIED territory)
    case failed(SteamSetupError)
}

/// The step the wizard shows. Derived from the four states above by `SteamSetupModel.step`.
enum SteamWizardStep: Equatable {
    case installTools, fixRosetta, signIn, checkOwnership, done
}

enum SteamSetupError: Error, Equatable {
    case downloadFailed(String)           // fetching steamcmd_osx.tar.gz
    case extractFailed(String)
    case toolsBroken(String)              // no executable / unreadable architecture after install
    case rosettaMissing
    case firstRunFailed(String)
    case badPassword
    case badCode
    case rateLimited
    case guardTimedOut                    // no code / approval within the window
    case unrecognizedPrompt(String)
    case loginFailed(String)              // any other FAILED line from steamcmd (scrubbed)
    case processFailed(String)
    case timedOut
    case cancelled
    case diskSpace(neededBytes: Int64)
    case assetsFailed(String)

    /// Bold line.
    var title: String {
        switch self {
        case .downloadFailed: return "Couldn’t download Steam’s command-line tool"
        case .extractFailed, .toolsBroken: return "The Steam tool didn’t install correctly"
        case .rosettaMissing: return "Rosetta is needed"
        case .firstRunFailed: return "Steam’s tool couldn’t finish its first start"
        case .badPassword: return "Steam didn’t accept that password"
        case .badCode: return "That Steam Guard code didn’t work"
        case .rateLimited: return "Steam is asking you to wait"
        case .guardTimedOut: return "Steam Guard timed out"
        case .unrecognizedPrompt: return "Steam is waiting for something unexpected"
        case .loginFailed: return "Steam sign-in failed"
        case .processFailed: return "The Steam tool stopped unexpectedly"
        case .timedOut: return "Steam took too long to answer"
        case .cancelled: return "Cancelled"
        case .diskSpace: return "Not enough free disk space"
        case .assetsFailed: return "Couldn’t get Wallpaper Engine’s shared files"
        }
    }

    /// Secondary line (exact copy: SPEC3.md 4.6).
    var message: String {
        switch self {
        case .downloadFailed(let detail): return "Check your internet connection and try again. (\(detail))"
        case .extractFailed(let detail), .toolsBroken(let detail): return "Remove it in Steam Setup and install it again. (\(detail))"
        case .rosettaMissing: return "Steam’s tool is built for Intel Macs. Install Rosetta, then try again."
        case .firstRunFailed(let detail): return "Try again. If it keeps failing, remove the tool and reinstall. (\(detail))"
        case .badPassword: return "Check the password and try again. After several wrong tries Steam makes you wait."
        case .badCode: return "Enter the newest code. Codes from the Steam Mobile app change every 30 seconds."
        case .rateLimited: return "Too many sign-in attempts. Wait about 30 minutes before trying again."
        case .guardTimedOut: return "No code or approval arrived in time. Start again."
        case .unrecognizedPrompt: return "Steam sent a prompt this app doesn’t know. Details are below; you can also sign in using Terminal."
        case .loginFailed(let line): return "Steam said: \(line)"
        case .processFailed(let detail): return "Try again. (\(detail))"
        case .timedOut: return "Check your connection and try again."
        case .cancelled: return ""
        case .diskSpace(let bytes): return "About \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of free space is needed."
        case .assetsFailed(let detail): return detail
        }
    }
}

/// What the text coming out of steamcmd's pty means. Pure and tolerant (SPEC3.md 4.4): lower-cased substring and
/// small regex matching on the last ~2 KB of scrubbed output, first match in the order of the table wins.
enum SteamPrompt: Equatable {
    case none
    case passwordPrompt
    case guardCode(SteamCodeKind)
    case mobileApproval
    case badPassword
    case badCode
    case rateLimited
    case signedIn
    case failed(String)          // other "FAILED" / "ERROR!" line, scrubbed
    case rosettaMissing          // "Bad CPU type"
}

enum SteamPromptClassifier {
    /// `tail` is the most recent output with ANSI sequences and carriage-return redraws already resolved.
    static func classify(_ tail: String) -> SteamPrompt {
        .none
    }
}

// MARK: - Model

@MainActor final class SteamSetupModel: ObservableObject {
    static let shared = SteamSetupModel()

    @Published private(set) var tools: SteamToolsState = .unknown
    @Published private(set) var account: SteamAccountState = .unknown
    @Published private(set) var ownership: SteamOwnershipState = .unknown
    @Published private(set) var assets: SteamAssetsState = .unknown
    /// Persisted (UserDefaults); not secret. Shown pre-filled in the sign-in form.
    @Published var username: String = ""

    /// Which wizard card to show.
    var step: SteamWizardStep {
        switch tools {
        case .unknown, .missing, .installing, .failed: return .installTools
        case .rosettaRequired: return .fixRosetta
        case .ready: break
        }
        guard case .signedIn = account else { return .signIn }
        return ownership == .owned ? .done : .checkOwnership
    }

    /// Workshop downloads may start (tools ready and a cached login). Ownership `.couldNotCheck` still allows it.
    var canDownload: Bool {
        guard case .ready = tools, case .signedIn = account else { return false }
        return ownership != .notOwned
    }

    /// The steamcmd launcher to use for Workshop downloads, nil until tools are ready.
    var steamcmdPath: String? {
        if case .ready(let info) = tools { return info.path }
        return nil
    }

    init() {}

    /// Cheap, no network: look for the app-managed SteamCMD, then the Homebrew / manual locations of phase 2,
    /// run `lipo -archs`, test Rosetta (`arch -x86_64 /usr/bin/true`), and see whether a cached login exists.
    func refresh() {
        tools = .missing
        account = .signedOut
    }

    /// Downloads steamcmd_osx.tar.gz from Valve, extracts it into AppPaths.steamToolsDirectory, runs it once
    /// (`+quit`) so it can update itself, then checks the architecture. Reports `.installing(step)`.
    func installTools() {}

    func cancelInstall() {}

    /// Starts `steamcmd +login <username>` under a pty and drives the prompts. The password is sent when its
    /// prompt appears and then dropped. Moves `account` through `.signingIn(step)` to `.signedIn` or back to
    /// `.signedOut` with the error in `lastError`.
    func signIn(username: String, password: String) {}

    /// Sends the Steam Guard code to the waiting prompt (or to the next one if Steam asks again).
    func submitGuardCode(_ code: String) {}

    func cancelSignIn() {}

    /// Logs out and removes the cached login that lives under AppPaths.steamHomeDirectory. Never touches the
    /// user's own Steam installation.
    func signOut() {}

    /// Checks that the signed-in account owns Wallpaper Engine (app 431960). Sets `ownership`.
    func checkOwnership() {}

    /// Optional: discovers the depot with Wallpaper Engine's shared assets (`+app_info_print 431960`), asks for
    /// confirmation (`.needsConfirmation`), then downloads it into AppPaths.sharedAssetsDirectory.
    func prepareSharedAssets() {}
    func confirmSharedAssets() {}
    func removeSharedAssets() {}

    /// The last error, for the card to show; cleared when a new action starts.
    @Published private(set) var lastError: SteamSetupError?
}
