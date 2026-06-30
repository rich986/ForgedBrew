import Foundation
import AppKit

// MARK: - AppUpdateService
//
// Detects available updates for NON-Homebrew apps (App Store + direct-download)
// and manages the user's "parked" (held) app-update records. Backs the App
// Updates sidebar. See AppUpdate.swift for the data model and the rationale.
//
// Detection is best-effort and resilient: any single app that fails to scan
// (unreadable plist, network error, malformed appcast) is skipped, never
// aborting the whole scan. Network work runs off the main actor; only the
// published results are written back on the actor.
//
// Park state lives in UserDefaults (key below) as JSON, an ignored-app-updates
// record — deliberately NOT in the GRDB schema, so this
// non-brew feature stays decoupled from the brew database and needs no
// migration.
//
// @Observable + @MainActor so SwiftUI views observe `updates` / `parked` /
// `isScanning` directly, consistent with AppDataService.
@MainActor
@Observable
final class AppUpdateService {
    static let shared = AppUpdateService()
    private init() { loadParked() }

    // Detected available updates for non-parked apps, newest-scan wins.
    var updates: [AppUpdate] = []
    // Every installed non-Homebrew app (both categories), whether or not it
    // has an update. Drives the "All apps" lists on the Mac Store / Other
    // Apps screen. Rebuilt on each scan.
    var allApps: [InstalledApp] = []
    // Parked (held) app-update records, keyed by bundle id.
    var parked: [String: ParkedAppUpdate] = [:]
    var isScanning = false
    // True once scan() has completed at least one full pass this session.
    // The Mac Store/Other Apps view uses this to avoid re-scanning every
    // time the user navigates into it; the launch refresh / manual Rescan /
    // post-action rescans keep the list current.
    var hasScannedOnce = false
    var lastScanError: String?
    // Whether the `mas` CLI is available. When false, App Store apps can still
    // be listed and routed to the store, but we can't read their available
    // version. Surfaced in the view as an informational note.
    var masAvailable = false

    // Bundle ids whose most recent in-place update attempt failed this session.
    // Drives the "some apps can't be updated this way — park them" banner on
    // the Mac Store/Other Apps screen. Memory-only and cleared when the user
    // dismisses the banner, parks the app, or a later update for it succeeds.
    var recentUpdateErrors: Set<String> = []
    // Friendly app names for the errored bundle ids, so the banner can name them.
    var recentUpdateErrorNames: [String: String] = [:]

    // Record / clear in-place update errors (called from AppDataService when an
    // app-update run settles).
    func recordUpdateError(bundleID: String, appName: String) {
        recentUpdateErrors.insert(bundleID)
        recentUpdateErrorNames[bundleID] = appName
    }
    func clearUpdateError(bundleID: String) {
        recentUpdateErrors.remove(bundleID)
        recentUpdateErrorNames[bundleID] = nil
    }
    func clearAllUpdateErrors() {
        recentUpdateErrors.removeAll()
        recentUpdateErrorNames.removeAll()
    }
    // Names of the currently-errored apps, sorted, for display in the banner.
    func updateErrorAppNames() -> [String] {
        recentUpdateErrors.compactMap { recentUpdateErrorNames[$0] }.sorted()
    }

    private let parkedDefaultsKey = "forgedbrewParkedAppUpdates"
    // A browser-like UA: some appcast hosts (e.g. CDNs) reject empty/curl UAs.
    // Accessed from nonisolated network code (fetch(url:)), so it must be
    // actor-independent. It is an immutable constant, so this is safe.
    private nonisolated static let userAgent = "ForgedBrew/1.0 Sparkle/2.0"

    // MARK: - Public API

