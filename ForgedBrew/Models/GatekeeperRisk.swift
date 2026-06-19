//
//  GatekeeperRisk.swift
//  ForgedBrew
//
//  A Homebrew-managed cask app that macOS Gatekeeper currently REJECTS, and
//  that is therefore at risk from an upcoming Homebrew change.
//
//  The change: Homebrew is removing the `--no-quarantine` option for casks and,
//  as of September 1, 2026, is ending support for any cask that fails Gatekeeper
//  checks. Today Homebrew quietly works around the "downloaded from the
//  internet" quarantine flag during install/upgrade; once that goes away, an app
//  that Gatekeeper won't accept on its own will hit the "can't be opened"
//  wall. See Homebrew/brew#20755 (closed via #20973).
//
//  ForgedBrew surfaces those at-risk apps PROACTIVELY in the Maintenance tab's
//  Trust Maintenance card so the user can clear the quarantine flag now, on the
//  apps they trust, rather than discovering the breakage later. The trust action
//  is the same one macOS documents: `xattr -d com.apple.quarantine <app>` (no
//  sudo), which BrewCLIService.removeQuarantine(at:) already runs.
//
//  Authoritative signal: `spctl --assess --type execute` (the exact check
//  Gatekeeper performs at launch). We reuse BrewCLIService.scanAppSecurity, so a
//  risk here is the same verdict the Security Scan would show — we list EVERY
//  Gatekeeper-rejected cask app (the apps that would actually break on Sept 1),
//  and record per-app which of the trust checks fail and whether a quarantine
//  flag is currently present (i.e. whether the local "Trust" action can do
//  anything right now).
//

import Foundation

// One installed cask app that Gatekeeper would reject today. `nonisolated` +
// Sendable so it can cross the actor boundary from BrewCLIService (an actor) up
// to the @MainActor UI without isolation warnings under the project's
// MainActor-default isolation.
nonisolated struct GatekeeperRisk: Identifiable, Sendable, Hashable {
    // The .app bundle path is unique per installed app, so it doubles as the
    // stable identity and is exactly what we pass to `xattr -d` to clear the
    // quarantine flag.
    var id: String { appPath }

    // Homebrew cask token, e.g. "google-chrome". Shown for context.
    let token: String

    // Human-facing app name from the bundle, e.g. "Google Chrome".
    let appName: String

    // Absolute path to the .app bundle, e.g. "/Applications/Google Chrome.app".
    // Used for Reveal in Finder and as the target of the trust action.
    let appPath: String

    // Why Gatekeeper rejects it, in plain language, derived from the security
    // scan. Lets the user judge whether they trust the app before clearing the
    // flag (e.g. "Unsigned", "Not notarized", "Signature invalid").
    let reason: String

    // The specific trust checks this app FAILS, each as a short label
    // ("Signature invalid", "No Developer ID", "Not notarized"). Shown per-app
    // so the user can see exactly what would make it fail Gatekeeper on Sept 1,
    // rather than a single collapsed reason. Always non-empty for a listed risk.
    let failedChecks: [String]

    // The signing authority string, when present (e.g. "Developer ID
    // Application: Foo Bar (ABCDE12345)"). nil for unsigned apps. Extra context
    // shown beneath the app name.
    let signingAuthority: String?

    // Whether the bundle currently carries the com.apple.quarantine flag.
    //   • true  → the local "Trust" action (xattr -d com.apple.quarantine) can
    //             clear the flag now and keep the app launching.
    //   • false → there is no flag to remove right now, so the Trust action
    //             would be a no-op. The app is still AT RISK (Gatekeeper
    //             rejects it) and is shown as a watch-only item.
    let isQuarantined: Bool

    // True when there is something the user can act on locally right now: the
    // app is Gatekeeper-rejected AND still carries the quarantine flag, so
    // clearing it keeps the app launching. Drives whether the row shows a Trust
    // button or an informational "watch for Sept 1" note.
    var actionable: Bool { isQuarantined }
}

// Translates a rejected AppSecurityResult into the plain-language reason shown
// in the Trust Maintenance row. Kept here (not in the View) so the wording is
// testable and lives next to the model it describes.
nonisolated enum GatekeeperRiskReason {
    static func describe(codesignValid: Bool,
                         teamIdentifier: String?,
                         notarized: Bool,
                         signingAuthority: String?) -> String {
        if signingAuthority == nil || signingAuthority?.isEmpty == true {
            return "Unsigned — macOS can’t verify who made it"
        }
        if !codesignValid {
            return "Signature invalid or tampered"
        }
        if (teamIdentifier?.isEmpty ?? true) {
            return "No Developer ID — not from an identified developer"
        }
        if !notarized {
            return "Not notarized by Apple"
        }
        return "Gatekeeper rejects this app"
    }

    // The full list of trust checks an app FAILS, in the order shown. Unlike
    // `describe` (which collapses to the single most important reason), this
    // returns every failing check so the Trust Maintenance row can show, per
    // app, exactly which parts of the trust scan would not pass on Sept 1.
    // Always returns at least one entry for a Gatekeeper-rejected app; falls
    // back to a generic line if none of the specific checks tripped.
    static func failingChecks(codesignValid: Bool,
                              teamIdentifier: String?,
                              notarized: Bool,
                              signingAuthority: String?) -> [String] {
        var checks: [String] = []
        let unsigned = (signingAuthority == nil || signingAuthority?.isEmpty == true)
        if unsigned {
            checks.append("Unsigned")
        } else if !codesignValid {
            checks.append("Signature invalid")
        }
        if !unsigned, (teamIdentifier?.isEmpty ?? true) {
            checks.append("No Developer ID")
        }
        if !notarized {
            checks.append("Not notarized")
        }
        return checks.isEmpty ? ["Rejected by Gatekeeper"] : checks
    }
}

// The result of one Trust Maintenance scan: the at-risk apps plus when it ran,
// so the UI doesn't recompute on every redraw.
nonisolated struct GatekeeperRiskScanResult: Sendable, Hashable {
    let risks: [GatekeeperRisk]
    let scannedAt: Date

    var isEmpty: Bool { risks.isEmpty }
    var count: Int { risks.count }

    // Apps the user can act on locally right now: Gatekeeper-rejected AND still
    // carrying the quarantine flag, so the Trust button clears it and keeps the
    // app launching.
    var actionable: [GatekeeperRisk] { risks.filter(\.actionable) }

    // Apps that are at risk (Gatekeeper-rejected) but have no quarantine flag to
    // clear right now — informational "watch for Sept 1" items, no Trust button.
    var watchOnly: [GatekeeperRisk] { risks.filter { !$0.actionable } }

    static let empty = GatekeeperRiskScanResult(risks: [], scannedAt: .distantPast)
}
