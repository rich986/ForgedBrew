//
//  MaintenanceView.swift
//  ForgedBrew
//
//  The "Maintenance" tab — ForgedBrew's catch-all for keeping a Homebrew
//  installation healthy. It is two things stacked together:
//
//   1. `MaintenanceMetrics` — a @MainActor @Observable view-model that owns ALL
//      of the screen's asynchronously-probed state: the brew-doctor report,
//      cache sizes, Homebrew's own version, plus the results of every on-demand
//      scan (orphans, duplicates, disk footprint, quarantine, adopt candidates,
//      local security scan, network CVE scan, and the Gatekeeper "trust" scan).
//      Each probe is best-effort and degrades to a neutral state on failure;
//      none of them throws into the UI. The scans share a few recurring
//      patterns worth knowing before reading the methods:
//        • a `scanning` Bool flag (drives spinners / disables buttons), cleared
//          on every exit path — several use `defer` so a Task cancelled when its
//          sheet is dismissed mid-scan can never leave the flag stuck true;
//        • a re-entrancy guard (`guard !scanning`) so overlapping Tasks don't
//          fight over the live progress counters;
//        • live progress callbacks (scanned / total / current-item) that the
//          service invokes on the main actor so the sheet updates app-by-app;
//        • per-row error dictionaries keyed by token / path / install-id so a
//          failed action surfaces its reason inline instead of being swallowed.
//
//   2. `MaintenanceView` and its sheets/cards — the SwiftUI surface. The body is
//      a grid of one-tap "action cards"; each heavier task opens a dedicated
//      sheet (Quarantine, Adopt, Duplicates, Orphans, Disk Usage, Security,
//      Vulnerability, Trust) bound to the shared `MaintenanceMetrics`.
//
//  Scan-result persistence & freshness: the Security and Trust scans are slow,
//  so their last completed report is written to Application Support and reloaded
//  on init. Reopening a scan screen (or relaunching the app) shows the saved
//  results immediately; a scan only auto-re-runs once its result is older than
//  `MaintenanceMetrics.scanFreshness` (24h) or the user taps Re-scan (force).
//

import SwiftUI

import AppKit

/// A circular progress gauge for the overall health score (0–100). Colour is
/// derived from the score (green > 80, yellow > 50, red otherwise) and the trim
/// animates as the score changes.
struct HealthRing: View {
    let score: Int  // 0–100

    private var color: Color {
        if score > 80 { return .green }
        else if score > 50 { return .yellow }
        else { return .red }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: 12)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 1.0), value: score)
            VStack(spacing: 2) {
                Text("\(score)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text("Health")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 90, height: 90)
    }
}