    // The current list of updates with parked apps removed, sorted by name.
    // The view binds to this so parking an app immediately drops it from view.
    func visibleUpdates() -> [AppUpdate] {
        updates
            .filter { parked[$0.bundleID] == nil }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    // Installed apps in one category (Mac Store / Other Apps), sorted by
    // name. Used for the "All apps" section.
    func installedApps(category: AppCategory) -> [InstalledApp] {
        allApps
            .filter { $0.category == category }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    // Visible (non-parked) updates within one category, sorted by name.
    // Used for the "Updates available" section.
    func visibleUpdates(category: AppCategory) -> [AppUpdate] {
        let wantStore = (category == .macStore)
        return visibleUpdates().filter { ($0.source == .appStore) == wantStore }
    }

    // Filter-aware variants for the segmented control, which now offers an
    // "All" option in addition to the two storage categories. "All" returns
    // everything across both categories.
    func installedApps(filter: AppCategoryFilter) -> [InstalledApp] {
        guard let category = filter.category else {
            return allApps
                .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
        }
        return installedApps(category: category)
    }

    func visibleUpdates(filter: AppCategoryFilter) -> [AppUpdate] {
        guard let category = filter.category else {
            return visibleUpdates()
        }
        return visibleUpdates(category: category)
    }

    // Parked records joined with their (possibly newer) available version, for
    // the App Updates "Parked" affordance. Sorted by name.
    func parkedList() -> [ParkedAppUpdate] {
        parked.values.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    // Full scan: enumerate non-Homebrew apps and detect updates from all three
    // sources. `managedAppPaths` are the resolved .app paths Homebrew already
    // manages (from AppDataService) — those are excluded, since the brew Updates
    // screen owns them.
    func scan(managedAppPaths: Set<String>, casks: [CaskMetadata]) async {
        // Re-entrancy guard: a launch refresh and the user opening the
        // "Mac Store/Other Apps" page can both kick a scan at nearly the same
        // time. Without this, two scans run concurrently and the second one
        // flips isScanning back to false while the first is still working —
        // which is part of why "rescan across the board" looked stuck after a
        // while (Bug 4). Coalesce to a single in-flight scan.
        guard !isScanning else { return }
        isScanning = true
        // Guarantee the flag clears even if this scan is cancelled or an awaited
        // step throws, so the Rescan button never gets stuck disabled.
        defer { isScanning = false }
        lastScanError = nil
        masAvailable = AppUpdateService.locateMas() != nil

        let bundles = AppLocationSettings.installedAppBundles()
        // App Store "outdated" set (bundle id → available version) from `mas`,
        // computed once up front. Empty when mas is absent.
        let masOutdated = await AppUpdateService.fetchMASOutdated()
        // Homebrew's full cask catalog (read once, off the main actor) is the
        // catch-all source: it lets us detect updates for apps that ship no
        // Sparkle feed, no GitHub link, and no App Store receipt (e.g. VS Code)
        // by cross-referencing the installed bundle against the cask that
        // provides it. Empty when brew has never been run.
        // Build the cask lookup from ForgedBrew's already-loaded in-memory
        // catalog rather than re-reading Homebrew's on-disk cache (whose
        // layout changes between brew versions). Falls back to the file
        // reader only if no catalog was passed in.
        let caskCatalog = casks.isEmpty
            ? await Task.detached { CaskCatalog.load() }.value
            : await Task.detached { CaskCatalog.from(casks: casks) }.value

        // Probe each non-managed bundle off the main actor, in parallel, then
        // collect. Each probe returns an AppUpdate? (nil = up to date / not
        // detectable).
        var found: [AppUpdate] = []
        await withTaskGroup(of: AppUpdate?.self) { group in
            for bundle in bundles {
                if managedAppPaths.contains(bundle.path) { continue }
                let path = bundle.path
                let name = bundle.name.hasSuffix(".app") ? String(bundle.name.dropLast(4)) : bundle.name
                group.addTask {
                    await AppUpdateService.probe(appPath: path, appName: name, masOutdated: masOutdated, caskCatalog: caskCatalog)
                }
            }
            for await result in group {
                if let result { found.append(result) }
            }
        }

        self.updates = found
        // Build the full installed-app inventory (both categories) so the
        // screen can show every app, not only the ones with updates. We map
        // the detected updates by bundle id and attach them as we go.
        let updatesByBundle = Dictionary(found.map { ($0.bundleID, $0) }, uniquingKeysWith: { a, _ in a })
        // Measure each non-managed bundle's on-disk size in parallel (du -sk),
        // off the main actor, so the full app list can show sizes like the
        // Homebrew screen does. Keyed by bundle path.
        let sizePaths = bundles
            .map { $0.path }
            .filter { !managedAppPaths.contains($0) }
        var sizeByPath: [String: Int64] = [:]
        await withTaskGroup(of: (String, Int64?).self) { group in
            for path in sizePaths {
                group.addTask {
                    (path, await AppUpdateService.bundleSizeBytes(atPath: path))
                }
            }
            for await (path, bytes) in group {
                if let bytes { sizeByPath[path] = bytes }
            }
        }

        // Install date per bundle, derived from the .app bundle's filesystem
        // date (creation date, falling back to modification date). Non-Homebrew
        // apps carry no brew install timestamp, so this is our best "installed"
        // proxy and lets the Mac Store/Other Apps rows show the same date pill
        // as the Homebrew screens. Cheap (one stat per path), but done up front
        // here alongside sizes so the row views stay pure.
        var dateByPath: [String: Date] = [:]
        for path in sizePaths {
            if let date = AppUpdateService.bundleInstallDate(atPath: path) {
                dateByPath[path] = date
            }
        }

        var inventory: [InstalledApp] = []
        for bundle in bundles {
            if managedAppPaths.contains(bundle.path) { continue }
            guard let info = AppUpdateService.freshInfoDictionary(appPath: bundle.path) else { continue }
            let bundleID = (info["CFBundleIdentifier"] as? String) ?? bundle.path
            let name = bundle.name.hasSuffix(".app") ? String(bundle.name.dropLast(4)) : bundle.name
            let installed = (info["CFBundleShortVersionString"] as? String)
                ?? (info["CFBundleVersion"] as? String) ?? ""
            // A _MASReceipt marks a Mac App Store install → Mac Store category.
            let receipt = (bundle.path as NSString).appendingPathComponent("Contents/_MASReceipt/receipt")
            let category: AppCategory = FileManager.default.fileExists(atPath: receipt) ? .macStore : .other
            // Resolve the matching Homebrew cask (if any) so the row can offer
            // Adopt and a Website link. Uses the SAME catalog match the update
            // probe uses, so "adoptable" is consistent across screens. Cheap:
            // two dictionary lookups against the already-loaded catalog.
            var suggestedToken: String? = nil
            var websiteURL: URL? = nil
            if !caskCatalog.isEmpty {
                let appFileName = (bundle.path as NSString).lastPathComponent  // "Foo.app"
                let displayName = info["CFBundleDisplayName"] as? String
                if let entry = caskCatalog.entry(appFileName: appFileName, displayName: displayName) {
                    suggestedToken = entry.token
                    websiteURL = entry.homepage.flatMap { URL(string: $0) }
                }
            }
            inventory.append(InstalledApp(
                bundleID: bundleID, appName: name, appPath: bundle.path,
                category: category, installedVersion: installed,
                update: updatesByBundle[bundleID],
                sizeBytes: sizeByPath[bundle.path],
                installedDate: dateByPath[bundle.path],
                suggestedToken: suggestedToken,
                websiteURL: websiteURL
            ))
        }
        self.allApps = inventory
        // Auto-unpark sweep: any parked record whose hold has expired (duration
        // passed, or a newer version shipped) re-enters the list.
        sweepExpiredParks()
        // Mark that we've scanned at least once so navigation into the
        // Mac Store/Other Apps page no longer forces a re-scan on every click.
        hasScannedOnce = true
        // isScanning is cleared by the defer at the top of this method.
    }

    // MARK: - Park / Unpark (UserDefaults-backed)

    func isParked(_ bundleID: String) -> Bool { parked[bundleID] != nil }

    // Park an app update. `availableVersion` is recorded so .untilNextVersion can
    // detect a genuinely newer release later.
    func park(_ update: AppUpdate, parkType: ParkType, duration: ParkDuration? = nil) {
        clearUpdateError(bundleID: update.bundleID)
        let expiresAt: Date?
        if parkType == .duration, let duration {
            expiresAt = Date().addingTimeInterval(duration.seconds)
        } else {
            expiresAt = nil
        }
        parked[update.bundleID] = ParkedAppUpdate(
            bundleID: update.bundleID,
            appName: update.appName,
            parkType: parkType,
            parkedAt: Date(),
            parkedVersion: update.availableVersion ?? update.installedVersion,
            expiresAt: expiresAt
        )
        persistParked()
    }

    func unpark(_ bundleID: String) {
        parked[bundleID] = nil
        persistParked()
    }

    // Re-park an existing record under a new hold type (used by the Parked
    // affordance's "change how long" control). Keeps appName / parkedVersion.
    func changePark(bundleID: String, parkType: ParkType, duration: ParkDuration? = nil) {
        guard let existing = parked[bundleID] else { return }
        let expiresAt: Date?
        if parkType == .duration, let duration {
            expiresAt = Date().addingTimeInterval(duration.seconds)
        } else {
            expiresAt = nil
        }
        parked[bundleID] = ParkedAppUpdate(
            bundleID: existing.bundleID,
            appName: existing.appName,
            parkType: parkType,
            parkedAt: existing.parkedAt,
            parkedVersion: existing.parkedVersion,
            expiresAt: expiresAt
        )
        persistParked()
    }

    // MARK: - Update action
    //
    // Opens the update for an app. Non-Homebrew apps can't be silently upgraded,
    // so we send the user to the right place:
    //   • App Store apps → the App Store product / updates page.
    //   • Sparkle/GitHub → the download / release URL.
    // Best-effort: if we have no URL we fall back to revealing the app so the
    // user can trigger its own "Check for Updates".
    func openUpdate(for update: AppUpdate) {
        if update.source == .appStore {
            // Open the App Store "Updates" page; the store reconciles which apps
            // are outdated. (A per-app product URL would need the numeric store
            // id, which we don't reliably have without mas.)
            if let url = update.updateURL {
                NSWorkspace.shared.open(url)
            } else if let updatesURL = URL(string: "macappstore://showUpdatesPage") {
                NSWorkspace.shared.open(updatesURL)
            }
            return
        }
        if let url = update.updateURL {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: update.appPath)])
        }
    }

