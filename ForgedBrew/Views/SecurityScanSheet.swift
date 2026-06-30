import SwiftUI
import AppKit

// A short "Last scanned <date>" caption for a scan sheet footer. Returns an
// empty string for a never-run scan (.distantPast) so callers can hide it.
// Defined once at module scope here and reused by TrustMaintenanceSheet.
func lastScannedCaption(_ date: Date) -> String {
    guard date != .distantPast else { return "" }
    let df = DateFormatter()
    df.dateStyle = .medium
    df.timeStyle = .short
    return "Last scanned \(df.string(from: date))"
}

// MARK: - SecurityScanSheet
//
// The Diagnostics / Security Scan sheet. It runs macOS's own security tooling
// (codesign + spctl — the same checks Gatekeeper performs when you first open
// an app) against every installed app bundle — Homebrew casks plus everything in
// the user's scanned folders (/Applications, ~/Applications, custom) — and
// reports a per-app pass / fail.
//
// IMPORTANT (design principle): the sheet always tells the user exactly WHAT it is
// scanning for, both before they run it (the "What this scan checks" panel) and
// after (per-app verdicts with the four individual checks). No network access —
// this layer is purely local signature / notarization / Gatekeeper inspection.
//
// Layout follows the other Maintenance sheets: a single definite frame so
// AppKit lays out in one pass (avoids _NSDetectedLayoutRecursion); no
// GeometryReader; one fixed source-of-truth width per row.
struct SecurityScanSheet: View {
    // Shared maintenance state hub: owns the live scan counters
    // (securityScannedCount/TotalCount/CurrentApp), the persisted report +
    // securityScannedAt timestamp, and loadSecurityScan(...) which streams
    // per-app verdicts in as each codesign/spctl check completes.
    @Bindable var metrics: MaintenanceMetrics
    // Used to enumerate the installed app bundles to inspect (casks + all apps
    // in the user's scanned folders, via installedAppBundlesToSecurityScan()).
    let cli: BrewCLIService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 620, height: 580)
        // Use the pure-SwiftUI spinner for every ProgressView in this sheet.
        // A sheet is presented in its own hosting context and does NOT reliably
        // inherit the .progressViewStyle(.forgedbrew) applied at the WindowGroup
        // root (the sibling Settings/Welcome/Manual windows re-apply it for the
        // same reason). Without this, the bare ProgressView()s here (the header
        // Scan-button spinner, the progress block, the footer) fall back to the
        // AppKit NSProgressIndicator, which "ghosts" — briefly drawing a grey
        // spinner at the sheet's top-center on each re-layout as scan results
        // stream in. The custom style draws with SwiftUI shapes and fixed
        // frames, so there is no AppKit host to ghost.
        .progressViewStyle(.forgedbrew)
        // Disable ALL implicit animations on the sheet while a scan runs. As
        // each app finishes, counts change and per-app result rows stream in;
        // SwiftUI's default transitions would slide/fade a grey checkmark
        // symbol across the header ("ghost" effect). Killing animation at the
        // root makes everything appear in place with no movement or flicker.
        .transaction { $0.animation = nil }
        .task {
            // Auto-run the scan when the sheet opens. loadSecurityScan now
            // self-guards: it reuses the saved report while it's fresh (within
            // the 24h window) and only re-runs once it's stale, so subsequent
            // opens show the saved results immediately without re-scanning.
            await metrics.loadSecurityScan(cli: cli)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.blue)
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Security Scan")
                    .font(.system(size: 15, weight: .bold))
                Text("Signature, identity, notarization & Gatekeeper checks")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            // Scan/Re-scan sits just to the right of the title, matching the main pages.
            // Unlike the auto-run .task (which honours the 24h freshness gate),
            // the explicit button passes force: true so a deliberate Re-scan
            // always re-runs, even when the saved report is still fresh.
            PageRefreshButton(metrics.securityHasScanned ? "Re-scan" : "Scan",
                              isWorking: metrics.securityScanning,
                              size: .compact,
                              showsSpinner: false) {
                Task { await metrics.loadSecurityScan(cli: cli, force: true) }
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: Content states

    @ViewBuilder
    private var content: some View {
        if let err = metrics.securityError, metrics.securityHasScanned, metrics.securityResults.isEmpty {
            // Hard error with nothing to show (e.g. no casks installed).
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // The explainer is shown ALWAYS — before, during, and after a
                    // scan — so the user always knows what the scan is doing.
                    checksExplainer

                    // Live progress bar while scanning.
                    if metrics.securityScanning {
                        Divider()
                        progressBlock
                    }

                    // Summary chips once we have any results (live or final).
                    if !metrics.securityResults.isEmpty {
                        Divider()
                        if !metrics.securityScanning { summaryBlock }
                        // Results appear here one-by-one as each app finishes.
                        resultsList
                    }
                }
                .padding(20)
            }
        }
    }

    // MARK: Live progress (during a scan)

    private var progressBlock: some View {
        let done = metrics.securityScannedCount
        let total = max(metrics.securityTotalCount, 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6)
                Text("Scanning \(done) of \(metrics.securityTotalCount)…")
                    .font(.system(size: 12, weight: .medium))
                if let app = metrics.securityCurrentApp {
                    Text("— \(app)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ProgressView(value: Double(done), total: Double(total))
                .frame(width: 540)
            // Same reassurance the Trust scan shows: these checks run macOS's
            // own security tools on every installed app, so a large library can
            // take a while — the note keeps the wait from reading as a hang.
            Text("This scan can take a few minutes — depending on how many apps are being checked. ForgedBrew runs macOS's own security tools on each one.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 540, alignment: .leading)
        }
        .frame(width: 540, alignment: .leading)
    }

    // MARK: What this scan checks (always visible)

    private var checksExplainer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("What this scan checks")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text("For every installed app — your Homebrew casks plus everything in /Applications, ~/Applications, and your custom folders — ForgedBrew runs macOS's own security tools, the same checks Gatekeeper performs when you first open an app. Nothing leaves your Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 540, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(SecurityCheckInfo.all) { check in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 11))
                            .foregroundStyle(.blue)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.title)
                                .font(.system(size: 11, weight: .semibold))
                            Text(check.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(width: 540, alignment: .leading)
                }
            }

            // Awareness banner — prominent, near the top so users see it before
            // reading any per-app results. Most casks legitimately trip a warning.
            Text("These flags are for awareness, not alarm. An app can be unsigned or not notarized for perfectly legitimate reasons (open-source tools, older apps). A warning doesn’t mean the app is malware — it just means one of macOS’s guarantees is missing, so you can decide whether you trust it.")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 540, alignment: .leading)
                .background(color(for: .yellow).opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(width: 540, alignment: .leading)
    }

    // MARK: Summary (after a scan)

    private var summaryBlock: some View {
        let r = metrics.securityReport
        return VStack(alignment: .leading, spacing: 10) {
            // Headline verdict line.
            HStack(spacing: 8) {
                Image(systemName: r.headlineStatus.symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(color(for: r.headlineStatus.tint))
                Text(headline(for: r))
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            // Count chips.
            HStack(spacing: 10) {
                summaryChip(count: r.passedCount, label: "passed", token: .green)
                if r.warnCount > 0 {
                    summaryChip(count: r.warnCount, label: "warnings", token: .yellow)
                }
                if r.failedCount > 0 {
                    summaryChip(count: r.failedCount, label: "unverified", token: .red)
                }
                Spacer()
            }

            // What we found — only the apps that need attention, named, with the
            // specific reason so it's clear WHY each was flagged.
            if r.failedCount > 0 || r.warnCount > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What we found")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(flaggedResults(r)) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: item.overall.symbol)
                                .font(.system(size: 10))
                                .foregroundStyle(color(for: item.overall.tint))
                                .frame(width: 14)
                            Text(item.appName)
                                .font(.system(size: 11, weight: .medium))
                            Text("— " + item.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .frame(width: 540, alignment: .leading)
                    }
                }
                .padding(.top, 2)

            }
        }
        .frame(width: 540, alignment: .leading)
    }

    // A plain-language headline for the whole scan.
    private func headline(for r: SecurityScanReport) -> String {
        if r.totalCount == 0 { return "No apps scanned" }
        if r.failedCount == 0 && r.warnCount == 0 {
            return "All \(r.totalCount) apps passed — signed, notarized & accepted by Gatekeeper"
        }
        var parts: [String] = []
        if r.failedCount > 0 { parts.append("\(r.failedCount) need attention") }
        if r.warnCount > 0 { parts.append("\(r.warnCount) with warnings") }
        return "\(r.passedCount) of \(r.totalCount) passed — \(parts.joined(separator: ", "))"
    }

    // Only the apps that didn't fully pass, worst-first, for the findings list.
    private func flaggedResults(_ r: SecurityScanReport) -> [AppSecurityResult] {
        r.sortedResults.filter { $0.overall == .fail || $0.overall == .warn }
    }

    private func summaryChip(count: Int, label: String, token: ColorToken) -> some View {
        HStack(spacing: 5) {
            Text("\(count)")
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundStyle(color(for: token))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color(for: token).opacity(0.12), in: Capsule())
    }

    // MARK: Per-app results

    private var resultsList: some View {
        VStack(spacing: 10) {
            ForEach(metrics.securityReport.sortedResults) { result in
                AppSecurityRow(result: result)
            }
        }
        .frame(width: 540, alignment: .leading)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("A “passed” app is signed by an identifiable developer, notarized by Apple, and accepted by Gatekeeper")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            // Timestamp of the saved/just-completed scan, so the user knows how
            // fresh the results are.
            if metrics.securityHasScanned {
                Text(lastScannedCaption(metrics.securityScannedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    // Maps a model ColorToken to a concrete SwiftUI Color (model stays SwiftUI-free).
    private func color(for token: ColorToken) -> Color {
        switch token {
        case .blue:   return .blue
        case .teal:   return .teal
        case .purple: return .purple
        case .orange: return .orange
        case .gray:   return .gray
        case .green:  return .green
        case .red:    return .red
        case .yellow: return .yellow
        }
    }
}
// MARK: - AppSecurityRow
//
// One scanned app: name + overall badge, a one-line plain summary, the four
// individual check badges, and a Reveal-in-Finder affordance. A single definite
// width keeps AppKit's layout in one pass.
private struct AppSecurityRow: View {
    let result: AppSecurityResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: result.overall.symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(color(for: result.overall.tint))
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.appName)
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if !result.summary.isEmpty {
                        Text(result.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: result.appPath)]
                    )
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Reveal in Finder")
            }

            // The four individual checks as small status badges.
            HStack(spacing: 6) {
                checkBadge(title: "Signature", status: result.signatureCheck)
                checkBadge(title: "Identity", status: result.identityCheck)
                checkBadge(title: "Notarized", status: result.notarizationCheck)
                checkBadge(title: "Gatekeeper", status: result.gatekeeperCheck)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(width: 516, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }

    private func checkBadge(title: String, status: SecurityCheckStatus) -> some View {
        HStack(spacing: 3) {
            Image(systemName: status.symbol)
                .font(.system(size: 9))
            Text(title)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color(for: status.tint))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color(for: status.tint).opacity(0.12), in: Capsule())
    }

    private func color(for token: ColorToken) -> Color {
        switch token {
        case .blue:   return .blue
        case .teal:   return .teal
        case .purple: return .purple
        case .orange: return .orange
        case .gray:   return .gray
        case .green:  return .green
        case .red:    return .red
        case .yellow: return .yellow
        }
    }
}
