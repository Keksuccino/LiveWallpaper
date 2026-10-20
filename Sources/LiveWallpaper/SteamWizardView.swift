import SwiftUI
import Core

// Owner: SETTINGS. The Steam sign-in wizard (SPEC3.md section 6.4), replacing the phase-2 SteamSetupView inside
// the "Steam Setup" tab: cards for Install tools -> (Rosetta) -> Sign in (username, password, Steam Guard) ->
// Ownership -> done, plus Sign out and the optional shared-assets card. It only reads `SteamSetupModel` (owner
// STEAM) and calls its methods; it holds the typed password in @State, clears it on submit and never logs it.
// This file is a stub with the final type. It is not wired into the tabs yet.

@MainActor
struct SteamWizardView: View {
    @ObservedObject var setup: SteamSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Steam Setup").font(.title2)
            Text("\(String(describing: setup.step))").foregroundStyle(.secondary)
        }
        .padding(16)
        .onAppear { setup.refresh() }
    }
}
