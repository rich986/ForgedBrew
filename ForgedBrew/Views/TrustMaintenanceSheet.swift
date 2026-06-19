import SwiftUI
import AppKit

// MARK: - TrustMaintenanceSheet
//
// Proactive heads-up for an upcoming Homebrew change. By September 1, 2026,
// Homebrew is removing casks that fail macOS Gatekeeper (unsigned/unnotarized)
// from the official tap and dropping its quarantine workaround
// (Homebrew/brew#20755). IMPORTANT distinction so the copy stays honest:
//   • Installed apps are NOT deleted or disabled. They keep running.
//   • What is lost is the UPDATE PATH — once a cask leaves the official tap,
//     Homebrew can no longer upgrade or track that app, so it goes stale.
//   • Clearing the quarantine flag here lets a Gatekeeper-rejected app keep
//     LAUNCHING, but it does NOT restore updates. Nothing the app does locally
//     can bring a removed cask back into Homebrew's update path.
//
// This sheet evaluates ALL the trust checks (signature, Developer ID,
// notarization, Gatekeeper) for every installed cask app and lists every one
// that macOS Gatekeeper would reject — i.e. the apps that would hit the "can't
// be opened" wall after Sept 1 unless their developer ships a fix. Each app is
// labelled with the SPECIFIC checks it fails. The list is split into two tiers:
//
//   • Trust now  — the app is Gatekeeper-rejected AND still carries the
//                  com.apple.quarantine flag, so the Trust button can clear it
//                  today (`xattr -d com.apple.quarantine`, no sudo) and keep the
//                  app launching. This is the SAME operation as the Maintenance
//                  ▸ Remove Quarantine page, scoped to this one app.
//   • Watch for Sept 1 — the app is Gatekeeper-rejected but has no quarantine
//                  flag to clear right now, so there's nothing to act on. It's
//                  shown informationally so the user can keep an eye on it (a
//                  popular app will likely be re-signed/notarized before the
//                  deadline). If macOS re-quarantines it on a future upgrade,
//                  the Remove Quarantine page is where to clear it.
//
// The screen is primarily INFORMATIONAL. The copy is careful to frame the Trust
// action as "keeps it running, not updating," never as a full fix.
//
// Mirrors OrphansSheet/AdoptSheet: a single fixed frame (so AppKit lays out in
// one pass and avoids _NSDetectedLayoutRecursion), header with Re-scan + Done,
// a warning bar explaining the change, and scanning / empty / list states.
struct TrustMaintenanceSheet: View {
    @Bindable var metrics: MaintenanceMetrics
    let cli: BrewCLIService
    @Environment(\.dismiss) private var dismiss

    // Muted yellow used for the actionable "Trust" affordance — present but not
    // alarming, since trusting is a deliberate, low-urgency choice.
    private static let trustYellow = Color(red: 0.78, green: 0.62, blue: 0.07)