/// A reusable one-tap "action" card (icon + title + description + a single
/// button) whose action streams brew CLI output. The raw output is never shown:
/// while it runs the card shows a spinner, and on completion `resultSummary`
/// distils the collected lines into one friendly status line. Used for the
/// Homebrew Cache cleanup card; other cards on this screen open sheets instead.
struct ActionCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    /// Builds and returns the stream of CLI output lines for this card's action.
    let onRun: () async -> AsyncStream<String>
    // Optional closure that turns the collected command output into a single
    // friendly status line (e.g. "Ready to brew" for Doctor). When nil, a
    // generic "All set" message is shown. We never display raw terminal output
    // — these cards are meant to feel like one-tap, consumer-grade actions.
    var resultSummary: (([String]) -> String)? = nil

    // Label for the action button. Defaults to "Run"; the cleanup card uses
    // "Clean Up".
    var primaryTitle: String = "Run"

    // Optional explanatory footnote rendered under the card header (e.g. the
    // Homebrew Cache card uses this to explain that ForgedBrew already cleans the
    // cache automatically on install/update).
    var note: String? = nil

    @State private var isRunning = false
    @State private var isDone = false
    @State private var summary: String = ""
    @State private var log: [String] = []
    @State private var task: Task<Void, Never>? = nil
    @State private var needsPermission = false

    // Detects the macOS TCC permission block that occurs when the app process
    // lacks Full Disk Access and brew tries to write into ~/Library/Caches.
    private func isPermissionError(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.contains("operation not permitted")
            || (l.contains("permission denied") && l.contains("cache"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(iconColor.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .foregroundStyle(iconColor)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(description).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    run(onRun)
                } label: {
                    Text(isRunning ? "Running…" : primaryTitle)
                }
                .buttonStyle(PillActionButtonStyle())
                // Re-enabled once the run finishes so the user can run it again.
                .disabled(isRunning)
            }
            .padding(14)

            // Optional explanatory footnote (e.g. "cleaned automatically on
            // install/update"). Sits just under the header, above any result row.
            if let note {
                Divider()
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            // Friendly result row — a single status line (no raw terminal output).
            // Shows a spinner while running, then a green check + summary once done.
            if isRunning || (isDone && !summary.isEmpty) {
                Divider()
                HStack(spacing: 8) {
                    if isRunning {
                        ProgressView().scaleEffect(0.6)
                        Text("Working…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 12))
                        Text(summary)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            // macOS permission guidance (Full Disk Access)
            if needsPermission {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Permission needed")
                                .font(.system(size: 12, weight: .semibold))
                            Text("macOS blocked ForgedBrew from modifying Homebrew's cache. Grant ForgedBrew Full Disk Access, then try again.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // Resets the card to its running state, then drains the action's stream on a
    // background Task: each line is appended to `log` on the main actor (watching
    // for the TCC permission block as it goes), and once the stream ends the
    // collected log is reduced to a single `summary` line. Any previous Task is
    // cancelled first so re-running mid-flight can't leave two streams racing.
    private func run(_ action: @escaping () async -> AsyncStream<String>) {
        isRunning = true
        isDone = false
        needsPermission = false
        summary = ""
        log = []
        task?.cancel()
        task = Task {
            let stream = await action()
            for await line in stream {
                let permissionHit = isPermissionError(line)
                await MainActor.run {
                    log.append(line)
                    if permissionHit { needsPermission = true }
                }
            }
            await MainActor.run {
                // Derive the friendly one-line status from the collected output.
                // The raw output is never shown to the user.
                summary = resultSummary?(log) ?? "All set"
                isRunning = false
                isDone = true
            }
        }
    }
}

// (See the file header for an overview of MaintenanceMetrics, which holds all of
// this screen's asynchronously-probed state and is defined below.)

/// The classified result of an adopt attempt, so the UI can show the right icon,
/// colour, and message — and decide whether to offer the Force fallback. The
/// associated `String` is the user-facing message; `adoptSummary(_:)` maps brew's
/// raw output onto one of these cases.
nonisolated enum AdoptOutcome: Equatable, Sendable {
    case success(String)        // adopted cleanly
    case mismatch(String)       // already installed / version mismatch — Force may help
    case failure(String)        // a real failure (e.g. OneDrive is Microsoft-controlled)
    case unknown(String)        // finished without a clear signal — suggest re-scan

    var message: String {
        switch self {
        case .success(let m), .mismatch(let m), .failure(let m), .unknown(let m): return m
        }
    }
    var isSuccess: Bool { if case .success = self { return true }; return false }
    var isMismatch: Bool { if case .mismatch = self { return true }; return false }
    var isFailure: Bool { if case .failure = self { return true }; return false }
}

/// The view-model backing the entire Maintenance screen. It is `@MainActor`
/// (every property mutation happens on the main actor, so progress callbacks
/// from the off-actor scanners can write straight to these `@Observable`
/// properties and the UI reflects them live) and `@Observable` (SwiftUI tracks
/// reads automatically). One instance is created by `MaintenanceView` and shared
/// into every sheet, so a scan kicked off from a card is visible in its sheet.
/// See the file header for the shared scan/load/persistence conventions.
@MainActor
@Observable
final class MaintenanceMetrics {
    var brewCacheSize: String? = nil          // e.g. "55 MB"
    var brewCacheSizeAfter: String? = nil     // populated after a cleanup run
    var doctorReport: BrewCLIService.DoctorReport? = nil
    var doctorLoading = false
    var forgedbrewCacheSize: String? = nil

    // Quarantine (Gatekeeper) management state.
    var quarantinedItems: [BrewCLIService.QuarantinedItem] = []
    var quarantineScanning = false
    var quarantineRemoving = false
    // Last removal outcome surfaced in the sheet: how many cleared, and any
    // paths that failed (usually a Full Disk Access / permissions issue). nil
    // until a removal has run.
    var quarantineError: String? = nil
    var quarantineLastCleared: Int = 0

    // Adopt (bring an existing app under Homebrew management) state.
    var adoptCandidates: [BrewCLIService.AdoptCandidate] = []
    var adoptScanning = false
    var adoptingTokens = Set<String>()        // tokens with an adopt in flight
    // Per-token last-run outcome, so a row can surface a clear result / error
    // (success, version mismatch, or a real failure like OneDrive) right under
    // itself with the right icon and color.
    var adoptResults: [String: AdoptOutcome] = [:]
    // Tokens the user chose to hide from Adopt. Persisted in UserDefaults so the
    // choice survives relaunches; mirrored here for instant @Observable updates.
    var hiddenAdoptTokens: Set<String> = []

    // Duplicates (same app/tool installed more than once) state.
    var duplicateGroups: [DuplicateGroup] = []
    var duplicatesScanning = false
    var removingDuplicateIDs = Set<String>()   // install ids with a removal in flight
    // Per-install last-removal error, keyed by DuplicateInstall.id, so a row can
    // show exactly why a removal failed (permissions, app running, brew error).
    var duplicateErrors: [String: String] = [:]

    // Full Disk Access status. Probed on appear so the banner can prompt the
    // user to grant access (without which cache cleanup + sizes are unreliable).
    var fdaGranted: Bool = false

// Probes whether ForgedBrew has Full Disk Access. Drives the banner that
    // prompts the user to grant it (without which cache cleanup and quarantine
    // removal silently fail).
func loadFDAStatus() async {
        fdaGranted = FullDiskAccess.isGranted()
    }

    // MARK: - Homebrew self-update
    //
    // We surface Homebrew's OWN version (separate from the packages it manages)
    // and a one-tap "Update Homebrew" that runs `brew update` -- the command
    // that fetches the newest Homebrew itself plus all formula/cask definitions.
    // There is no separate "upgrade Homebrew" command, and Homebrew updates by
    // pulling git commits (not just tagged releases), so we do NOT try to predict
    // whether an update is needed from a version comparison -- that is unreliable
    // and can be misleading. Instead, like the established Homebrew GUIs, we treat
    // Update as a refresh action and report whatever `brew update` actually did.
    var brewInstalledVersion: String? = nil   // e.g. "4.4.24"; nil = unknown/not installed
    var brewVersionLoading: Bool = false      // true while probing the installed version
    var brewUpdating: Bool = false            // true while `brew update` runs
    var brewUpdateMessage: String? = nil      // last result line from `brew update`, for the banner

    // Reads the installed Homebrew version via the CLI. Leaves brewInstalledVersion
    // nil if brew is missing or unparseable, which the banner shows as "not found".
    func loadHomebrewStatus(cli: BrewCLIService) async {
        brewVersionLoading = true
        brewInstalledVersion = await cli.installedBrewVersion()
        brewVersionLoading = false
    }

    // Runs `brew update`, then re-reads the installed version and reports a
    // CLEAN, deterministic outcome. We do NOT echo raw brew output lines: when
    // brew has changes it prints section headers ("==> Updated Casks") followed
    // by one bare cask/formula name per line, so the last non-empty line is
    // often just an app name (e.g. "kimi-code") -- meaningless as a status. We
    // instead detect the "Already up-to-date." sentinel and otherwise summarize.
    @MainActor
    func updateHomebrew(cli: BrewCLIService) async {
        guard !brewUpdating else { return }
        brewUpdating = true
        brewUpdateMessage = "Updating Homebrew…"
        var lines: [String] = []
        for await line in await cli.updateBrew() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        // Re-read the version in case Homebrew itself advanced.
        brewInstalledVersion = await cli.installedBrewVersion()
        brewUpdating = false

        let joined = lines.joined(separator: "\n")
        // An explicit error (e.g. permissions) should be shown verbatim so the
        // user knows what to fix.
        if let errorLine = lines.first(where: { $0.hasPrefix("Error:") || $0.hasPrefix("Warning:") }) {
            brewUpdateMessage = errorLine
        } else if joined.localizedCaseInsensitiveContains("already up-to-date")
                    || joined.localizedCaseInsensitiveContains("already up to date") {
            brewUpdateMessage = "Homebrew is up to date."
        } else if lines.contains(where: { $0.range(of: #"Updated \d+ tap"#, options: .regularExpression) != nil }) {
            brewUpdateMessage = "Homebrew and package definitions updated."
        } else {
            brewUpdateMessage = "Homebrew updated."
        }
    }

    // Measures the current Homebrew download-cache size (the "before" figure).
    func loadCacheSize(cli: BrewCLIService) async {
        brewCacheSize = (try? await cli.cacheSize()) ?? nil
    }

    // Re-measures the cache after a cleanup so the card can show "was X, now Y".
    func refreshCacheAfterCleanup(cli: BrewCLIService) async {
        brewCacheSizeAfter = (try? await cli.cacheSize()) ?? nil
    }

    // Runs `brew doctor` (via the CLI parser) and stores the structured report
    // so the Doctor section and health summary can render its findings.
    func loadDoctor(cli: BrewCLIService) async {
        doctorLoading = true
        doctorReport = await cli.doctorReport()
        doctorLoading = false
    }

    // Tracks which tap actions (trust / untap) are currently running, plus any
    // error message to surface beside a tap card when the action
    // fails (e.g. untap blocked because installed packages still depend on it).
    var tapActionInFlight = Set<String>()
    var tapActionErrors: [String: String] = [:]
    // Name of the tap awaiting Remove-Tap confirmation, if any. Drives a
    // confirmation dialog so the destructive untap isn't a one-click accident.
    var tapPendingUntap: String? = nil

    // Trusts a tap, then re-runs brew doctor on success so the now-trusted tap
    // drops out of the warning. On failure we keep the card and show why.
    func trustTap(_ name: String, cli: BrewCLIService) async {
        tapActionErrors[name] = nil
        tapActionInFlight.insert(name)
        let result = await cli.trustTap(name)
        tapActionInFlight.remove(name)
        if result.success {
            await loadDoctor(cli: cli)
        } else {
            tapActionErrors[name] = result.message.isEmpty
                ? "Could not trust this tap." : result.message
        }
    }

    // Removes a tap entirely, then re-runs brew doctor on success. brew refuses
    // to untap when installed packages still depend on it; that message is shown
    // verbatim so the user knows to remove those packages first.
    func untapTap(_ name: String, cli: BrewCLIService) async {
        tapActionErrors[name] = nil
        tapActionInFlight.insert(name)
        let result = await cli.untap(name)
        tapActionInFlight.remove(name)
        if result.success {
            await loadDoctor(cli: cli)
        } else {
            tapActionErrors[name] = result.message.isEmpty
                ? "Could not untap this tap." : result.message
        }
    }

    func loadQuarantinedItems(cli: BrewCLIService) async {
        quarantineScanning = true
        // Clear the flag on every exit path (including Task cancellation when
        // the sheet is dismissed mid-scan) so the view can never get stuck
        // showing "Scanning…".
        defer { quarantineScanning = false }
        quarantinedItems = await cli.scanQuarantinedItems()
    }

    // Scans for duplicates using the current cask catalog plus the installed
    // cask/formula token sets (derived from AppDataService.installedPackages).
    func loadDuplicates(casks: [CaskMetadata],
                        installedCaskTokens: Set<String>,
                        installedFormulaTokens: Set<String>,
                        cli: BrewCLIService) async {
        duplicatesScanning = true
        // Clear the flag on every exit path (including Task cancellation when
        // the sheet is dismissed mid-scan) so the view can never get stuck
        // showing "Scanning…". Mirrors loadQuarantinedItems.
        defer { duplicatesScanning = false }
        duplicateGroups = await cli.scanDuplicates(
            casks: casks,
            installedCaskTokens: installedCaskTokens,
            installedFormulaTokens: installedFormulaTokens
        )
    }

    // Removes one copy of a duplicate, then re-scans so the resolved group drops
    // out of the list. Any failure is surfaced on the row via duplicateErrors
    // (keyed by the install id) and the group stays visible so the user sees why.
    func removeDuplicate(_ install: DuplicateInstall,
                         casks: [CaskMetadata],
                         installedCaskTokens: Set<String>,
                         installedFormulaTokens: Set<String>,
                         cli: BrewCLIService) async {
        removingDuplicateIDs.insert(install.id)
        duplicateErrors[install.id] = nil
        let error = await cli.removeDuplicateInstall(install)
        removingDuplicateIDs.remove(install.id)
        if let error {
            duplicateErrors[install.id] = error
            return   // keep the group visible with its error
        }
        // Success — re-scan so the group disappears (or shrinks) accordingly.
        await loadDuplicates(casks: casks,
                             installedCaskTokens: installedCaskTokens,
                             installedFormulaTokens: installedFormulaTokens,
                             cli: cli)
    }

    // Orphaned packages (formulae kept only as now-unneeded dependencies) state.
    var orphanResult: OrphanScanResult = .empty
    var orphansScanning = false
    var removingOrphanTokens = Set<String>()   // formula tokens with a removal in flight
    var removingAllOrphans = false             // "Remove All" / autoremove in flight
    // Per-package last-removal error, keyed by formula token, so a row can show
    // exactly why a removal failed (e.g. still has dependents).
    var orphanErrors: [String: String] = [:]
    // A top-level error for the "Remove All" path (autoremove as a whole).
    var orphanRemoveAllError: String?

    // Asks Homebrew which formulae are orphaned and enriches each with size.
    func loadOrphans(cli: BrewCLIService) async {
        orphansScanning = true
        // Clear on every exit path (including Task cancellation mid-scan) so the
        // view can never get stuck showing "Scanning…". Mirrors loadQuarantinedItems.
        defer { orphansScanning = false }
        orphanResult = await cli.scanOrphanedPackages()
    }

    // Removes one orphaned formula, then re-scans so the list refreshes (and
    // any newly-exposed orphans surface). Failure is surfaced on the row via
    // orphanErrors (keyed by token) and the package stays visible.
    func removeOrphan(_ package: OrphanedPackage, cli: BrewCLIService) async {
        removingOrphanTokens.insert(package.token)
        orphanErrors[package.token] = nil
        let error = await cli.removeOrphanedPackage(package)
        removingOrphanTokens.remove(package.token)
        if let error {
            orphanErrors[package.token] = error
            return   // keep the package visible with its error
        }
        await loadOrphans(cli: cli)
    }

    // Removes every orphaned formula in one shot via `brew autoremove`, then
    // re-scans. Any failure is surfaced via orphanRemoveAllError.
    func removeAllOrphans(cli: BrewCLIService) async {
        removingAllOrphans = true
        orphanRemoveAllError = nil
        let error = await cli.removeAllOrphanedPackages()
        removingAllOrphans = false
        if let error {
            orphanRemoveAllError = error
            return
        }
        await loadOrphans(cli: cli)
    }

    // Trust Management Screening (upcoming Homebrew change) state. Every installed cask
    // app that macOS Gatekeeper rejects today — these are at risk after Sept 1,
    // 2026, when Homebrew stops working around Gatekeeper for casks and drops
    // those that fail it. Includes apps with no quarantine flag (still at risk,
    // just no local action yet); the sheet splits actionable vs. watch-only.
    var gatekeeperRiskResult: GatekeeperRiskScanResult = .empty
    var trustScanning = false
    var trustHasScanned = false
    // Live progress for the trust scan: how many apps checked out of the total,
    // and the name of the app currently being assessed. Drives the sheet's
    // "Scanning X of N…" bar (same pattern as the Security Scan).
    var trustScannedCount = 0
    var trustTotalCount = 0
    var trustCurrentApp: String? = nil
    // Bundle paths with a trust action (xattr -d) in flight.
    var trustingPaths = Set<String>()
    // Per-app last-trust error, keyed by bundle path, so a row can show exactly
    // why clearing the quarantine flag failed.
    var trustErrors: [String: String] = [:]

    // How long a completed scan stays "fresh". While fresh, reopening a scan
    // screen shows the saved results instead of auto-re-running. Re-scan always
    // overrides this.
    static let scanFreshness: TimeInterval = 24 * 60 * 60   // 24 hours

    // True when the last Security Scan finished within the freshness window.
    // `timeIntervalSinceNow` is NEGATIVE for a past date, so a scan that ran less
    // than `scanFreshness` ago compares as "> -scanFreshness". We ALSO require the
    // timestamp not be in the future (`<= Date()`): a clock change or hand-edited
    // cache could leave a future date, which would otherwise read as "fresh"
    // indefinitely and suppress the auto-rescan forever. A future date is treated
    // as stale so a rescan runs. `loadSecurityScan` checks this to skip an auto-re-run.
    var securityIsFresh: Bool {
        securityHasScanned
            && securityScannedAt.timeIntervalSinceNow > -Self.scanFreshness
            && securityScannedAt <= Date()
    }
    // True when the last Trust scan finished within the freshness window. The
    // Trust scan stores its own timestamp on the result struct rather than a
    // separate property, so we read it from there. Same future-date guard as
    // above: a future timestamp is treated as stale so a rescan runs.
    var trustIsFresh: Bool {
        trustHasScanned
            && gatekeeperRiskResult.scannedAt.timeIntervalSinceNow > -Self.scanFreshness
            && gatekeeperRiskResult.scannedAt <= Date()
    }

    // Scans installed cask apps and keeps only the ones Gatekeeper would reject
    // today — the apps at risk from the upcoming Homebrew cask-quarantine change.
    // `force: true` (the Re-scan button, and the post-trustApp re-scan) bypasses
    // the freshness gate; otherwise a fresh saved result is reused as-is.
    func loadGatekeeperRisks(cli: BrewCLIService, force: Bool = false) async {
        // Re-entrancy guard. Several paths can ask for a scan (the Review
        // button, Re-scan, and trustApp re-scans when done).
        // Without this, overlapping Tasks each reset the counter to 0 and start
        // a fresh pass, so the progress bar appears to climb, snap back, climb
        // higher, snap back, etc. Bail out if a scan is already running.
        guard !trustScanning else { return }
        if !force && trustIsFresh { return }            // reuse saved results (new)
        trustScanning = true
        trustScannedCount = 0
        trustTotalCount = 0
        trustCurrentApp = nil
        // GUARANTEE the scanning flag is cleared on EVERY exit path — including
        // when this Task is cancelled mid-scan (e.g. the sheet is dismissed
        // while "Scanning…" is showing). Previously the `trustScanning = false`
        // line lived after the await, so a cancellation skipped it and left the
        // flag stuck true forever; the re-entrancy guard above then turned every
        // later Re-scan into a silent no-op that just spun on "Scanning…". The
        // defer runs even on cancellation, so the scan can always be re-run.
        defer {
            trustScanning = false
            trustCurrentApp = nil
        }
        // Walk apps one-by-one and update the live progress as each is checked.
        // The callback runs on the main actor, so it can mutate this @Observable
        // state directly and the sheet reflects it immediately.
        gatekeeperRiskResult = await cli.scanGatekeeperRisks { [weak self] scanned, total, currentApp in
            guard let self else { return }
            self.trustScannedCount = scanned
            self.trustTotalCount = total
            self.trustCurrentApp = currentApp.isEmpty ? nil : currentApp
        }
        // Persist after the assignment so a cancelled scan (which leaves the
        // result unchanged) doesn't overwrite the saved report with a partial.
        saveTrustScan()
        // Mark complete only on the real-completion path (NOT in the defer above),
        // matching loadSecurityScan: a Task cancelled mid-scan must not flip this
        // on while gatekeeperRiskResult is still empty, which would render the
        // reassuring "Nothing at risk" copy on a partial/aborted scan.
        trustHasScanned = true
    }

    // Clears the quarantine flag on one trusted app (xattr -d com.apple.quarantine
    // via removeQuarantine(at:)), then re-scans so the now-trusted app drops out
    // of the list. Failure is surfaced on the row via trustErrors (keyed by
    // bundle path) and the app stays visible.
    func trustApp(_ risk: GatekeeperRisk, cli: BrewCLIService) async {
        trustingPaths.insert(risk.appPath)
        trustErrors[risk.appPath] = nil
        let ok = await cli.removeQuarantine(at: risk.appPath)
        trustingPaths.remove(risk.appPath)
        if !ok {
            trustErrors[risk.appPath] = "Couldn’t clear the quarantine flag for this app."
            return   // keep the app visible with its error
        }
        await loadGatekeeperRisks(cli: cli, force: true)
    }

    // Disk footprint (Apps / Formulae / Caskroom / cache / taps) state.
    var diskFootprint: DiskFootprint = .empty
    var footprintMeasuring = false

    // Measures the Homebrew footprint. Slow-ish (du over the Cellar/Caskroom),
    // so it runs off the main actor inside the service and we just await the
    // result. `caskAppsBytes` is the summed size of cask-installed app bundles
    // in /Applications (those live outside the prefix); the caller computes it
    // from the per-cask sizes already on InstalledPackage and passes it in.
    func loadDiskFootprint(cli: BrewCLIService, caskAppsBytes: Int64) async {
        footprintMeasuring = true
        // Clear on every exit path (including Task cancellation mid-measure) so
        // the view can never get stuck showing "Measuring…". Mirrors loadQuarantinedItems.
        defer { footprintMeasuring = false }
        diskFootprint = await cli.measureDiskFootprint(caskAppsBytes: caskAppsBytes)
    }

    // MARK: - Security scan

    // Results accumulate HERE as each app is scanned, so the UI can show app-by-
    // app progress live rather than waiting for the whole batch. The sheet reads
    // this array directly (sorting itself), and we build a SecurityScanReport
    // from it at the end for the summary counts.
    var securityResults: [AppSecurityResult] = []
    // True while a scan is running (drives the spinner + disabled button).
    var securityScanning = false
    // True once a scan has completed at least once this session.
    var securityHasScanned = false
    // Set if the scan couldn't run at all (no installed casks, tooling error).
    var securityError: String? = nil
    // Live progress: how many apps we've scanned out of the total, and the name
    // of the app currently being scanned (shown under the progress bar).
    var securityScannedCount = 0
    var securityTotalCount = 0
    var securityCurrentApp: String? = nil
    // When the most recent completed scan finished (for the report summary).
    var securityScannedAt: Date = .distantPast

    // A live view of the results gathered so far, wrapped in a report so the
    // sheet can reuse its sorting + counts during AND after the scan.
    var securityReport: SecurityScanReport {
        SecurityScanReport(results: securityResults, scannedAt: securityScannedAt)
    }

    // MARK: - Vulnerability (CVE) scan
    //
    // Layer 2 of Diagnostics. Unlike the security scan, this reaches the network
    // (OSV.dev) to check whether the installed VERSION of each package has known
    // CVEs. Results accumulate live, package-by-package, just like the security
    // scan above.
    var vulnResults: [PackageVulnerabilityResult] = []
    var vulnScanning = false
    var vulnHasScanned = false
    var vulnError: String? = nil
    var vulnScannedCount = 0
    var vulnTotalCount = 0
    var vulnCurrentPkg: String? = nil
    var vulnScannedAt: Date = .distantPast

    var vulnReport: VulnerabilityScanReport {
        VulnerabilityScanReport(results: vulnResults, scannedAt: vulnScannedAt)
    }

    // Runs the CVE scan across every installed formula and cask, querying OSV
    // for each and appending results AS THEY COMPLETE so the UI updates live.
    // This is the only ForgedBrew feature that uses the network.
    func loadVulnerabilityScan(cli: BrewCLIService) async {
        vulnScanning = true
        // Clear on every exit path (the empty-targets guard below AND Task
        // cancellation mid-scan) so the view can never get stuck showing
        // "Scanning…". Mirrors loadQuarantinedItems.
        defer { vulnScanning = false }
        vulnError = nil
        vulnResults = []
        vulnScannedCount = 0
        vulnCurrentPkg = nil

        let targets = (try? await cli.vulnerabilityScanTargets()) ?? []
        vulnTotalCount = targets.count

        guard !targets.isEmpty else {
            vulnHasScanned = true
            vulnError = "No installed packages were found to check."
            vulnScannedAt = Date()
            return
        }

        // Sort so formulae then casks, alphabetically within each, for a stable
        // predictable progression in the UI.
        let ordered = targets.sorted { a, b in
            if a.kind != b.kind { return a.kind < b.kind }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        for target in ordered {
            vulnCurrentPkg = target.name
            let result = await cli.scanPackageVulnerabilities(target: target)
            vulnResults.append(result)
            vulnScannedCount += 1
        }

        vulnCurrentPkg = nil
        vulnScannedAt = Date()
        vulnHasScanned = true
    }

    // Runs the local security scan across every installed cask app bundle,
    // appending each app's result AS IT COMPLETES so the UI updates live. No
    // network access — this only uses macOS's own codesign + spctl tooling.
    // `force: true` (Re-scan) bypasses the freshness gate; otherwise a saved
    // result that is still fresh is reused without re-scanning. A completed result
    // (when casks were found) is persisted so reopening the screen shows it
    // immediately; the empty "no casks found" outcome is intentionally NOT
    // persisted (see the guard below).
    func loadSecurityScan(cli: BrewCLIService, force: Bool = false) async {
        if securityScanning { return }                 // re-entrancy guard
        if !force && securityIsFresh { return }         // reuse fresh saved results
        securityScanning = true
        // Clear the scanning flag (and the live "current app") on EVERY exit path —
        // including Task cancellation when the sheet is dismissed mid-scan — so the
        // re-entrancy guard above can never latch true forever and turn every later
        // scan into a silent no-op. Mirrors loadGatekeeperRisks. (securityHasScanned
        // and saveSecurityScan stay on the real-completion path below, so a cancelled
        // partial scan is neither marked complete nor persisted.)
        defer {
            securityScanning = false
            securityCurrentApp = nil
        }
        securityError = nil
        securityResults = []
        securityScannedCount = 0
        securityCurrentApp = nil

        let bundles = await cli.installedAppBundlesToSecurityScan()
        securityTotalCount = bundles.count

        guard !bundles.isEmpty else {
            securityHasScanned = true
            securityError = "No installed apps were found to scan."
            securityScannedAt = Date()
            // Deliberately NOT persisted: a saved empty report would reload as a
            // misleading "All 0 apps passed" because securityError isn't part of
            // SecurityScanReport. Re-running an empty scan next launch is cheap and
            // shows the correct "no casks found" message.
            return
        }

        // Scan sequentially so results appear one-by-one, sorted A–Z by app name
        // (non-cask apps use their bundle PATH as the token, so we can't sort on
        // the token). Each scan is a few quick subprocesses; results are cached for
        // 24h, so the larger "all installed apps" sweep only re-runs occasionally.
        for bundle in bundles.sorted(by: {
            let a = (($0.appPath as NSString).lastPathComponent as NSString).deletingPathExtension
            let b = (($1.appPath as NSString).lastPathComponent as NSString).deletingPathExtension
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }) {
            // Show which app we're on (derive a friendly name from the path).
            let name = ((bundle.appPath as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            securityCurrentApp = name
            let result = await cli.scanAppSecurity(token: bundle.token, appPath: bundle.appPath)
            securityResults.append(result)
            securityScannedCount += 1
        }

        securityScannedAt = Date()
        securityHasScanned = true
        saveSecurityScan()
    }

    // Removes quarantine from the given paths, then re-scans so the list and
    // any count reflect what's left. We now track which paths FAILED (each
    // removeQuarantine returns a Bool) and surface a clear error instead of
    // silently swallowing failures — the common cause is missing Full Disk
    // Access, which the user needs to be told about.
    func removeQuarantine(paths: [String], cli: BrewCLIService) async {
        quarantineRemoving = true
        quarantineError = nil
        var failed: [String] = []
        for path in paths {
            let ok = await cli.removeQuarantine(at: path)
            if !ok { failed.append((path as NSString).lastPathComponent) }
        }
        quarantineLastCleared = paths.count - failed.count
        if failed.isEmpty {
            quarantineError = nil
        } else if failed.count == paths.count {
            quarantineError = "Couldn't clear quarantine on \(failed.count) item\(failed.count == 1 ? "" : "s"). This usually means ForgedBrew needs Full Disk Access (see the banner above)."
        } else {
            quarantineError = "Cleared \(quarantineLastCleared), but \(failed.count) failed (\(failed.prefix(3).joined(separator: ", "))\(failed.count > 3 ? "…" : "")). Granting Full Disk Access usually fixes this."
        }
        quarantinedItems = await cli.scanQuarantinedItems()
        quarantineRemoving = false
    }

    // MARK: - Adopt

    // UserDefaults key for the persisted hidden-from-Adopt token list.
    private static let hiddenAdoptKey = "forgedbrewHiddenAdoptTokens"

    // Loads the persisted hidden list into memory. Call before the first scan.
    func loadHiddenAdoptTokens() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.hiddenAdoptKey) ?? []
        hiddenAdoptTokens = Set(stored)
    }

    private func persistHiddenAdoptTokens() {
        UserDefaults.standard.set(Array(hiddenAdoptTokens).sorted(), forKey: Self.hiddenAdoptKey)
    }

    // Scans for apps that could be adopted into Homebrew. Excludes apps Homebrew
    // already manages (from the Installed list) and anything the user hid.
    //
    // IMPORTANT: the "already managed" exclusion is only correct if the Installed
    // list has actually loaded. On a fresh launch the user can open Adopt before
    // appData.installedPackages has been populated; with an empty managed set the
    // filter excludes nothing and nearly every app that maps to a cask floods the
    // list. So we guarantee the Installed list is loaded first and derive the
    // managed-cask tokens from that fresh data instead of trusting a caller
    // snapshot that may be empty.
    func loadAdoptCandidates(casks: [CaskMetadata], managedTokens: Set<String>, cli: BrewCLIService, appData: AppDataService) async {
        adoptScanning = true
        // Always refresh the hidden set from persistence BEFORE scanning so the
        // exclusion is correct regardless of who triggers the scan or when. The
        // previous load happened in a separate .task, so a row-initiated Adopt
        // could scan with an empty hidden set and leak hidden apps into the
        // adoptable list (showing them in both the top list and the hidden
        // section). Reloading here closes that race.
        loadHiddenAdoptTokens()
        // Ensure the Installed list is loaded before we compute exclusions. If it
        // has never loaded (empty and not already in flight), load it now.
        if appData.installedPackages.isEmpty && !appData.isLoadingInstalled {
            await appData.refreshInstalled()
        }
        // Recompute managed cask tokens from the (now-loaded) Installed list so
        // the exclusion is always accurate, regardless of what the caller passed.
        let resolvedManaged = Set(
            appData.installedPackages
                .filter { $0.type == .cask }
                .map(\.token)
        )
        adoptCandidates = await cli.scanAdoptableApps(
            casks: casks,
            managedTokens: resolvedManaged,
            hiddenTokens: hiddenAdoptTokens
        )
        adoptScanning = false
    }

    // Adopts one app. Drains the brew stream, then re-scans (with the same
    // exclusions) so a freshly-adopted app drops off the list. The caller must
    // refresh the Installed list afterward so the adopted token is recognized as
    // managed on the next scan; we keep a local managedTokens snapshot here.
    func adopt(
        token: String,
        force: Bool,
        casks: [CaskMetadata],
        managedTokens: Set<String>,
        cli: BrewCLIService,
        appData: AppDataService
    ) async {
        adoptingTokens.insert(token)
        adoptResults[token] = nil
        var lines: [String] = []
        // BrewCLIService is an actor: hop to it to build the stream, THEN drain.
        let stream = await cli.adoptCask(token: token, force: force)
        for await line in stream { lines.append(line) }
        let outcome = Self.adoptSummary(lines)
        adoptResults[token] = outcome
        adoptingTokens.remove(token)
        // Only a clean success removes the app from the list. On mismatch or a
        // real failure (e.g. OneDrive, which Microsoft controls) we KEEP the row
        // so its error stays visible and the user can try Force or hide it.
        guard outcome.isSuccess else { return }
        // Keep the green "Adopted successfully" message visible for a few
        // seconds so the user sees confirmation, THEN drop the row so they do
        // not think they still need to adopt it again. We remove just this one
        // candidate immediately (cheap, animatable) and re-scan in the
        // background to keep the exclusion list correct for everything else.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        withAnimation(.easeInOut(duration: 0.25)) {
            adoptCandidates.removeAll { $0.suggestedToken == token }
        }
        adoptResults[token] = nil
        var managed = managedTokens
        managed.insert(token)
        await loadAdoptCandidates(casks: casks, managedTokens: managed, cli: cli, appData: appData)
    }

    // Hides a token from Adopt (persisted) and removes it from the current list.
    func hideAdopt(token: String) {
        hiddenAdoptTokens.insert(token)
        persistHiddenAdoptTokens()
        adoptCandidates.removeAll { $0.suggestedToken == token }
    }

    // Unhides a token; the next scan can surface it again.
    func unhideAdopt(token: String) {
        hiddenAdoptTokens.remove(token)
        persistHiddenAdoptTokens()
    }

    // Classifies brew's adopt output into a structured outcome. Order matters:
    // we check explicit failures BEFORE the generic "error" catch so a clear
    // message wins, and check success last among the positive signals.
    static func adoptSummary(_ lines: [String]) -> AdoptOutcome {
        let joined = lines.joined(separator: "\n").lowercased()

        // Real failures we don't want to mask as a mismatch. Apps whose cask is
        // managed/blocked by the vendor (OneDrive, some Microsoft apps) report
        // these; Force won't help, so we don't suggest it.
        if joined.contains("no available cask")
            || joined.contains("no cask")
            || joined.contains("it is not")
            || joined.contains("cannot be adopted")
            || joined.contains("not be adopted")
            || joined.contains("permission denied")
            || joined.contains("not allowed")
            || joined.contains("sha256 mismatch")
            || joined.contains("checksum") {
            return .failure("App cannot be Adopted — see conditions above")
        }
        // Version mismatch / already-installed: Force can reinstall over it.
        if joined.contains("version mismatch")
            || joined.contains("already installed")
            || joined.contains("not updated")
            || joined.contains("different version") {
            return .mismatch("Version mismatch — try Force to reinstall over it")
        }
        if joined.contains("was successfully installed") || joined.contains("successfully installed") {
            return .success("Adopted successfully")
        }
        // Any remaining error signal is a generic failure.
        if joined.contains("error") || joined.contains("failed") || joined.contains("abort") {
            return .failure("App cannot be Adopted — see conditions above")
        }
        return .unknown("Adopt finished — re-scan to confirm")
    }

    func loadForgedBrewCacheSize() async {
        forgedbrewCacheSize = await ForgedBrewCacheService.shared.totalCacheSizeString()
    }

    func clearForgedBrewCache() async {
        _ = await ForgedBrewCacheService.shared.clearAll()
        await loadForgedBrewCacheSize()
    }

    // MARK: - Scan result persistence
    //
    // Security & Trust scans are slow (many large bundles). Persist the last
    // completed report to Application Support so reopening a screen — or
    // relaunching the app — shows the saved results immediately with their
    // timestamp, instead of re-running. Auto-re-run only happens once a result
    // is older than `scanFreshness`, or when the user taps Re-scan.

    // Application Support/ForgedBrew/ScanCache, created on demand. Falls back to
    // the temp dir if Application Support is somehow unavailable so persistence
    // never throws (a lost temp cache just means the next open re-scans).
    private static var scanCacheDir: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("ForgedBrew/ScanCache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var securityCacheURL: URL { scanCacheDir.appendingPathComponent("security-scan.json") }
    private static var trustCacheURL: URL    { scanCacheDir.appendingPathComponent("trust-scan.json") }

    // Writes the current security report to disk (atomically). Called at the end
    // of every completed security scan. All failures are swallowed — a missed
    // save just costs a re-scan next time, never a crash.
    func saveSecurityScan() {
        // Never persist an empty report: it carries no per-app results and would
        // reload as a misleading "All 0 apps passed" (the "no casks" error text
        // isn't part of the report). Only a real, non-empty completion is cached.
        guard !securityResults.isEmpty else { return }
        let report = SecurityScanReport(results: securityResults, scannedAt: securityScannedAt)
        if let data = try? JSONEncoder().encode(report) {
            try? data.write(to: Self.securityCacheURL, options: .atomic)
        }
    }
    // Writes the current Gatekeeper-risk result to disk (atomically) at the end
    // of a completed trust scan. The result struct carries its own timestamp.
    func saveTrustScan() {
        if let data = try? JSONEncoder().encode(gatekeeperRiskResult) {
            try? data.write(to: Self.trustCacheURL, options: .atomic)
        }
    }

    // Loads any persisted scan reports back into memory. Called once from `init`,
    // so a freshly-launched screen shows the last results immediately. The
    // `scannedAt != .distantPast` guard rejects a sentinel/empty report (the
    // default timestamp) so we don't pretend a never-run scan has completed —
    // that would leave `hasScanned` true with no real results.
    private func loadPersistedScans() {
        if let data = try? Data(contentsOf: Self.securityCacheURL),
           let report = try? JSONDecoder().decode(SecurityScanReport.self, from: data),
           report.scannedAt != .distantPast {
            securityResults = report.results
            securityScannedAt = report.scannedAt
            securityHasScanned = true
        }
        if let data = try? Data(contentsOf: Self.trustCacheURL),
           let result = try? JSONDecoder().decode(GatekeeperRiskScanResult.self, from: data),
           result.scannedAt != .distantPast {
            gatekeeperRiskResult = result
            trustHasScanned = true
        }
    }

    // Rehydrate persisted Security/Trust reports up front so the screen opens
    // with saved results rather than a blank "never scanned" state.
    init() {
        loadPersistedScans()
    }
}

/// The Maintenance tab's root view. Owns the shared `MaintenanceMetrics`, kicks
/// off the best-effort metric probes in `.task` on appear, lays out the health
/// panel + diagnostics + the action-card grid, and hosts every maintenance sheet
/// (each bound to the shared metrics object).
struct MaintenanceView: View {
    @Environment(AppDataService.self) var appData
    @State private var metrics = MaintenanceMetrics()

    // The 0–100 health score driving the ring. Deliberately simple: start at 100
    // and dock 5 points per outdated package, capped at a 50-point total penalty
    // so the score never drops below 50 from outdated packages alone (the ring
    // stays in the "needs attention", not "critical", zone for updates only).
    private var healthScore: Int {
        let outdatedPenalty = min(appData.installedPackages.filter(\.isOutdated).count * 5, 50)
        return max(0, 100 - outdatedPenalty)
    }

    private var healthMessage: String {
        if healthScore > 80 { return "Your setup looks healthy" }
        else if healthScore > 50 { return "A few updates available" }
        else { return "Maintenance needed" }
    }

    @State private var showBrewfileSheet = false
    @State private var showQuarantineSheet = false
    // Drives the Adopt sheet via .sheet(item:) for race-free presentation.
    // Replaces the old presentation boolean, whose latched true state
    // could leave the sheet unable to re-present until an app restart.
    @State private var showDuplicatesSheet = false
    @State private var showOrphansSheet = false
    @State private var showDiskUsageSheet = false
    @State private var showSecurityScanSheet = false
    @State private var showVulnerabilitySheet = false
    @State private var showTrustMaintenanceSheet = false
    // True while an inline "Run brew cleanup" fix (triggered from a Diagnostics
    // card whose remedy is `brew cleanup`, e.g. broken symlinks) is running.
    // Disables the button and shows a spinner until cleanup + the follow-up
    // brew-doctor re-run finish.
    @State private var cleanupFixRunning = false

    private var outdatedCount: Int { appData.installedPackages.filter(\.isOutdated).count }

    // Tokens Homebrew already manages — used to exclude already-adopted apps
    // from the Adopt scan.
    private var managedTokens: Set<String> {
        Set(appData.installedPackages.filter { $0.type == .cask }.map(\.token))
    }

    // Installed token sets split by type, used by duplicate detection.
    private var installedCaskTokens: Set<String> {
        Set(appData.installedPackages.filter { $0.type == .cask }.map(\.token))
    }
    private var installedFormulaTokens: Set<String> {
        Set(appData.installedPackages.filter { $0.type == .formula }.map(\.token))
    }

    // Summed size of cask-installed app bundles in /Applications. These live
    // outside the Homebrew prefix, so the Disk Usage measurement can't find them
    // via brew's path queries; we reuse the per-cask sizes AppDataService
    // already computed (InstalledPackage.sizeBytes) and pass the total in.
    private var caskAppsBytes: Int64 {
        appData.installedPackages
            .filter { $0.type == .cask }
            .compactMap { $0.sizeBytes }
            .reduce(Int64(0)) { $0 + Int64($1) }
    }

    var body: some View {
        // Bindable view of the shared service so the Adopt sheet can be presented
        // with .sheet(item: $appData.adoptNavigationRequest): the request is the
        // single source of truth, and dismissing the sheet clears it automatically.
        @Bindable var appData = appData
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // Title
                VStack(alignment: .leading, spacing: 4) {
                    PageTitleLabel(title: "Maintenance")
                    Text("Keep your Homebrew installation healthy")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)

                // Full Disk Access status banner
                FullDiskAccessBanner(granted: metrics.fdaGranted)
                    .padding(.horizontal, 20)

                // Homebrew self-update status banner
                HomebrewStatusBanner(metrics: metrics, cli: appData.cli)
                    .padding(.horizontal, 20)

                // Health Score Panel
                HStack(alignment: .center, spacing: 24) {
                    HealthRing(score: healthScore)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(healthMessage)
                            .font(.title3)
                            .fontWeight(.semibold)

                        VStack(alignment: .leading, spacing: 6) {
                            healthCheckItem(
                                text: outdatedCount == 0 ? "All packages up to date" : "\(outdatedCount) packages need updates",
                                ok: outdatedCount == 0
                            )
                            healthCheckItem(
                                text: doctorSummaryText,
                                ok: metrics.doctorReport?.isClean ?? true
                            )
                            healthCheckItem(
                                text: metrics.brewCacheSize.map { "Homebrew cache: \($0)" } ?? "Homebrew cache: measuring…",
                                ok: true
                            )
                        }
                    }

                    Spacer()
                }
                .padding(20)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 0.5))
                .padding(.horizontal, 20)

                // Brew doctor — itemized findings
                doctorSection

                // Two-column action layout: general upkeep on the left,
                // security checks on the right. Cards are full-width rows within
                // each column and fill it via their own maxWidth: .infinity, so
                // we don't stack competing fixed widths (avoids the AppKit
                // layout recursion this app is careful about — no GeometryReader).
                VStack(spacing: 12) {
                    // Group headers sit above their respective columns so the
                    // grid reads as Maintenance (left) | Security (right).
                    HStack(alignment: .center, spacing: 16) {
                        actionGroupHeader(
                            title: "Maintenance",
                            systemImage: "wrench.and.screwdriver",
                            tint: Color(red: 0.20, green: 0.45, blue: 0.72)
                        )
                        actionGroupHeader(
                            title: "Security",
                            systemImage: "shield.lefthalf.filled",
                            tint: Color(red: 0.22, green: 0.55, blue: 0.34)
                        )
                    }

                    // Render the cards ROW BY ROW (instead of column by column)
                    // and stretch each pair to equal height so the two columns
                    // line up as a uniform grid. Each card already fills its
                    // column width; .frame(maxHeight: .infinity) makes the
                    // shorter card in a row grow to match the taller one.
                    gridRow(diskUsageCard, securityScanCard)
                    gridRow(adoptCard, vulnerabilityScanCard)
                    gridRow(orphansCard, quarantineCard)
                    gridRow(duplicatesCard, trustMaintenanceCard)
                }
                .padding(.horizontal, 20)

                // Cache row: ForgedBrew's own media cache on the left, Homebrew's
                // download cache on the right — two cards, one row.
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        Image(systemName: "externaldrive")
                            .foregroundStyle(Color(red: 0.20, green: 0.55, blue: 0.58))
                        Text("Cache")
                    }
                    .font(.title3)
                    .fontWeight(.bold)
                    HStack(alignment: .top, spacing: 16) {
                        forgedbrewCacheCard
                        homebrewCacheCard
                    }
                }
                .padding(.horizontal, 20)

                // Backup & Restore row: export the current setup to a Brewfile or
                // reinstall everything from one. (Moved here from the sidebar to
                // keep the sidebar focused on Installed/Updates.)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(Color(red: 0.52, green: 0.40, blue: 0.72))
                        Text("Backup & Restore")
                    }
                    .font(.title3)
                    .fontWeight(.bold)
                    brewfileCard
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        // NOTE: every sheet below re-applies .progressViewStyle(.forgedbrew).
        // Sheets are presented in their own hosting context and do NOT reliably
        // inherit the style set at the WindowGroup root, so without this a bare
        // ProgressView() falls back to the AppKit NSProgressIndicator, which
        // "ghosts" a grey spinner at the sheet's top-center during re-layout
        // (most visible as a scan streams results in). The standalone scan
        // sheets also set it on their own body; the inline sheets (Brewfile,
        // Quarantine, Adopt) get it here. See ForgedBrewSpinner for the why.
        .sheet(isPresented: $showBrewfileSheet) {
            BrewfileView(onDone: { showBrewfileSheet = false })
                .frame(minWidth: 560, minHeight: 520)
                .progressViewStyle(.forgedbrew)
        }
        .sheet(isPresented: $showQuarantineSheet) {
            QuarantineSheet(metrics: metrics, cli: appData.cli)
                .frame(minWidth: 520, minHeight: 420)
                .progressViewStyle(.forgedbrew)
        }
        .sheet(item: $appData.adoptNavigationRequest) { _ in
            // The navigation request is the single source of truth: .sheet(item:)
            // presents whenever it is non-nil and clears it on dismiss, so the
            // Adopt sheet can never be missed by an observer that wasn't mounted
            // yet and is never left latched after a dismissal. AdoptSheet sets its
            // own fixed 600x540 frame internally and runs the candidate scan in
            // its own .task, so presentation no longer depends on mount/observer
            // ordering or a separately-toggled flag.
            AdoptSheet(metrics: metrics, casks: appData.casks, managedTokens: managedTokens, appData: appData)
                .progressViewStyle(.forgedbrew)
        }
        .sheet(isPresented: $showDuplicatesSheet) {
            DuplicatesSheet(metrics: metrics,
                            casks: appData.casks,
                            installedCaskTokens: installedCaskTokens,
                            installedFormulaTokens: installedFormulaTokens,
                            cli: appData.cli)
        }
        .sheet(isPresented: $showOrphansSheet) {
            // OrphansSheet sets its own fixed frame internally.
            OrphansSheet(metrics: metrics, cli: appData.cli)
        }
        .sheet(isPresented: $showDiskUsageSheet) {
            // DiskUsageSheet sets its own fixed frame internally.
            DiskUsageSheet(metrics: metrics, cli: appData.cli, caskAppsBytes: caskAppsBytes)
        }
        .sheet(isPresented: $showSecurityScanSheet) {
            // SecurityScanSheet sets its own fixed frame internally.
            SecurityScanSheet(metrics: metrics, cli: appData.cli)
        }
        .sheet(isPresented: $showVulnerabilitySheet) {
            // VulnerabilityScanSheet sets its own fixed frame internally.
            VulnerabilityScanSheet(metrics: metrics, cli: appData.cli)
        }
        .sheet(isPresented: $showTrustMaintenanceSheet) {
            // TrustMaintenanceSheet sets its own fixed frame internally.
            TrustMaintenanceSheet(metrics: metrics, cli: appData.cli)
        }
        .task {
            // Kick off the best-effort metric probes when the screen appears.
            await metrics.loadFDAStatus()
            await metrics.loadHomebrewStatus(cli: appData.cli)
            await metrics.loadCacheSize(cli: appData.cli)
            await metrics.loadForgedBrewCacheSize()
            await metrics.loadDoctor(cli: appData.cli)
            metrics.loadHiddenAdoptTokens()
        }
    }

    // MARK: - Action column

    // A small tinted group header (Maintenance or Security) that sits above
    // its column. Wrapped in maxWidth: .infinity so the two headers split the
    // row evenly and align with the two card columns below them.
    @ViewBuilder
    private func actionGroupHeader(
        title: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 15, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // One row of the Maintenance/Security grid: a left card and a right card.
    // Both are stretched to fill the column width AND to the row\u2019s tallest
    // height (maxHeight: .infinity), so the two columns line up uniformly even
    // when one card has more content than the other. Top alignment keeps each
    // card\u2019s header pinned to the top while the shorter card\u2019s body simply
    // has extra trailing space. No GeometryReader \u2014 pure stack layout.
    @ViewBuilder
    private func gridRow<Left: View, Right: View>(
        _ left: Left,
        _ right: Right
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            left
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            right
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Homebrew Cache card

    // Cache Cleanup, pulled out of the old grid so it can sit beside the ForgedBrew
    // cache card in the Cache row. Runs `brew cleanup --prune=all -s`, which
    // removes old versions and every cached download. It never touches the
    // Caskroom installers Homebrew keeps for installed casks.
    private var homebrewCacheCard: some View {
        ActionCard(
            icon: "trash",
            iconColor: .orange,
            title: "Homebrew Cache",
            description: cacheCleanupDescription,
            onRun: {
                await metrics.loadCacheSize(cli: appData.cli)
                let stream = await appData.cli.deepCleanup()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await metrics.refreshCacheAfterCleanup(cli: appData.cli)
                }
                return stream
            },
            resultSummary: { Self.cleanupSummary($0) },
            primaryTitle: "Clean Up",
            note: "ForgedBrew automatically cleans the cache after every install and update. "
                + "If another app or the command line was used to install or update something, "
                + "use this button to clean up any leftover cache files."
        )
    }

    // MARK: - Remove Quarantine card

    @ViewBuilder
    private var quarantineCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "lock.open")
                        .foregroundStyle(.green)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove Quarantine from Applications")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Clear the Gatekeeper flag on downloaded apps")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showQuarantineSheet = true
                    Task { await metrics.loadQuarantinedItems(cli: appData.cli) }
                } label: {
                    Text("Review")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Security Scan card

    // Short status line shown under the card title: either a call to action, a
    // running indicator, or a one-line summary of the last scan's verdict.
    private var securityScanStatusText: String {
        if metrics.securityScanning { return "Scanning installed apps…" }
        if let err = metrics.securityError, metrics.securityHasScanned { return err }
        if metrics.securityHasScanned {
            let r = metrics.securityReport
            if r.failedCount > 0 {
                return "\(r.failedCount) of \(r.totalCount) need attention"
            } else if r.warnCount > 0 {
                return "\(r.passedCount) passed, \(r.warnCount) with warnings"
            } else {
                return "All \(r.totalCount) apps passed"
            }
        }
        return "Verify signatures, notarization & Gatekeeper"
    }

    @ViewBuilder
    private var securityScanCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(.blue)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Security Scan")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(securityScanStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showSecurityScanSheet = true
                } label: {
                    Text("Scan")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Trust Management Screening card

    // Short status line under the card title: a call to action, a running
    // indicator, or a one-line summary of the last scan.
    private var trustMaintenanceStatusText: String {
        if metrics.trustScanning { return "Checking apps against Gatekeeper…" }
        if metrics.trustHasScanned {
            let count = metrics.gatekeeperRiskResult.count
            if count > 0 {
                let app = count == 1 ? "app" : "apps"
                return "\(count) \(app) will break after Sept 1, 2026"
            } else {
                return "All apps will keep working"
            }
        }
        return "Check which apps may fail to launch after Sept 1, 2026"
    }

    @ViewBuilder
    private var trustMaintenanceCard: some View {
        // Tint orange when there are at-risk apps to draw the eye; neutral blue
        // otherwise. We only know there is risk once a scan has run.
        let hasRisk = metrics.trustHasScanned && metrics.gatekeeperRiskResult.count > 0
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill((hasRisk ? Color.orange : Color.blue).opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: hasRisk ? "exclamationmark.shield" : "checkmark.shield")
                        .foregroundStyle(hasRisk ? .orange : .blue)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trust Management Screening")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(trustMaintenanceStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showTrustMaintenanceSheet = true
                } label: {
                    Text("Review")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Vulnerability scan card

    private var vulnerabilityScanStatusText: String {
        if metrics.vulnScanning { return "Checking packages against OSV.dev…" }
        if let err = metrics.vulnError, metrics.vulnHasScanned { return err }
        if metrics.vulnHasScanned {
            let r = metrics.vulnReport
            if r.vulnerableCount > 0 {
                let pkg = r.vulnerableCount == 1 ? "package" : "packages"
                return "\(r.vulnerableCount) \(pkg) with known CVEs"
            } else {
                return "No known vulnerabilities found"
            }
        }
        return "Check installed packages for known CVEs"
    }

    private var vulnerabilityScanCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "ladybug")
                        .foregroundStyle(.orange)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vulnerability Scan")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(vulnerabilityScanStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showVulnerabilitySheet = true
                } label: {
                    Text("Scan")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Adopt Apps card

    @ViewBuilder
    private var adoptCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Adopt Apps into Homebrew")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Let Homebrew manage apps you already installed manually")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    // Drive the same request the row Adopt buttons use, so this
                    // entry point presents the sheet through the one mechanism.
                    // The sheet runs the candidate scan in its own .task.
                    appData.adoptNavigationRequest = AdoptNavigationRequest(
                        bundleID: "",
                        appName: "",
                        suggestedToken: nil
                    )
                } label: {
                    Text("Review")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Orphaned Packages card

    @ViewBuilder
    private var orphansCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "leaf")
                        .foregroundStyle(.orange)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean Up Orphaned Packages")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Remove formulae kept only as now-unneeded dependencies")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showOrphansSheet = true
                    Task { await metrics.loadOrphans(cli: appData.cli) }
                } label: {
                    Text("Review")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Disk Usage card

    @ViewBuilder
    private var diskUsageCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.teal.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.teal)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Disk Usage")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("See how much space Homebrew uses, broken down by location")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showDiskUsageSheet = true
                    Task { await metrics.loadDiskFootprint(cli: appData.cli, caskAppsBytes: caskAppsBytes) }
                } label: {
                    Text("Review")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Duplicates card

    @ViewBuilder
    private var duplicatesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.purple.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.purple)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find Duplicate Installs")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Spot apps installed more than once and remove the extra copy")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showDuplicatesSheet = true
                    Task {
                        await metrics.loadDuplicates(
                            casks: appData.casks,
                            installedCaskTokens: installedCaskTokens,
                            installedFormulaTokens: installedFormulaTokens,
                            cli: appData.cli
                        )
                    }
                } label: {
                    Text("Review")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Derived text

    private var doctorSummaryText: String {
        if metrics.doctorLoading { return "Running brew doctor…" }
        guard let report = metrics.doctorReport else { return "brew doctor status pending" }
        if report.isClean { return "brew doctor: system ready" }
        // Name the actual issue(s) so the user knows what to look at in the
        // Diagnostics list below, rather than just a bare count. We pull a short
        // label off each finding (e.g. "Untrusted taps", "Broken symlinks") and
        // join them. If the list gets long we show the first couple plus a
        // "+N more" so the health panel line stays readable.
        let labels = report.findings.map { Self.doctorIssueLabel(for: $0) }
        let n = labels.count
        let prefix = "brew doctor: \(n) issue\(n == 1 ? "" : "s") — "
        if labels.count <= 2 {
            return prefix + labels.joined(separator: ", ")
        }
        let shown = labels.prefix(2).joined(separator: ", ")
        return prefix + "\(shown) +\(labels.count - 2) more"
    }

    // Turns one brew-doctor finding into a short, plain-language label for the
    // health-panel summary line. The untrusted-taps finding gets a friendly
    // name (and a count when it covers multiple taps); everything else is
    // derived by tidying the raw warning title brew prints.
    static func doctorIssueLabel(for finding: BrewCLIService.DoctorFinding) -> String {
        if !finding.untrustedTaps.isEmpty {
            let c = finding.untrustedTaps.count
            return c == 1 ? "Untrusted tap" : "\(c) untrusted taps"
        }
        let base = shortIssueLabel(from: finding.title)
        return finding.occurrences > 1 ? "\(base) (×\(finding.occurrences))" : base
    }

    // brew doctor titles look like "Warning: Some installed formulae are
    // deprecated." — strip the "Warning:" prefix and trailing punctuation, then
    // map a few common ones to crisp labels. Falls back to a trimmed version of
    // brew's own wording so unknown warnings still read sensibly.
    static func shortIssueLabel(from title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "warning:", options: .caseInsensitive) {
            t = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        while let last = t.last, ".!:".contains(last) { t.removeLast() }
        let lower = t.lowercased()
        if lower.contains("not trusted") || lower.contains("untrusted tap") { return "Untrusted taps" }
        if lower.contains("broken symlink") { return "Broken symlinks" }
        if lower.contains("unbrewed") && lower.contains("dylib") { return "Unbrewed dylibs" }
        if lower.contains("unbrewed") && lower.contains("header") { return "Unbrewed headers" }
        if lower.contains("unbrewed") { return "Unbrewed files" }
        // Distinguish a deprecated *syntax* warning (brew complaining that a
        // tap's formula/cask Ruby file uses an old DSL call like
        // `depends_on macos:` string comparison) from genuinely deprecated
        // *packages*. The former is a tap-maintainer issue, not something the
        // user installed, so calling it "Deprecated formulae" is misleading.
        if lower.contains("deprecated") {
            if lower.contains("depends_on") || lower.contains("string comparison")
                || lower.contains("calling") || lower.contains("syntax")
                || lower.contains("dsl") {
                return "Deprecated cask syntax"
            }
            return "Deprecated formulae"
        }
        if lower.contains("outdated") { return "Outdated packages" }
        if lower.contains("not on your path") || lower.contains("not in your path") { return "PATH not configured" }
        if lower.contains("out of date") { return "Homebrew out of date" }
        if lower.contains("cellar") { return "Cellar issue" }
        // Unknown warning: keep brew's first words so it still means something.
        let words = t.split(separator: " ").prefix(6).joined(separator: " ")
        return words.isEmpty ? "Unknown issue" : words
    }

    private var cacheCleanupDescription: String {
        if let after = metrics.brewCacheSizeAfter, let before = metrics.brewCacheSize {
            return "Cache was \(before), now \(after)"
        }
        if let before = metrics.brewCacheSize {
            return "Cache is \(before) — clean up old versions and cached downloads"
        }
        return "Remove old versions and cached downloads to free up space"
    }

    // MARK: - Friendly result summaries (parse brew output into one clean line)

    // Doctor: brew prints "Your system is ready to brew." when clean, otherwise
    // one or more "Warning:" blocks. We surface a reassuring "Ready to brew" or,
    // when there are warnings, NAME them (e.g. "Untrusted taps, Broken symlinks")
    // so the user knows what to look at in Diagnostics below — not just a count.
    static func doctorSummary(_ lines: [String]) -> String {
        let joined = lines.joined(separator: "\n").lowercased()
        if joined.contains("ready to brew") { return "Ready to brew" }
        // Each warning starts with a "Warning:" line; turn those titles into
        // short labels, de-duplicating so repeated kinds don't pile up.
        var labels: [String] = []
        for line in lines where line.lowercased().hasPrefix("warning:") {
            let label = shortIssueLabel(from: line)
            if !labels.contains(label) { labels.append(label) }
        }
        if labels.isEmpty {
            // No explicit "ready" line and no warnings parsed: treat as healthy.
            return "Ready to brew"
        }
        let n = labels.count
        let prefix = "\(n) issue\(n == 1 ? "" : "s") found — "
        if labels.count <= 2 {
            return prefix + labels.joined(separator: ", ") + " (see Diagnostics)"
        }
        let shown = labels.prefix(2).joined(separator: ", ")
        return prefix + "\(shown) +\(labels.count - 2) more (see Diagnostics)"
    }

    // Cache cleanup: brew prints a trailing line like
    // "==> This operation has freed approximately 1.2GB of disk space."
    // Surface that figure; otherwise report a tidy generic result.
    static func cleanupSummary(_ lines: [String]) -> String {
        for line in lines {
            let l = line.lowercased()
            if l.contains("freed"), let range = l.range(of: "approximately") {
                // Pull the size token after "approximately".
                let after = String(l[range.upperBound...])
                    .replacingOccurrences(of: "of disk space.", with: "")
                    .replacingOccurrences(of: "of disk space", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty { return "Freed approximately \(after.uppercased())" }
            }
        }
        // brew prints nothing meaningful when the cache is already empty.
        let didRemove = lines.contains { $0.lowercased().hasPrefix("removing") || $0.lowercased().contains("pruned") }
        return didRemove ? "Cache cleaned" : "Cache already clean — nothing to remove"
    }

    // Auto Remove: brew lists "Removing: <formula>..." / "Uninstalling" lines, or
    // prints nothing when there are no orphaned dependencies.
    static func autoremoveSummary(_ lines: [String]) -> String {
        let removed = lines.filter {
            let l = $0.lowercased()
            return l.hasPrefix("removing") || l.hasPrefix("uninstalling")
        }.count
        if removed > 0 {
            return "Removed \(removed) unused package\(removed == 1 ? "" : "s")"
        }
        return "Nothing to remove — no unused dependencies"
    }

    // MARK: - Doctor section

    @ViewBuilder
    private var doctorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Diagnostics")
                    .font(.title3)
                    .fontWeight(.bold)
                // Re-run sits just to the right of the section title.
                PageRefreshButton("Re-run", isWorking: metrics.doctorLoading, size: .compact) {
                    Task { await metrics.loadDoctor(cli: appData.cli) }
                }
                Spacer()
            }
            // A one-line, plain-language recap that NAMES the issues brew doctor
            // found, so the user knows exactly what the cards below are about
            // instead of scanning a long page. Hidden while loading or clean.
            if !metrics.doctorLoading,
               let report = metrics.doctorReport,
               !report.isClean {
                let labels = report.findings.map { Self.doctorIssueLabel(for: $0) }
                let n = labels.count
                Text("^[\(n) issue](inflect: true) to review: \(labels.joined(separator: ", "))")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if metrics.doctorLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Running brew doctor…")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
            } else if let report = metrics.doctorReport {
                if report.isClean {
                    doctorRow(
                        icon: "checkmark.seal.fill",
                        iconColor: .green,
                        title: "Your system is ready to brew",
                        detail: "No issues found by brew doctor."
                    )
                } else {
                    // Three-tier severity:
                    //  • brew said "ready to brew" -> the findings are non-fatal
                    //    WARNINGS: yellow caution icon, plus a green "ready"
                    //    confirmation row beneath them.
                    //  • brew did NOT say "ready" -> the findings are FATAL
                    //    errors that actually block Homebrew: red error icon,
                    //    and no green confirmation.
                    let isFatal = !report.systemReady
                    let icon = isFatal ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
                    let tint: Color = isFatal ? .red : .yellow
                    VStack(spacing: 8) {
                        ForEach(report.findings) { finding in
                            if !finding.untrustedTaps.isEmpty {
                                untrustedTapsFinding(finding)
                            } else if Self.isCleanupFixable(finding) {
                                cleanupFixableRow(finding, tint: tint, icon: icon)
                            } else {
                                doctorRow(
                                    icon: icon,
                                    iconColor: tint,
                                    title: finding.occurrences > 1
                                        ? "\(finding.title)  (×\(finding.occurrences))"
                                        : finding.title,
                                    detail: finding.detail
                                )
                            }
                        }
                        // brew said the system is "ready to brew" even though it
                        // also printed the warning(s) above — they are non-fatal.
                        // Mirror brew by reassuring the user the system still
                        // works, in green beneath the warnings.
                        if report.systemReady {
                            doctorRow(
                                icon: "checkmark.seal.fill",
                                iconColor: .green,
                                title: "Your system is ready to brew",
                                detail: "The warning(s) above are non-fatal — Homebrew still works normally."
                            )
                        }
                    }
                }
            }
        }
    }
    // A brew-doctor finding is "cleanup-fixable" when brew itself tells the user
    // the remedy is `brew cleanup` (the classic case being broken symlinks like
    // /opt/homebrew/opt/python@3). We look in both the title and the detail so
    // we catch it regardless of which line carried the instruction.
    static func isCleanupFixable(_ finding: BrewCLIService.DoctorFinding) -> Bool {
        let haystack = (finding.title + " " + finding.detail).lowercased()
        return haystack.contains("brew cleanup")
    }

    // Runs `brew cleanup`, then re-runs brew doctor so the fixed finding clears
    // from the Diagnostics list on success.
    private func runInlineCleanup() {
        guard !cleanupFixRunning else { return }
        cleanupFixRunning = true
        Task {
            // Drain the cleanup stream to completion (we don't need the chatty
            // per-file log here — just to wait until brew is finished).
            let stream = await appData.cli.normalCleanup()
            for await _ in stream { }
            // Re-probe so the resolved finding disappears.
            await metrics.loadDoctor(cli: appData.cli)
            cleanupFixRunning = false
        }
    }

    // Like doctorRow, but with an inline "Run brew cleanup" fix button on the
    // right. Used for findings whose remedy is `brew cleanup` so the fix is one
    // click from the problem.
    private func cleanupFixableRow(_ finding: BrewCLIService.DoctorFinding,
                                   tint: Color = .yellow,
                                   icon: String = "exclamationmark.triangle.fill") -> some View {
        let title = finding.occurrences > 1
            ? "\(finding.title)  (×\(finding.occurrences))"
            : finding.title
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                if !finding.detail.isEmpty {
                    Text(finding.detail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Button(action: runInlineCleanup) {
                HStack(spacing: 6) {
                    if cleanupFixRunning {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(cleanupFixRunning ? "Cleaning…" : "Run brew cleanup")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(cleanupFixRunning)
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    private func doctorRow(icon: String, iconColor: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty {
                    Text(detail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }
    // MARK: - Untrusted taps (two-box layout)
    //
    // The user asked for a clean split: a top box listing each not-trusted tap
    // with what we know about it (when added, last updated, what it provides),
    // then a separate, shorter box that explains the Homebrew trust change in
    // plain language — not the full wall of brew command examples that brew
    // doctor prints, just the gist of what is happening and why.
    @ViewBuilder
    private func untrustedTapsFinding(_ finding: BrewCLIService.DoctorFinding) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Box 1 — the apps/taps that are not trusted.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                    Text(finding.title)
                    Spacer(minLength: 0)
                }
                ForEach(finding.untrustedTaps) { tap in
                    untrustedTapCard(tap)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
            // Box 2 — the concise explanation of the trust change.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                    Text("What this means")
                }
                Text(finding.detail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
        }
    }
    // One not-trusted tap as a compact card: name, a row of stat chips
    // (provides / added / updated), and any sample contents. Everything we
    // couldn't read off disk is simply omitted.
    @ViewBuilder
    private func untrustedTapCard(_ tap: BrewCLIService.UntrustedTap) -> some View {
        let busy = metrics.tapActionInFlight.contains(tap.name)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tap.name)
                    HStack(spacing: 6) {
                        tapStat("shippingbox", Self.tapProvidesText(tap))
                        if let added = tap.tappedDate {
                            tapStat("calendar.badge.plus", "Added \(Self.shortDate(added))")
                        }
                        if let updated = tap.lastUpdated {
                            tapStat("clock.arrow.circlepath", "Updated \(Self.shortDate(updated))")
                        }
                    }
                    if !tap.sampleNames.isEmpty {
                        Text("Includes: \(tap.sampleNames.joined(separator: ", "))")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                // Actions: Trust keeps the tap so Homebrew keeps loading and
                // updating it; Remove Tap deletes the tap's install recipes
                // (not your installed apps) after a confirmation. A spinner
                // replaces both while a brew action for this tap is in flight.
                if busy {
                    ProgressView().scaleEffect(0.6).frame(width: 60)
                } else {
                    HStack(spacing: 6) {
                        Button {
                            Task { await metrics.trustTap(tap.name, cli: appData.cli) }
                        } label: {
                            Text("Trust")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.orange)
                        .help("Tell Homebrew to keep loading and updating this tap (runs “brew trust”). Your installed apps keep getting updates.")
                        Button {
                            metrics.tapPendingUntap = tap.name
                        } label: {
                            Text("Remove Tap")
                        }
                        .buttonStyle(OutlinedButtonStyle())
                        .controlSize(.small)
                        .help("Remove this tap’s install recipes (runs “brew untap”). Your installed apps stay and keep running, but Homebrew stops tracking and updating them. Blocked if packages are still installed from it.")
                    }
                }
            }
            if let error = metrics.tapActionErrors[tap.name], !error.isEmpty {
                Text(error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(
            "Remove the tap “\(tap.name)”?",
            isPresented: Binding(
                get: { metrics.tapPendingUntap == tap.name },
                set: { if !$0 { metrics.tapPendingUntap = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Tap", role: .destructive) {
                metrics.tapPendingUntap = nil
                Task { await metrics.untapTap(tap.name, cli: appData.cli) }
            }
            Button("Cancel", role: .cancel) {
                metrics.tapPendingUntap = nil
            }
        } message: {
            Text("This deletes the tap’s install recipes (runs “brew untap \(tap.name)”). Apps you already installed from it stay on your Mac and keep running — but Homebrew will no longer update or track them. To manage them again later, re-add the tap with “brew tap \(tap.name)”. Homebrew will refuse if packages are still installed from this tap.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5))
    }
    private func tapStat(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(text)
        }
        .background(Color.secondary.opacity(0.1), in: Capsule())
    }
    // "3 casks", "1 cask, 2 formulae", etc. Falls back to a neutral label when
    // we couldn't read the tap's contents off disk.
    private static func tapProvidesText(_ tap: BrewCLIService.UntrustedTap) -> String {
        var parts: [String] = []
        if tap.caskCount > 0 { parts.append("\(tap.caskCount) cask\(tap.caskCount == 1 ? "" : "s")") }
        if tap.formulaCount > 0 { parts.append("\(tap.formulaCount) formula\(tap.formulaCount == 1 ? "" : "e")") }
        return parts.isEmpty ? "No items" : parts.joined(separator: ", ")
    }
    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
    // MARK: - Brewfile card
    // Backup & Restore entry point. Opens the full BrewfileView (export / import)
    // in a sheet. Lives on the Maintenance screen so the sidebar stays focused
    // on Installed and Updates.
    private var brewfileCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "doc.text")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Brewfile")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Export your setup to a Brewfile or reinstall everything from one")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showBrewfileSheet = true
                } label: {
                    Text("Export / Import…")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - ForgedBrew cache card

    // ForgedBrew's own downloaded-media cache (screenshots + favicons), as a single
    // card so it can sit in the two-up Cache row next to the Homebrew cache.
    private var forgedbrewCacheCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.teal.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "photo.stack")
                        .foregroundStyle(.teal)
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("ForgedBrew Cache")
                        .font(.system(size: 13, weight: .semibold))
                    Text(metrics.forgedbrewCacheSize.map { "Screenshots & icons — \($0) on disk" } ?? "Measuring…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    Task { await metrics.clearForgedBrewCache() }
                } label: {
                    Text("Clear Cache")
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(14)
            // Explanatory footnote (mirrors the Homebrew Cache card note):
            // reassures the user that clearing this cache is harmless.
            Divider()
            Text("These are the screenshots and app icons ForgedBrew downloads while "
                + "you search and view apps and casks. It is safe to clear them — "
                + "they are re-downloaded automatically the next time they are needed.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }
    private func healthCheckItem(text: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            Text(text)
        }
    }
}
/// Multi-select sheet listing every quarantined app across the folders ForgedBrew
/// scans (/Applications, ~/Applications, and the user's custom app folders).
/// The user can check any subset and remove quarantine, or use
/// the top button to clear quarantine from all listed files at once. Backed by
/// the shared `MaintenanceMetrics` (scan + removal state live there).
struct QuarantineSheet: View {
    @Bindable var metrics: MaintenanceMetrics
    let cli: BrewCLIService
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<String>()
    private var allSelected: Bool {
        !metrics.quarantinedItems.isEmpty &&
        selection.count == metrics.quarantinedItems.count
    }
    private var busy: Bool { metrics.quarantineScanning || metrics.quarantineRemoving }
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "lock.open")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quarantined Files")
                    // Keep this crisp instead of listing every scanned path — the
                    // custom folders could be several long paths. The actual set is
                    // /Applications + ~/Applications + the user's custom app folders
                    // (Settings), per AppLocationSettings.
                    Text("/Applications, ~/Applications & your custom app folders")
                }
                // Manual re-scan of the quarantine list, just to the right of
                // the title. Disabled while a scan or removal is in flight.
                PageRefreshButton("Re-scan", isWorking: busy, size: .compact, showsSpinner: false) {
                    Task { await metrics.loadQuarantinedItems(cli: cli) }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            // Padding so the title and the Re-scan/Done buttons aren't jammed
            // against the window's top and right edges (Done was getting clipped
            // in the top-right corner).
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            Divider()
            // Top action bar: remove-from-all + select-all toggle
            HStack(spacing: 12) {
                Button {
                    let paths = metrics.quarantinedItems.map(\.path)
                    Task {
                        await metrics.removeQuarantine(paths: paths, cli: cli)
                        selection.removeAll()
                    }
                } label: {
                    Text("Remove quarantine from all files")
                }
                .buttonStyle(PillActionButtonStyle())
                .disabled(busy || metrics.quarantinedItems.isEmpty)

                Spacer()

                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected {
                        selection.removeAll()
                    } else {
                        selection = Set(metrics.quarantinedItems.map(\.path))
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(busy || metrics.quarantinedItems.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // List / states
            Group {
                if metrics.quarantineScanning {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Scanning for quarantined files…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if metrics.quarantinedItems.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 30))
                            .foregroundStyle(.green)
                        Text("No quarantined files found")
                            .font(.system(size: 13, weight: .medium))
                        Text("None of your installed apps carry the quarantine flag.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(metrics.quarantinedItems) { item in
                                Button {
                                    toggle(item.path)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selection.contains(item.path) ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(selection.contains(item.path) ? Color.accentColor : Color.secondary)
                                            .font(.system(size: 15))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.displayName)
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(1)
                                            Text(item.path)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Error row (e.g. a removal that failed — System Integrity Protection / permissions)
            if let err = metrics.quarantineError, !err.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 12))
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            // Footer: remove-selected
            HStack {
                if metrics.quarantineRemoving {
                    ProgressView().scaleEffect(0.6)
                    Text("Removing…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(selection.count) selected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button {
                    let paths = Array(selection)
                    Task {
                        await metrics.removeQuarantine(paths: paths, cli: cli)
                        selection.removeAll()
                    }
                } label: {
                    Text("Remove Quarantine from Selected")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(selection.isEmpty ? AnyShapeStyle(Color.secondary.opacity(0.4)) : AnyShapeStyle(Color.accentColor),
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(busy || selection.isEmpty)
            }
            .padding(16)
        }
    }

    private func toggle(_ path: String) {
        if selection.contains(path) {
            selection.remove(path)
        } else {
            selection.insert(path)
        }
    }
}

// MARK: - Adopt Apps sheet

/// Lists apps in /Applications (and ~/Applications) that aren't managed by
/// Homebrew but match a known cask, and lets the user adopt each one
/// (`brew install --cask --adopt`). Mirrors the QuarantineSheet structure:
/// header + re-scan, a scrollable list of rows, and a footer. Per-row actions:
/// Adopt, Force-adopt (after a version-mismatch), Hide, and a manual cask
/// override for when the suggested token is wrong. A "Manage Hidden Apps"
/// disclosure lets the user unhide previously-hidden apps.
struct AdoptSheet: View {
    @Bindable var metrics: MaintenanceMetrics
    let casks: [CaskMetadata]
    let managedTokens: Set<String>
    let appData: AppDataService
    @Environment(\.dismiss) private var dismiss

    // Hidden apps are the user's deliberate "I'll manage this myself" choice, so
    // they stay collapsed by default — the sheet shows only the state the user
    // put each app in, never the adoptable + hidden lists side by side. A small
    // toggle reveals the hidden list when the user actually wants to unhide one.
    @State private var showHidden = false

    private var busy: Bool { metrics.adoptScanning || !metrics.adoptingTokens.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            warningBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        // Anchor the sheet to a SINGLE definite width (not a range) so AppKit
        // resolves layout in one top-down pass. A width range still let the
        // multi-line text and Spacer-driven rows re-negotiate width on first
        // layout, which trips _NSDetectedLayoutRecursion when the sheet opens.
        .frame(width: 600, height: 540)
        .task {
            // Scan for adoptable apps as soon as the sheet presents. This used to
            // live in the caller that opened the sheet; centralizing it here means
            // the scan runs exactly once per presentation regardless of which
            // entry point opened the sheet.
            await metrics.loadAdoptCandidates(casks: casks, managedTokens: managedTokens, cli: appData.cli, appData: appData)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Adopt Apps into Homebrew")
                    .font(.system(size: 15, weight: .bold))
                Text("\u{201C}Adopting\u{201D} hands an app you installed manually to Homebrew so you can update and remove it from ForgedBrew \u{2014} without losing your data. Review each match below, then Adopt. If an app can\u{2019}t be adopted in place (for example, a version mismatch), you have two options: in Mac Store/Other Apps, click Uninstall to remove it, then install the Homebrew version by searching for it and installing it from there \u{2014} so Homebrew keeps it updated. Or Hide it and keep managing it yourself.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Re-scan sits just to the right of the title, matching the main pages.
            PageRefreshButton("Re-scan", isWorking: busy, size: .compact, showsSpinner: false) {
                Task {
                    await metrics.loadAdoptCandidates(casks: casks, managedTokens: managedTokens, cli: appData.cli, appData: appData)
                }
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: Accuracy warning

    private var warningBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            Text("Always verify the suggested cask is correct before adopting. Detection may not always be accurate.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: Content (states)

    @ViewBuilder
    private var content: some View {
        if metrics.adoptScanning {
            VStack(spacing: 10) {
                ProgressView()
                Text("Scanning your apps…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if metrics.adoptCandidates.isEmpty && metrics.hiddenAdoptTokens.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(.green)
                Text("Nothing to adopt")
                    .font(.system(size: 13, weight: .medium))
                Text("Every app we recognized is already managed by Homebrew (or hidden).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Section 1 — Adoptable apps.
                    sectionHeader("Adoptable apps", systemImage: "square.and.arrow.down", count: metrics.adoptCandidates.count)
                    if metrics.adoptCandidates.isEmpty {
                        Text("No apps left to adopt — they\u{2019}re already managed by Homebrew or hidden below.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)
                    }
                    ForEach(metrics.adoptCandidates) { candidate in
                        AdoptRow(
                            candidate: candidate,
                            metrics: metrics,
                            casks: casks,
                            managedTokens: managedTokens,
                            appData: appData
                        )
                        Divider().padding(.leading, 16)
                    }

                    // Section 2 — Hidden apps. Collapsed by default behind a
                    // small toggle so the sheet shows only one list at a time:
                    // the user already chose to manage these, so they stay out
                    // of sight until the user asks to see them (to unhide).
                    if !metrics.hiddenAdoptTokens.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { showHidden.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showHidden ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                Image(systemName: "eye.slash")
                                    .font(.system(size: 11))
                                Text(showHidden
                                        ? "Hide \(metrics.hiddenAdoptTokens.count) hidden app\(metrics.hiddenAdoptTokens.count == 1 ? "" : "s")"
                                        : "Show \(metrics.hiddenAdoptTokens.count) hidden app\(metrics.hiddenAdoptTokens.count == 1 ? "" : "s")")
                                    .font(.system(size: 11, weight: .medium))
                                Spacer()
                            }
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 6)
                        }
                        .buttonStyle(.plain)

                        if showHidden {
                            Text("You chose to manage these yourself. Unhide one to bring it back into the adoptable list.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 4)
                            hiddenRows
                        }
                    }
                }
            }
        }
    }

    // A section title with an icon and a count pill, used to split the sheet
    // into "Adoptable apps" and "Hidden apps".
    private func sectionHeader(_ title: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15), in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    // The hidden-app rows, each with an Unhide button.
    private var hiddenRows: some View {
        ForEach(Array(metrics.hiddenAdoptTokens).sorted(), id: \.self) { token in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    AppIconView(token: token, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(InstalledRowView.displayName(for: token))
                            .font(.system(size: 12, weight: .medium))
                        Text(token)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button {
                        metrics.unhideAdopt(token: token)
                        Task {
                            await metrics.loadAdoptCandidates(casks: casks, managedTokens: managedTokens, cli: appData.cli, appData: appData)
                        }
                    } label: {
                        Label("Unhide", systemImage: "eye")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Bring this app back into the adoptable list")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider().padding(.leading, 16)
            }
        }
    }

    // MARK: Footer (count + adopting status)
    //
    // Hidden-app management now lives in the content area's "Hidden apps"
    // section (with per-app Unhide buttons), so the footer just shows progress
    // and a found-count summary.

    private var footer: some View {
        HStack {
            if !metrics.adoptingTokens.isEmpty {
                ProgressView().scaleEffect(0.6)
                Text("Adopting…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(metrics.adoptCandidates.count) app\(metrics.adoptCandidates.count == 1 ? "" : "s") found")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Adopt row

/// A single adoptable app: icon, name, suggested cask token, and actions.
/// Tapping "Adopt" runs `brew install --cask --adopt`; if that reports a version
/// mismatch a "Force" button appears to reinstall over it. "Change" reveals a
/// manual token override for when the suggestion is wrong, and "Hide" removes the
/// app from the list (persisted). Also runs the "smart" version diagnosis below
/// that flags a likely-wrong adoption (installed newer/older than the cask, or a
/// short-vs-long version-number shape) in red before the user commits.
private struct AdoptRow: View {
    let candidate: BrewCLIService.AdoptCandidate
    @Bindable var metrics: MaintenanceMetrics
    let casks: [CaskMetadata]
    let managedTokens: Set<String>
    let appData: AppDataService

    @State private var editingToken = false
    @State private var overrideText = ""

    // The token we'd actually adopt: the user's override if they typed one,
    // otherwise the suggested token.
    private var effectiveToken: String {
        let trimmed = overrideText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? candidate.suggestedToken : trimmed
    }

    private var isAdopting: Bool { metrics.adoptingTokens.contains(effectiveToken) || metrics.adoptingTokens.contains(candidate.suggestedToken) }

    private var outcome: AdoptOutcome? {
        metrics.adoptResults[effectiveToken] ?? metrics.adoptResults[candidate.suggestedToken]
    }

    // Offer Force only on a version mismatch (where reinstalling over the app
    // helps). Real failures like OneDrive don't get a Force button — it won't
    // help and would just fail again.
    private var showForce: Bool { outcome?.isMismatch ?? false }

    // Which side of the version comparison to flag in red, plus a short reason.
    // Drives the colored version line + warning beneath the app name.
    private enum FlaggedSide { case installed, homebrew }
    private struct VersionDiagnosis {
        var flagged: FlaggedSide?
        var message: String?
    }

    // Splits a version string into its leading integer components. Strips a
    // leading "v", splits on "." / "_" / "-", and reads the leading integer of
    // each piece (so "1.2606.0101" -> [1, 2606, 101], "v2.3-beta" -> [2, 3]).
    // Pieces with no leading digits are dropped so suffixes like "beta" don't
    // derail the numeric compare.
    private func versionComponents(_ raw: String) -> [Int] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let body = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst()) : trimmed
        let pieces = body.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
        var out: [Int] = []
        for piece in pieces {
            let digits = piece.prefix(while: { $0.isNumber })
            guard !digits.isEmpty, let n = Int(digits) else { continue }
            out.append(n)
        }
        return out
    }

    // The raw "." -separated part count, used to detect a short-vs-long version
    // shape (e.g. installed "1.2606" vs homebrew "1.2606.0101").
    private func dotPartCount(_ raw: String) -> Int {
        let body = raw.hasPrefix("v") || raw.hasPrefix("V") ? String(raw.dropFirst()) : raw
        return body.split(separator: ".").count
    }

    // Compares two component arrays lexically. Returns .orderedDescending when
    // `a` is newer than `b`, .orderedAscending when older, .orderedSame when the
    // shared leading components all match (ignoring extra trailing parts).
    private func compareComponents(_ a: [Int], _ b: [Int]) -> ComparisonResult {
        for i in 0..<min(a.count, b.count) {
            if a[i] != b[i] { return a[i] < b[i] ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // Smart checks the user asked for, comparing the installed app version with
    // the Homebrew (cask) version we'd adopt to. Two cases get flagged in red:
    //   1. Installed is NEWER than the Homebrew version (e.g. Caffeine): the
    //      lower Homebrew version is highlighted with a "newer on installed" note.
    //   1b. Installed is OLDER than the Homebrew version (e.g. Hidden Bar 1.8 vs
    //      1.10 — dotted/semver, so 1.10 is newer): the installed version is
    //      flagged with a note to install the newer Homebrew build and remove the
    //      old copy. (1.10 > 1.8 because .10 is the 10th minor release, not a decimal.)
    //   2. The two share the same leading numbers but one is a longer dotted
    //      release string (e.g. Copilot installed "1.2606" vs cask "1.2606.0101"):
    //      the longer version is flagged as a possible adoption mismatch.
    // Anything else (homebrew newer, equal, or unparseable) is not flagged.
    private var versionDiagnosis: VersionDiagnosis {
        guard let installedRaw = candidate.installedVersion,
              let homebrewRaw = candidate.latestVersion,
              !installedRaw.isEmpty, !homebrewRaw.isEmpty,
              installedRaw != homebrewRaw else { return VersionDiagnosis() }

        let inst = versionComponents(installedRaw)
        let hb = versionComponents(homebrewRaw)
        guard !inst.isEmpty, !hb.isEmpty else { return VersionDiagnosis() }

        let order = compareComponents(inst, hb)

        // Case 1: installed strictly newer than the Homebrew version.
        if order == .orderedDescending {
            return VersionDiagnosis(flagged: .homebrew,
                                    message: "Version is newer on currently installed.")
        }

        // Case 1b: installed strictly OLDER than the Homebrew version (e.g.
        // Hidden Bar installed 1.8 vs Homebrew 1.10 — 1.10 is the newer release,
        // dotted/semver, NOT a decimal). Rather than adopt the stale build in
        // place, point the user at the newer Homebrew version and the removal
        // paths for the old copy. Flag the lower (installed) version.
        if order == .orderedAscending {
            return VersionDiagnosis(flagged: .installed,
                                    message: "Homebrew has a newer version (\(homebrewRaw)) than the installed \(installedRaw). To manage it through Homebrew, click Uninstall in Mac Store/Other Apps to remove it, then install the Homebrew version by searching for it and installing it there \u{2014} or Hide it and keep managing it yourself.")
        }

        // Case 2: leading numbers match, but one string has extra dotted parts.
        // Flag the LONGER one (and only when there's a real dot-count gap, like
        // "1.2606" vs "1.2606.0101", not just trailing zero differences).
        if order == .orderedSame {
            let instDots = dotPartCount(installedRaw)
            let hbDots = dotPartCount(homebrewRaw)
            if instDots != hbDots {
                let longerIsHomebrew = hbDots > instDots
                return VersionDiagnosis(
                    flagged: longerIsHomebrew ? .homebrew : .installed,
                    message: "Version numbers differ in length — this app may not be adoptable due to versioning.")
            }
        }

        return VersionDiagnosis()
    }

    // The trailing "added <date>" context, when we have an install date.
    private var addedDateText: String? {
        guard let date = candidate.installDate else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return "added \(f.string(from: date))"
    }

    // True when we have any version/date context to render at all.
    private var hasInfoLine: Bool {
        candidate.installedVersion != nil || candidate.latestVersion != nil || candidate.installDate != nil
    }

    // The version context line, rendered as separate colored segments so we can
    // flag a single version in red per `versionDiagnosis`. Styled to match the
    // larger, mid-bold secondary text used on the Installed/Updates screens
    // (size 12, semibold) rather than the old tiny tertiary text.
    @ViewBuilder
    private var infoLineView: some View {
        let diag = versionDiagnosis
        HStack(spacing: 8) {
            if let v = candidate.installedVersion, !v.isEmpty {
                Text("Installed \(v)")
                    .foregroundStyle(diag.flagged == .installed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
            }
            if let latest = candidate.latestVersion, !latest.isEmpty,
               latest != candidate.installedVersion {
                Text("Homebrew \(latest)")
                    .foregroundStyle(diag.flagged == .homebrew ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
            }
            if let added = addedDateText {
                Text(added)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .lineLimit(1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                AppIconView(token: candidate.suggestedToken, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.appName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text("cask:")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(effectiveToken)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button {
                            editingToken.toggle()
                        } label: {
                            Text(editingToken ? "Done" : "Change")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    // Version / install-date context so the user can decide.
                    // Now larger + mid-bold (matching the Installed/Updates
                    // screens) and color-flagged when a version looks off.
                    if hasInfoLine {
                        infoLineView
                    }
                    // Smart version warning (installed newer than Homebrew, or a
                    // short-vs-long version-number mismatch). Shown in red just
                    // beneath the version line so the user understands the flag.
                    if let warning = versionDiagnosis.message {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.red)
                            Text(warning)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 1)
                    }
                }
                Spacer()

                if isAdopting {
                    ProgressView().scaleEffect(0.6)
                } else {
                    HStack(spacing: 8) {
                        if showForce {
                            adoptButton(title: "Force", force: true, filled: true)
                        }
                        adoptButton(title: "Adopt", force: false, filled: !showForce)
                        Button {
                            metrics.hideAdopt(token: candidate.suggestedToken)
                        } label: {
                            Text("Hide")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if editingToken {
                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    TextField(candidate.suggestedToken, text: $overrideText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: 220)
                    Text("The suggested cask may be wrong — enter the correct one.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.leading, 44)
            }

            if let outcome {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: outcomeIcon(outcome))
                        .font(.system(size: 10))
                        .foregroundStyle(outcomeColor(outcome))
                    Text(outcome.message)
                        .font(.system(size: 10))
                        .foregroundStyle(outcome.isFailure ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.leading, 44)
                .padding(.trailing, 16)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func outcomeIcon(_ o: AdoptOutcome) -> String {
        switch o {
        case .success: return "checkmark.circle.fill"
        case .mismatch: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.circle.fill"
        case .unknown: return "info.circle"
        }
    }

    private func outcomeColor(_ o: AdoptOutcome) -> AnyShapeStyle {
        switch o {
        case .success: return AnyShapeStyle(Color.green)
        case .mismatch: return AnyShapeStyle(Color.orange)
        case .failure: return AnyShapeStyle(Color.red)
        case .unknown: return AnyShapeStyle(Color.secondary)
        }
    }

    @ViewBuilder
    private func adoptButton(title: String, force: Bool, filled: Bool) -> some View {
        Button {
            Task {
                await metrics.adopt(
                    token: effectiveToken,
                    force: force,
                    casks: casks,
                    managedTokens: managedTokens,
                    cli: appData.cli,
                    appData: appData
                )
                // Refresh the Installed list so the adopted app is recognized
                // as managed everywhere in the app.
                await appData.refreshInstalled()
            }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    filled
                        ? (force ? AnyShapeStyle(Color.white) : AnyShapeStyle(ActionColors.adoptText))
                        : AnyShapeStyle(ActionColors.adopt)
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    filled ? AnyShapeStyle(force ? ActionColors.update : ActionColors.adopt)
                           : AnyShapeStyle(ActionColors.adopt.opacity(0.14)),
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
    }
}
