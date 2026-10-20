import Foundation

// Owner: STEAM. One interactive steamcmd run under a pseudo-terminal (SPEC3.md section 4.3). Foundation + Darwin
// only (no AppKit/SwiftUI) so the harness can typecheck it. Design:
//  - posix_openpt / grantpt / unlockpt / ptsname give a master fd and a slave path; `Process` gets the slave as
//    stdin, stdout and stderr (three FileHandles on the same slave), TERM=dumb, HOME=AppPaths.steamHomeDirectory.
//  - Plan B if steamcmd insists on a controlling terminal (UNVERIFIED): run `/usr/bin/script -q /dev/null
//    <steamcmd> ...` with ordinary pipes; `script` allocates the pty. Same interface.
//  - Before the secret is written, `tcgetattr` on the master must show ECHO off; if it is on, turn it off
//    (`tcsetattr`) first. Output is scrubbed (ANSI removed, '\r' redraws resolved, every occurrence of the secret
//    replaced by "••••") BEFORE it reaches `onOutput`.
//  - The secret is a [UInt8] that is overwritten with zeros right after the write.

struct SteamCommandLine {
    var executable: String           // absolute path to steamcmd.sh
    var arguments: [String]          // never contains a password
    var environment: [String: String]
}

final class SteamPTYSession: @unchecked Sendable {
    /// Scrubbed text as it arrives (any thread).
    var onOutput: (@Sendable (String) -> Void)?
    /// Exit status once the process ended (any thread).
    var onExit: (@Sendable (Int32) -> Void)?

    init(command: SteamCommandLine) {}

    /// Opens the pty, launches the process. Throws POSIX/Process errors (message contains no secrets).
    func start() throws {
        throw CocoaError(.featureUnsupported)
    }

    /// Writes `text` + "\n" to the pty and wipes the buffer. `secret` true registers the text for scrubbing.
    func sendLine(_ text: inout [UInt8], secret: Bool) {}

    /// SIGTERM, then SIGKILL after 2 s. Idempotent.
    func terminate() {}
}