    private var busy: Bool {
        metrics.trustScanning || !metrics.trustingPaths.isEmpty
    }

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
        // Single definite size (see OrphansSheet) to keep AppKit's layout to one
        // top-down pass.
        .frame(width: 640, height: 580)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.blue)
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Trust Management Screening")
                    .font(.system(size: 15, weight: .bold))
                Text("Apps that fail macOS Gatekeeper and are at risk after Sept 1, 2026")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            // Re-scan sits just to the right of the title, matching the main pages.
            PageRefreshButton("Re-scan", isWorking: busy, size: .compact) {
                rescan()
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        // Padding so the title/subtitle and the Re-scan/Done buttons aren't
        // jammed against the window's top and right edges (the buttons were
        // getting clipped in the top-right corner).
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: Change-explanation warning bar
    private var warningBar: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("From September 1, 2026, Homebrew is removing casks that fail macOS Gatekeeper from its official tap. These apps won’t be deleted and will keep running for now — but Homebrew will stop updating or tracking them, and once Homebrew drops its quarantine workaround they can hit the “can’t be opened” wall. Each app below is labelled with the exact checks it fails. Where a quarantine flag is present, the muted-yellow Trust button clears it (the same action as Maintenance ▸ Remove Quarantine) so a trusted app keeps launching — it does not restore Homebrew updates. Apps with no flag to clear are listed so you can keep an eye on them; many popular apps will be re-signed before the deadline.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        // Inset the warning copy from the window edges so it isn't flush against
        // the sides, and give it vertical room from the divider above/below.
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: Content states
    @ViewBuilder
    private var content: some View {
        if metrics.trustScanning {
            scanningProgress
        } else if metrics.gatekeeperRiskResult.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                Text("Nothing at risk")
                Text(metrics.trustHasScanned
                     ? "Every installed app passes macOS Gatekeeper on its own, so the upcoming Homebrew change won’t stop them launching."
                     : "Run a scan to check your installed apps against the upcoming Homebrew change.")
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let actionable = metrics.gatekeeperRiskResult.actionable
                    let watch = metrics.gatekeeperRiskResult.watchOnly

                    if !actionable.isEmpty {
                        sectionHeader(
                            title: "Trust now",
                            count: actionable.count,
                            subtitle: "Fails Gatekeeper and still carries the quarantine flag. Trust clears it so the app keeps launching."
                        )
                        ForEach(actionable) { risk in
                            GatekeeperRiskRow(risk: risk, metrics: metrics, cli: cli)
                            Divider().padding(.leading, 16)
                        }
                    }

                    if !watch.isEmpty {
                        sectionHeader(
                            title: "Watch for Sept 1",
                            count: watch.count,
                            subtitle: "Fails Gatekeeper but has no quarantine flag to clear right now — nothing to act on yet. Keep an eye out; the developer may ship a signed, notarized update before the deadline."
                        )
                        ForEach(watch) { risk in
                            GatekeeperRiskRow(risk: risk, metrics: metrics, cli: cli)
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
        }
    }

    // MARK: Section header (tier separator inside the list)
    private func sectionHeader(title: String, count: Int, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: Live scan progress
    private var scanningProgress: some View {
        VStack(spacing: 14) {
            ProgressView(
                value: Double(metrics.trustScannedCount),
                total: Double(max(metrics.trustTotalCount, 1))
            )
            .progressViewStyle(.linear)
            .frame(maxWidth: 360)
            VStack(spacing: 4) {
                if metrics.trustTotalCount > 0 {
                    Text("Scanning \(metrics.trustScannedCount) of \(metrics.trustTotalCount)…")
                } else {
                    Text("Preparing scan…")
                }
                if let current = metrics.trustCurrentApp, !current.isEmpty {
                    Text(current)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Text("This scan can take a few minutes — depending on how many apps are being checked. macOS runs a full Gatekeeper assessment on each one.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer
    private var footer: some View {
        VStack(spacing: 8) {
            // No "Trust All": trusting is a deliberate, per-app decision. The
            // user clicks Trust on each app they recognize, one at a time, so
            // they consciously vouch for each source rather than clearing a
            // whole batch at once.
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                Text("Trust keeps an app launching — not updating. Trust apps one at a time, only sources you recognize.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(16)
    }

    private func rescan() {
        Task { await metrics.loadGatekeeperRisks(cli: cli) }
    }
}

// MARK: - GatekeeperRiskRow
//
// One at-risk app: shield icon + app name + token, the specific failing trust
// checks as small badges, the bundle path with Reveal in Finder, and — only
// when the app still carries a quarantine flag (risk.actionable) — a muted
// yellow Trust button that clears it. Watch-only apps (no flag to clear) show
// an informational note pointing to Maintenance ▸ Remove Quarantine instead of
// a button, so we never offer a no-op action. Failures surface inline in red.
struct GatekeeperRiskRow: View {
    let risk: GatekeeperRisk
    @Bindable var metrics: MaintenanceMetrics
    let cli: BrewCLIService

    private static let trustYellow = Color(red: 0.78, green: 0.62, blue: 0.07)

    var body: some View {
        let isTrusting = metrics.trustingPaths.contains(risk.appPath)
        let error = metrics.trustErrors[risk.appPath]

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.orange.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: "exclamationmark.shield")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 6) {
                    Text(risk.appName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(risk.token)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: risk.appPath)]
                    )
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                // Only an app that still carries a quarantine flag has anything
                // for the Trust button to clear. Watch-only apps get no button.
                if risk.actionable {
                    if isTrusting {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Button {
                            Task { await metrics.trustApp(risk, cli: cli) }
                        } label: {
                            Text("Trust")
                        }
                        .buttonStyle(PillActionButtonStyle(tint: Self.trustYellow, cornerRadius: 7))
                        .help("Clears the quarantine flag (xattr -d com.apple.quarantine) so this app keeps launching. Same as Maintenance ▸ Remove Quarantine. Does not restore Homebrew updates.")
                        .disabled(!metrics.trustingPaths.isEmpty || metrics.trustScanning)
                    }
                }
            }

            // The specific trust checks this app fails, as small badges, so the
            // user sees exactly what wouldn't pass on Sept 1.
            HStack(spacing: 6) {
                ForEach(risk.failedChecks, id: \.self) { check in
                    Text(check)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.orange.opacity(0.12))
                        )
                }
                // Make it explicit when there is no local fix available yet.
                if !risk.actionable {
                    Text("No quarantine flag to clear — watch for Sept 1")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 38)

            // Signing authority (who signed it), when present, for context.
            if let authority = risk.signingAuthority, !authority.isEmpty {
                Text(authority)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 38)
            }

            // Bundle path (monospaced, middle-truncated) so the user can see
            // exactly which app this is.
            Text(risk.appPath)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 38)

            if let error, !error.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