    // Launches the installed app itself so the user can update from within it
    // (e.g. the app's own "Check for Updates" or built-in updater). Many
    // non-Homebrew apps update best when opened directly rather than via a
    // download page, so the row offers this as an alternative to openUpdate.
    func openApp(for update: AppUpdate) {
        let url = URL(fileURLWithPath: update.appPath)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    // Path-based variant for the Installed list, which carries an InstalledApp
    // (not an AppUpdate). Launches the app so the user can use its own updater.
    func openApp(atPath appPath: String) {
        let url = URL(fileURLWithPath: appPath)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    // Opens the app's homepage / download page so the user can grab a new
    // version manually. Used by the Installed list's Website button.
    func openWebsite(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // Uninstalls a non-Homebrew app by moving its .app bundle to the Trash
    // (recoverable, the standard macOS behavior). Unlike the Homebrew
    // Installed screen — which runs `brew uninstall --zap` to also strip
    // leftover support files — App Store and direct-download apps have no
    // package manager that tracks their files, so we can only trash the
    // bundle; any ~/Library support files are left behind. Returns the error
    // message on failure (nil on success) so the row can surface it. On
    // success we also drop the app from the in-memory lists and any parked
    // record so the row disappears immediately, before the caller rescans.
    // `sudoPassword` is the session admin password the view captures up-front
    // (exactly like a Homebrew install/uninstall). We first try to move the
    // bundle to the Trash without privileges; if that's denied because the app
    // lives in a protected/root-owned location, we retry with `sudo rm -rf`
    // using that password so the uninstall succeeds instead of erroring. An
    // empty/nil password skips the privileged retry (the user cancelled the
    // prompt), so we simply surface the original error.
    @discardableResult
    func uninstall(appPath: String, bundleID: String, sudoPassword: String?) async -> String? {
        let url = URL(fileURLWithPath: appPath)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            // Unprivileged trash failed — try a privileged delete if we have a
            // password. (rm -rf is permanent rather than recoverable, but it's
            // the only way to remove a root-owned bundle, and the user has
            // already confirmed the uninstall and entered their password.)
            let password = (sudoPassword ?? "").isEmpty ? nil : sudoPassword
            guard let password else {
                return error.localizedDescription
            }
            if let sudoError = await AppUpdateService.sudoRemove(path: appPath, password: password) {
                return sudoError
            }
        }
        // Remove only the row for THIS bundle path. Two installed copies can
        // legitimately share a bundle id (e.g. the same app in /Applications and
        // ~/Applications), so keying the removal on bundleID would drop BOTH rows
        // when the user uninstalled just one. appPath is unique per copy.
        updates.removeAll { $0.appPath == appPath }
        allApps.removeAll { $0.appPath == appPath }
        // Only forget the park state once NO copy of this bundle id remains —
        // otherwise uninstalling one duplicate would un-park the surviving copy.
        if parked[bundleID] != nil,
           !allApps.contains(where: { $0.bundleID == bundleID }) {
            parked[bundleID] = nil
            persistParked()
        }
        return nil
    }

    // Privileged delete of a path via `sudo -S rm -rf`, feeding the password on
    // stdin. Runs off the main actor. Returns nil on success or an error string.
    nonisolated static func sudoRemove(path: String, password: String) async -> String? {
        // Once-guard so the terminationHandler, the run-failure path, and the
        // timeout watchdog can race to resume but only the first wins.
        let guardOnce = ResumeGuard()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-S", "-k", "/bin/rm", "-rf", path]

            let stdinPipe = Pipe()
            let errPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardError = errPipe
            process.standardOutput = Pipe()

            // Resume via terminationHandler so the continuation body never blocks
            // a cooperative thread.
            process.terminationHandler = { p in
                guard guardOnce.claim() else { return }
                if p.terminationStatus == 0 {
                    continuation.resume(returning: nil)
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errText = String(data: errData, encoding: .utf8) ?? ""
                    // Strip sudo's password prompt echo so the user sees the real error.
                    let cleaned = errText
                        .replacingOccurrences(of: "Password:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: cleaned.isEmpty
                        ? "The app couldn't be removed (permission denied)."
                        : cleaned)
                }
            }
            do {
                try process.run()
            } catch {
                if guardOnce.claim() {
                    continuation.resume(returning: error.localizedDescription)
                }
                return
            }
            // Watchdog armed BEFORE the (blocking) stdin write, so even a sudo that
            // never drains stdin — or a `rm -rf` wedged on a stale network mount —
            // can't leave this continuation suspended forever. Escalate
            // SIGTERM → SIGKILL, then force-resume as a last resort.
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(30 * 1_000_000_000))
                guard process.isRunning else { return }
                process.terminate()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                if process.isRunning, guardOnce.claim() {
                    continuation.resume(returning: "The removal timed out and was stopped.")
                }
            }
            // Feed the password (sudo -S reads it from stdin, newline-terminated).
            let handle = stdinPipe.fileHandleForWriting
            handle.write(Data((password + "\n").utf8))
            try? handle.close()
        }
    }

    // MARK: - Persistence

    private func loadParked() {
        guard let data = UserDefaults.standard.data(forKey: parkedDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: ParkedAppUpdate].self, from: data) else {
            parked = [:]
            return
        }
        parked = decoded
    }

    private func persistParked() {
        if let data = try? JSONEncoder().encode(parked) {
            UserDefaults.standard.set(data, forKey: parkedDefaultsKey)
        }
    }

    // Drops parked records whose hold has expired so they reappear in the list.
    private func sweepExpiredParks() {
        // Latest available version per bundle id from the current scan, so
        // .untilNextVersion parks can detect a newer release.
        var latestByID: [String: String] = [:]
        for u in updates { if let v = u.availableVersion { latestByID[u.bundleID] = v } }
        var changed = false
        for (id, record) in parked {
            if record.shouldAutoUnpark(latestAvailable: latestByID[id]) {
                parked[id] = nil
                changed = true
            }
        }
        if changed { persistParked() }
    }

    // MARK: - Per-app probe (off the main actor)
    //
    // Decides, for one app bundle, whether an update is available and from which
    // source. Source precedence: App Store (receipt is authoritative) → Sparkle
    // (explicit appcast) → GitHub (feed/homepage points at a repo). Returns nil
    // when the app is up to date or no source applies.
    nonisolated static func probe(appPath: String, appName: String, masOutdated: [String: MASOutdatedInfo], caskCatalog: CaskCatalog) async -> AppUpdate? {
        // Read Info.plist straight from disk rather than via Bundle(path:).
        // Bundle caches the Info dictionary per path for the life of the
        // process, so after the user updates an app in place the cached copy
        // still reports the OLD version — which made just-updated apps linger
        // in the list. A fresh read reflects what's actually on disk now.
        guard let info = freshInfoDictionary(appPath: appPath) else { return nil }
        let bundleID = (info["CFBundleIdentifier"] as? String) ?? appPath
        let installed = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? ""
        // The raw build string (CFBundleVersion) can differ from the
        // marketing version (CFBundleShortVersionString). Some casks key
        // their version off the build number (e.g. Microsoft Office:
        // short "16.109.3" but cask version "16.109.26053122" == the build),
        // so a short-only compare wrongly flagged them. Capture both and,
        // for the cask catch-all, require the cask to beat BOTH.
        let installedBuild = (info["CFBundleVersion"] as? String) ?? ""

        // 1. Mac App Store: a _MASReceipt is the canonical signal.
        let receiptPath = (appPath as NSString).appendingPathComponent("Contents/_MASReceipt/receipt")
        if FileManager.default.fileExists(atPath: receiptPath) {
            // If mas reported it outdated we have a concrete target version;
            // otherwise we still surface it (Update routes to the store) but only
            // when mas couldn't tell us — to avoid noise we ONLY list MAS apps
            // that mas flagged, OR (when mas is absent) we skip silent-up-to-date
            // ones we can't assess. We list it when mas flagged it.
            if let info = masOutdated[bundleID] {
                // Prefer a per-app deep link to THIS app's App Store page when we
                // know its numeric store id; fall back to the generic updates
                // page otherwise. The deep link is what the "Open App Store"
                // button uses when a silent `mas upgrade` cannot complete.
                let storeURL: URL? = info.storeID.flatMap {
                    URL(string: "macappstore://apps.apple.com/app/id\($0)")
                } ?? URL(string: "macappstore://showUpdatesPage")
                return AppUpdate(
                    bundleID: bundleID, appName: appName, appPath: appPath,
                    source: .appStore, installedVersion: installed,
                    availableVersion: info.version,
                    updateURL: storeURL,
                    releaseNotesURL: nil,
                    storeID: info.storeID
                )
            }
            // mas absent (no outdated map at all) → we can't assess; don't spam
            // every MAS app as "update available". Return nil so up-to-date store
            // apps stay quiet. (The view shows a note that mas enables this.)
            return nil
        }

        // 2. Sparkle: SUFeedURL in Info.plist → fetch + parse appcast.
        if let feed = info["SUFeedURL"] as? String,
           let feedURL = URL(string: feed) {
            if let newest = await fetchSparkleNewest(feedURL: feedURL) {
                if AppVersion.isNewer(newest.version, than: installed) {
                    return AppUpdate(
                        bundleID: bundleID, appName: appName, appPath: appPath,
                        source: .sparkle, installedVersion: installed,
                        availableVersion: newest.version,
                        updateURL: newest.downloadURL ?? feedURL,
                        releaseNotesURL: newest.releaseNotesURL
                    )
                }
                return nil  // Sparkle says up to date.
            }
            // Couldn't read the appcast — try GitHub as a fallback below.
        }

        // 3. GitHub: a feed or homepage pointing at github.com → latest release.
        if let repo = githubRepo(info: info) {
            if let release = await fetchGitHubLatest(repo: repo) {
                if AppVersion.isNewer(release.version, than: installed) {
                    return AppUpdate(
                        bundleID: bundleID, appName: appName, appPath: appPath,
                        source: .github, installedVersion: installed,
                        availableVersion: release.version,
                        updateURL: release.downloadURL,
                        releaseNotesURL: release.releaseNotesURL
                    )
                }
            }
        }

        // 4. Homebrew cask catalog (catch-all): the app isn't App Store /
        //    Sparkle / GitHub detectable, but Homebrew may still ship a cask
        //    for it and know the latest version. Match the installed bundle
        //    to a cask by its .app file name (then display name) and compare.
        //    This is what surfaces apps like Visual Studio Code that update
        //    through a proprietary updater. We only surface it when the cask
        //    version is strictly newer, so a current app stays quiet.
        if !caskCatalog.isEmpty {
            let appFileName = (appPath as NSString).lastPathComponent  // "Foo.app"
            let displayName = info["CFBundleDisplayName"] as? String
            // Strip Homebrew's revision suffix: cask versions like
            // "149.0.4022.52,1f3a9c..." carry a comma-separated build hash
            // that isn't part of the comparable version.
            if let cask = caskCatalog.entry(appFileName: appFileName, displayName: displayName) {
                let caskVersion = cask.version.split(separator: ",", maxSplits: 1).first.map(String.init) ?? cask.version
                // Only a real update when the cask beats BOTH the marketing
                // version and the build number — this kills false positives
                // for apps whose cask version equals their CFBundleVersion.
                let beatsShort = AppVersion.isNewer(caskVersion, than: installed)
                let beatsBuild = installedBuild.isEmpty ? true : AppVersion.isNewer(caskVersion, than: installedBuild)
                guard beatsShort && beatsBuild else { return nil }
                // "Update" for a non-Homebrew app opens its homepage so the
                // user can grab the new version manually (these apps can't be
                // upgraded in place by us). Falls back to revealing the app.
                let homepageURL = cask.homepage.flatMap { URL(string: $0) }
                return AppUpdate(
                    bundleID: bundleID, appName: appName, appPath: appPath,
                    source: .homebrewCask, installedVersion: installed,
                    availableVersion: caskVersion,
                    updateURL: homepageURL,
                    releaseNotesURL: nil,
                    suggestedToken: cask.token
                )
            }
        }

        return nil
    }

    // MARK: - Sparkle appcast

    nonisolated struct SparkleItem: Sendable {
        let version: String
        let downloadURL: URL?
        let releaseNotesURL: URL?
    }

    // Fetches an appcast and returns its NEWEST item (highest version). Returns
    // nil on any network/parse failure so the caller can fall back.
    nonisolated static func fetchSparkleNewest(feedURL: URL) async -> SparkleItem? {
        guard let data = await fetch(url: feedURL) else { return nil }
        let parser = AppcastParser()
        let items = parser.parse(data: data)
        guard !items.isEmpty else { return nil }
        // Pick the highest shortVersionString; ties broken by appearance order
        // (appcasts are conventionally newest-first).
        return items.max { a, b in AppVersion.isNewer(b.version, than: a.version) }
    }

    // MARK: - GitHub releases

    nonisolated struct GitHubRelease: Sendable {
        let version: String
        let downloadURL: URL?
        let releaseNotesURL: URL?
    }

    // Reads an app bundle's Info.plist directly from disk (no Bundle cache).
    // Returns nil when the file is missing or unreadable. Used so an in-place
    // app update is reflected immediately on the next scan.
    nonisolated static func freshInfoDictionary(appPath: String) -> [String: Any]? {
        let plistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plistPath) else { return nil }
        let parsed = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return parsed as? [String: Any]
    }

    // Extracts "owner/repo" from a Sparkle feed or homepage that lives on GitHub.
    nonisolated static func githubRepo(info: [String: Any]) -> String? {
        let candidates: [String?] = [
            info["SUFeedURL"] as? String,
            info["CFBundleHomePageURL"] as? String
        ]
        for case let raw? in candidates {
            guard let comps = URLComponents(string: raw),
                  let host = comps.host, host.contains("github.com") else { continue }
            // Path like "/owner/repo/..." → "owner/repo".
            let parts = comps.path.split(separator: "/").map(String.init)
            if parts.count >= 2 { return "\(parts[0])/\(parts[1])" }
        }
        return nil
    }

    nonisolated static func fetchGitHubLatest(repo: String) async -> GitHubRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest"),
              let data = await fetch(url: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let tag = (root["tag_name"] as? String) ?? (root["name"] as? String)
        guard let tag else { return nil }
        // Strip a leading "v" so "v1.4.3" compares cleanly.
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        // Prefer a .dmg/.zip asset download URL; fall back to the release page.
        var download: URL?
        if let assets = root["assets"] as? [[String: Any]] {
            for asset in assets {
                if let name = asset["name"] as? String,
                   name.hasSuffix(".dmg") || name.hasSuffix(".zip") || name.hasSuffix(".pkg"),
                   let urlStr = asset["browser_download_url"] as? String,
                   let assetURL = URL(string: urlStr) {
                    download = assetURL
                    break
                }
            }
        }
        let pageURL = (root["html_url"] as? String).flatMap(URL.init(string:))
        return GitHubRelease(version: version, downloadURL: download ?? pageURL, releaseNotesURL: pageURL)
    }

    // MARK: - mas (Mac App Store CLI)

    // What `mas outdated` tells us about one outdated Mac App Store app: the
    // newest available version, plus the numeric store id (adamID) when we can
    // get it. The store id drives both the silent `mas upgrade <id>` attempt and
    // the per-app "Open App Store" deep link.
    nonisolated struct MASOutdatedInfo: Sendable {
        let version: String
        let storeID: String?
    }

    // Result of attempting a silent Mac App Store upgrade for one app.
    enum MASUpgradeResult: Sendable {
        case succeeded
        case failed(String)   // human-readable reason
        case unavailable      // mas not installed, or no store id to target
    }

    // Attempts a silent `mas upgrade <storeID>` for an App Store app. Returns
    // .succeeded when mas exits 0, .failed(reason) when it runs but errors, and
    // .unavailable when we can't even try (mas missing or no store id). The
    // caller uses .failed/.unavailable to show the "update in the App Store"
    // message with an Open App Store button rather than a generic failure.
    nonisolated static func upgradeViaMAS(storeID: String?) async -> MASUpgradeResult {
        guard let mas = locateMas() else { return .unavailable }
        guard let storeID, !storeID.isEmpty else { return .unavailable }
        let (output, status) = await runProcessWithStatus(path: mas, args: ["upgrade", storeID])
        if status == 0 { return .succeeded }
        let trimmed = (output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(trimmed.isEmpty ? "mas could not upgrade this app." : trimmed)
    }

    // Locates the mas CLI, or nil if not installed.
    nonisolated static func locateMas() -> String? {
        for path in ["/opt/homebrew/bin/mas", "/usr/local/bin/mas"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // Runs `mas outdated` and returns a map of **bundle id → available version**.
    //
    // IMPORTANT (bug fix): probe() looks this map up by CFBundleIdentifier, but
    // the previous implementation keyed it by the lowercased app NAME. The two
    // never matched, so NO Mac App Store app was ever flagged as outdated even
    // when mas reported it (e.g. Prime Video showed an update in other tools but
    // never here). We now key strictly by bundle id.
    //
    // We ask mas itself to emit bundle ids via `--bundle` (mas ≥ 6 supports it),
    // and prefer `--json` for robust parsing, falling back to the plain-text
    // form. With `--bundle`, mas processes/outputs bundle ids directly, so we no
    // longer have to guess a store-id → bundle-id mapping.
    //
    // NOTE: returns an EMPTY map when mas is absent. The probe treats an empty
    // map as "can't assess App Store apps" and stays quiet rather than flagging
    // every store app.
    nonisolated static func fetchMASOutdated() async -> [String: MASOutdatedInfo] {
        guard let mas = locateMas() else { return [:] }

        // 1. Preferred: JSON keyed by bundle id. Each line is one JSON object
        //    carrying bundle id, available version, AND the numeric store id.
        if let jsonOut = await runProcess(path: mas, args: ["outdated", "--bundle", "--json"]),
           !jsonOut.isEmpty {
            let parsed = parseMASOutdatedJSON(jsonOut)
            if !parsed.isEmpty { return parsed }
        }

        // 2. Fallback: plain text with --bundle, where the FIRST whitespace
        //    token on each line is the bundle id (not a numeric store id):
        //    "com.example.App  App Name (1.2.3 -> 1.2.4)"
        guard let output = await runProcess(path: mas, args: ["outdated", "--bundle"]) else { return [:] }

        // The --bundle form omits the numeric store id we want for silent
        // `mas upgrade <id>` and per-app deep links. Recover it by also running
        // the PLAIN `mas outdated` (which leads each line with the store id and
        // the app NAME) and joining the two on app name. Best-effort: if the
        // plain run fails, store ids simply stay nil and we fall back to the
        // generic App Store updates page.
        let storeIDByName = await fetchMASStoreIDByName(mas: mas)

        var result: [String: MASOutdatedInfo] = [:]
        for line in output.split(separator: "\n") {
            let s = String(line)
            guard let arrowRange = s.range(of: "->") else { continue }
            let after = s[arrowRange.upperBound...]
            let newVersion = after.trimmingCharacters(in: CharacterSet(charactersIn: " )\t"))
            // Bundle id is the first whitespace-delimited token on the line.
            let tokens = s.split(separator: " ", maxSplits: 1)
            guard let first = tokens.first else { continue }
            let bundleID = String(first).trimmingCharacters(in: .whitespaces)
            guard !bundleID.isEmpty, !newVersion.isEmpty else { continue }
            // The app name is the text between the bundle id and the "(old ->"
            // version parenthesis; trim it to match against the plain-run map.
            var storeID: String? = nil
            if tokens.count > 1 {
                let rest = String(tokens[1])
                if let paren = rest.range(of: "(") {
                    let name = rest[..<paren.lowerBound].trimmingCharacters(in: .whitespaces)
                    storeID = storeIDByName[name]
                }
            }
            result[bundleID] = MASOutdatedInfo(version: newVersion, storeID: storeID)
        }
        return result
    }

    // Runs the PLAIN `mas outdated` (no --bundle) and returns app NAME → numeric
    // store id. The plain output format leads with the store id:
    //   "497799835 Xcode (15.0 -> 15.1)"
    // We use this only to backfill store ids for the --bundle fallback path.
    nonisolated static func fetchMASStoreIDByName(mas: String) async -> [String: String] {
        guard let output = await runProcess(path: mas, args: ["outdated"]) else { return [:] }
        var map: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            let tokens = s.split(separator: " ", maxSplits: 1)
            guard tokens.count == 2 else { continue }
            let storeID = String(tokens[0])
            // Store id is all digits; skip lines that don't start with one.
            guard storeID.allSatisfy(\.isNumber), !storeID.isEmpty else { continue }
            let rest = String(tokens[1])
            let name: String
            if let paren = rest.range(of: "(") {
                name = rest[..<paren.lowerBound].trimmingCharacters(in: .whitespaces)
            } else {
                name = rest.trimmingCharacters(in: .whitespaces)
            }
            if !name.isEmpty { map[name] = storeID }
        }
        return map
    }

    // Parses `mas outdated --bundle --json` output (one JSON object per line, or
    // a single JSON array) into a bundle id → MASOutdatedInfo map. Tolerant of
    // the field-name variations across mas versions: the bundle id may appear as
    // "bundleID"/"bundleId"/"bundle_id", the available version as
    // "availableVersion"/"latestVersion"/"version", and the numeric store id as
    // "id"/"adamID"/"trackId" (string or number).
    nonisolated static func parseMASOutdatedJSON(_ output: String) -> [String: MASOutdatedInfo] {
        var result: [String: MASOutdatedInfo] = [:]

        func ingest(_ obj: [String: Any]) {
            let bundleKeys = ["bundleID", "bundleId", "bundle_id", "bundleIdentifier"]
            let versionKeys = ["availableVersion", "latestVersion", "newVersion", "version"]
            let idKeys = ["id", "adamID", "adamId", "trackId", "trackID", "storeId", "storeID"]
            let bundleID = bundleKeys.compactMap { obj[$0] as? String }.first
            let version = versionKeys.compactMap { obj[$0] as? String }.first
            // Store id may arrive as a String or a JSON number — accept both.
            let storeID = idKeys.compactMap { key -> String? in
                if let s = obj[key] as? String, !s.isEmpty { return s }
                if let n = obj[key] as? NSNumber { return n.stringValue }
                return nil
            }.first
            if let bundleID, let version, !bundleID.isEmpty, !version.isEmpty {
                result[bundleID] = MASOutdatedInfo(version: version, storeID: storeID)
            }
        }

        // Try a top-level JSON array first.
        if let data = output.data(using: .utf8),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            arr.forEach(ingest)
            if !result.isEmpty { return result }
        }
        // Otherwise treat as JSON-lines (one object per line).
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            ingest(obj)
        }
        return result
    }

    // MARK: - Low-level helpers

    // Rejects URLs that aren't a plain remote web fetch: a non-http(s) scheme, or
    // a host that points back at this machine or a private/link-local network.
    // The appcast (SUFeedURL) and homepage URLs we fetch come straight from an
    // arbitrary installed app's Info.plist, so without this a malicious app could
    // aim them at cloud-metadata (169.254.169.254), localhost services, or
    // internal hosts (SSRF). Legitimate update feeds always live on public web
    // hosts, so this never rejects a real one.
    nonisolated static func isSafeRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        guard var host = url.host?.lowercased(), !host.isEmpty else { return false }
        // Normalize before matching: a single trailing dot (`localhost.`,
        // `127.0.0.1.`) still resolves to the same target, and `url.host` may or
        // may not include the IPv6 brackets — strip both so they can't sneak past.
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty else { return false }
        // Loopback / mDNS / cloud-internal hostnames.
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return false
        }
        // Reject any IP LITERAL that points back at this machine or a private /
        // link-local network — in EVERY textual encoding the OS resolver accepts.
        // String-prefix checks missed decimal (http://2130706433/ == 127.0.0.1),
        // hex (0x7f000001), octal (0177.0.0.1), dotted-shorthand (127.1), and
        // expanded / IPv4-mapped IPv6 (0:0:0:0:0:0:0:1, ::ffff:127.0.0.1). We let
        // the C resolver parse it instead: inet_aton covers all IPv4 forms,
        // inet_pton covers canonical IPv6.
        if isBlockedIPLiteral(host) { return false }
        return true
    }

    // True when `host` is an IP literal (any encoding) inside a loopback, private,
    // link-local, unique-local, or unspecified range. Returns false for ordinary
    // hostnames (which simply don't parse as an IP). Used only by isSafeRemoteURL.
    private nonisolated static func isBlockedIPLiteral(_ host: String) -> Bool {
        // IPv4 in any encoding inet_aton accepts (dotted, decimal, hex, octal,
        // shorthand). s_addr is network byte order → read it back as host order.
        var v4 = in_addr()
        if host.withCString({ inet_aton($0, &v4) }) != 0 {
            return isBlockedIPv4(UInt32(bigEndian: v4.s_addr))
        }
        // Canonical IPv6.
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            let b = withUnsafeBytes(of: &v6) { Array($0) }   // 16 bytes, network order
            guard b.count == 16 else { return false }
            if b.allSatisfy({ $0 == 0 }) { return true }                       // :: unspecified
            if b[0..<15].allSatisfy({ $0 == 0 }), b[15] == 1 { return true }   // ::1 loopback
            if b[0] == 0xfe, (b[1] & 0xc0) == 0x80 { return true }             // fe80::/10 link-local
            if (b[0] & 0xfe) == 0xfc { return true }                           // fc00::/7 unique-local
            // IPv4-mapped (::ffff:a.b.c.d) / IPv4-compatible (::a.b.c.d): the low
            // 32 bits carry an embedded IPv4 — check it against the same ranges.
            if b[0..<10].allSatisfy({ $0 == 0 }),
               (b[10] == 0xff && b[11] == 0xff) || (b[10] == 0 && b[11] == 0) {
                let embedded = (UInt32(b[12]) << 24) | (UInt32(b[13]) << 16)
                            | (UInt32(b[14]) << 8) | UInt32(b[15])
                if isBlockedIPv4(embedded) { return true }
            }
            return false
        }
        return false   // not an IP literal — an ordinary hostname, allowed
    }

    // True when the host-order IPv4 address is in a loopback/private/link-local
    // range (incl. 169.254.169.254 cloud-metadata, covered by 169.254/16).
    private nonisolated static func isBlockedIPv4(_ h: UInt32) -> Bool {
        let b0 = UInt8((h >> 24) & 0xff)
        let b1 = UInt8((h >> 16) & 0xff)
        if b0 == 0 || b0 == 127 || b0 == 10 { return true }       // this-host / loopback / private
        if b0 == 169, b1 == 254 { return true }                    // link-local + cloud metadata
        if b0 == 192, b1 == 168 { return true }                    // private
        if b0 == 172, (16...31).contains(b1) { return true }       // private
        return false
    }

    // GET a URL with a browser-like UA and a short timeout. Returns nil on any
    // error or non-2xx. Network only; safe off the main actor.
    nonisolated static func fetch(url: URL) async -> Data? {
        // SSRF guard: never fetch a non-web scheme or a local/private host (the
        // URL may have come from an untrusted Info.plist — see isSafeRemoteURL).
        guard isSafeRemoteURL(url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        // Always pull a fresh feed — a cached appcast would let a just-released
        // (or just-installed) version read incorrectly on a manual rescan.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/xml, application/json, */*", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    // On-disk size of an .app bundle in bytes, via `du -sk` (kilobytes ×
    // 1024). nil when the path can't be measured. Used to show per-app size
    // on the Mac Store / Other Apps screen.
    nonisolated static func bundleSizeBytes(atPath path: String) async -> Int64? {
        guard let out = await runProcess(path: "/usr/bin/du", args: ["-sk", path]) else { return nil }
        let token = out.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first.map(String.init)
        guard let kb = token.flatMap({ Int64($0) }) else { return nil }
        return kb * 1024
    }

    // Best-effort "installed" date for a non-Homebrew app: the .app bundle's
    // filesystem creation date, falling back to its modification date. macOS
    // sets the bundle's creation date when the app is first written to /
    // Applications, so it's a reasonable proxy for when the user installed it.
    // nil when neither attribute can be read.
    //
    // Guard against a BOGUS creation date: a bundle rewritten in place (e.g. by a
    // Sparkle self-update) can report a creationDate at the classic Mac "zero"
    // epoch (~Jan 1, 1904), which would render as a nonsensical "Installed
    // Dec 31, 1903". Reject any date before macOS X existed and fall back to the
    // modification date — for a freshly written/updated bundle that's a good
    // install-date proxy (and is what a just-updated app should show).
    nonisolated static func bundleInstallDate(atPath path: String) -> Date? {
        // Jan 1, 2001 (NSDate reference epoch); no real Mac app predates OS X.
        let earliestPlausible = Date(timeIntervalSinceReferenceDate: 0)
        func plausible(_ date: Any?) -> Date? {
            guard let date = date as? Date, date >= earliestPlausible else { return nil }
            return date
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return plausible(attrs?[.creationDate]) ?? plausible(attrs?[.modificationDate])
    }

    // Runs a command and returns combined stdout, or nil on failure. Used for
    // the small read-only CLIs (`mas …`); discards stderr and the exit status.
    nonisolated static func runProcess(path: String, args: [String]) async -> String? {
        await launch(path: path, args: args, mergeStderr: false).output
    }

    // Like runProcess, but also returns the process exit status and merges
    // stderr into the captured output. Used by upgradeViaMAS so we can tell a
    // successful `mas upgrade` (exit 0) from a failure and surface mas's own
    // error text to the user.
    nonisolated static func runProcessWithStatus(path: String, args: [String]) async -> (output: String?, status: Int32) {
        await launch(path: path, args: args, mergeStderr: true)
    }

    // One-shot resume guard: lets the terminationHandler and the timeout watchdog
    // race to resume the continuation, with only the first winning (a second
    // resume of a CheckedContinuation would trap).
    //
    // `nonisolated` (matching its twin `OneShot` in BrewCLIService): it's used
    // from the `nonisolated` process runners (sudoRemove, etc.), and without this
    // the project's default MainActor isolation makes init()/claim() main-actor-
    // bound — a Swift 6 error, and a warning today. It's a plain lock-guarded flag,
    // safe to touch from any thread.
    nonisolated private final class ResumeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    // Shared process launcher for the small read-only CLIs (`du -sk`, `mas …`).
    // A watchdog terminates — then SIGKILLs — any process that overruns
    // `timeout`, so a wedged `du` (e.g. a stale/dead network mount) or a hung
    // `mas` (stuck on the network) can never leave the awaiting continuation
    // suspended forever. The terminationHandler resumes on normal/killed exit;
    // if the process is so wedged that even SIGKILL doesn't reap it promptly
    // (uninterruptible I/O), the watchdog force-resumes so the caller is never
    // stranded. A once-guard ensures exactly one resume.
    private nonisolated static func launch(
        path: String,
        args: [String],
        mergeStderr: Bool,
        timeout: TimeInterval = 30
    ) async -> (output: String?, status: Int32) {
        let guardOnce = ResumeGuard()
        return await withCheckedContinuation { (cont: CheckedContinuation<(String?, Int32), Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            // Merge stderr into the same pipe when asked (mas error text); else
            // discard it down a separate pipe.
            process.standardError = mergeStderr ? pipe : Pipe()
            // Resume via terminationHandler so the continuation body never blocks a
            // cooperative thread. readDataToEndOfFile() is safe here because the
            // process has closed its write end by the time the handler fires.
            process.terminationHandler = { p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if guardOnce.claim() {
                    cont.resume(returning: (String(data: data, encoding: .utf8), p.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                // Launch failure (binary missing / not executable). Return a nil
                // output, NOT the error description: callers like runProcess treat
                // a non-nil string as real command output and would otherwise parse
                // the localized error text ("… doesn't exist") as data. Status -1
                // signals the failure to runProcessWithStatus callers.
                if guardOnce.claim() {
                    cont.resume(returning: (nil, -1))
                }
                return
            }
            // Watchdog: escalate SIGTERM → SIGKILL on a process that overruns the
            // timeout, then force-resume if it still won't die.
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard process.isRunning else { return }   // exited in time
                process.terminate()                        // SIGTERM
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                // If even SIGKILL hasn't reaped it (rare, uninterruptible I/O),
                // make sure the awaiting caller isn't left hanging.
                if process.isRunning, guardOnce.claim() {
                    cont.resume(returning: (nil, -1))
                }
            }
        }
    }

}

// MARK: - Appcast XML parser
//
// A minimal, tolerant Sparkle appcast parser. Sparkle appcasts are RSS:
//   <rss><channel><item>
//     <title>1.4.3</title>
//     <sparkle:shortVersionString>1.4.3</sparkle:shortVersionString>
//     <sparkle:version>167</sparkle:version>
//     <sparkle:releaseNotesLink>…</sparkle:releaseNotesLink>
//     <enclosure url="…" sparkle:shortVersionString="1.4.3" sparkle:version="167"/>
//   </item>…</channel></rss>
//
// The display version can appear either as the <sparkle:shortVersionString>
// element, as an attribute on <enclosure>, or (older feeds) only in <title>.
// We collect all three and prefer the most specific. Foundation's XMLParser is
// event-driven and namespace-aware enough for our needs; we match on the local
// element name to stay robust against the "sparkle:" prefix.
nonisolated final class AppcastParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private var items: [AppUpdateService.SparkleItem] = []

    // Per-item accumulators.
    private var inItem = false
    private var currentElement = ""
    private var titleText = ""
    private var shortVersionText = ""
    private var releaseNotesText = ""
    private var enclosureURL: String?
    private var enclosureShortVersion: String?

    func parse(data: Data) -> [AppUpdateService.SparkleItem] {
        items.removeAll()
        let parser = XMLParser(data: data)
        parser.delegate = self
        // Be lenient: don't abort on namespace quirks.
        parser.shouldProcessNamespaces = false
        parser.parse()
        return items
    }

    // Strips a known namespace prefix so "sparkle:version" → "version".
    private func localName(_ name: String) -> String {
        if let colon = name.firstIndex(of: ":") {
            return String(name[name.index(after: colon)...])
        }
        return name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        let local = localName(elementName)
        currentElement = local
        if local == "item" {
            inItem = true
            titleText = ""
            shortVersionText = ""
            releaseNotesText = ""
            enclosureURL = nil
            enclosureShortVersion = nil
        } else if local == "enclosure", inItem {
            enclosureURL = attributeDict["url"]
            // Attribute may be namespaced ("sparkle:shortVersionString") or not.
            enclosureShortVersion = attributeDict["sparkle:shortVersionString"]
                ?? attributeDict["shortVersionString"]
                ?? attributeDict["sparkle:version"]
                ?? attributeDict["version"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        switch currentElement {
        case "title":                  titleText += string
        case "shortVersionString":     shortVersionText += string
        case "releaseNotesLink":       releaseNotesText += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let local = localName(elementName)
        if local == "item" {
            inItem = false
            // Resolve the display version, most specific first.
            let version = firstNonEmpty(
                shortVersionText.trimmingCharacters(in: .whitespacesAndNewlines),
                enclosureShortVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
                titleText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard let version, !version.isEmpty else { return }
            let download = enclosureURL.flatMap { URL(string: $0) }
            let notes = URL(string: releaseNotesText.trimmingCharacters(in: .whitespacesAndNewlines))
            items.append(AppUpdateService.SparkleItem(
                version: version, downloadURL: download, releaseNotesURL: notes
            ))
        }
        currentElement = ""
    }

    private func firstNonEmpty(_ candidates: String?...) -> String? {
        for case let c? in candidates where !c.isEmpty { return c }
        return nil
    }
}
