import SwiftUI
import AppKit
@preconcurrency import CoreSpotlight

enum SidebarItem: Hashable, Sendable {
    case home
    case trending
    case recentlyUpdated
    case topPastYear
    case browseAll
    case category(CaskCategory)
    case subcategory(CaskCategory, String)
    // Formulae (CLI packages) live under a single top-level "Formulae" sidebar
    // category. formulaeRoot selects all formulae; formulaSubcategory scopes to
    // one CLI-tool group (e.g. "Databases"). Kept separate from the cask
    // category cases so the two taxonomies never bleed into each other.
    case formulaeRoot
    case formulaSubcategory(String)
    case installed
    case maintenance
    // "Updates" lives as a child row under Maintenance in the sidebar. It opens
    // the split Updates screen (Updates Available on top, Up to Date below).
    case updates
    // "App Updates" lists non-Homebrew apps (App Store, Sparkle, GitHub) that
    // have a newer version available, so the user can Update or Park them
    // without adopting them into Homebrew. Lives under Library in the sidebar.
    case appUpdates
    // Mac Store/Other Apps Updates: same screen as appUpdates, but its own
    // sidebar row so the updates-only entry highlights independently from the
    // total-count row above it (mirrors Installed Homebrew / Homebrew Updates).
    case appUpdatesOnly
    // "Taps" lists the Homebrew source repositories the user has added (extra
    // catalogs beyond core/cask). Sits at the bottom of the Installed and
    // Updates section, under Mac Store/Other Apps Updates. Opens TapsView.
    case taps
    case favorites
    case brewfile
    case notes
    // "Parked" holds packages out of the Updates list / Update All (ForgedBrew's
    // Park feature). Lives under Library in the sidebar.
    case parked
    case settings
}

// NOTE: The real SidebarView now lives in Views/SidebarView.swift (Prompt 11).
// The placeholder that used to be here has been removed to avoid a redeclaration.

// MARK: - Detail Router
// Switches the detail pane on the selected SidebarItem. Built views (Home,
// Browse, Installed, Maintenance) route to their real screens; the discover
// and category items reuse BrowseView (the catalog), and the Phase 3 items
// (Favorites, Brewfile, Notes) show a "coming soon" placeholder for now.
struct DetailRouter: View {
    @Binding var selection: SidebarItem?
    // The sidebar item we last ran applySidebarFilter() for. Used to tell a
    // genuine selection change (real sidebar click) apart from a no-op
    // re-appear (e.g. Back from a detail page, which re-fires the onChange
    // with the SAME value). On a genuine change we force the browse list to
    // refresh even if the change-guarded setters all no-op, which fixes the
    // stale/partial Trending list bug without disturbing scroll restoration.
    @State private var lastAppliedSidebarItem: SidebarItem? = nil
    // A single BrowseViewModel is shared across all catalog-style destinations
    // so scroll position and loaded results persist as the user navigates.
    @Bindable var browseViewModel: BrowseViewModel
    // Bound to the toolbar search field. When non-empty (>= 2 chars) the
    // search results overlay the current section, mirroring the App Store.
    @Binding var searchText: String
    @Environment(AppDataService.self) private var appData

    // When non-nil, the detail page for this cask overlays the current section.
    // Tapping a card sets it; the detail page's Back button clears it.
    @State private var selectedCask: CaskMetadata? = nil

    // Same idea for formulae: tapping a formula card opens its detail page,
    // overlaying the current section; the detail page's Back button clears it.
    @State private var selectedFormula: FormulaMetadata? = nil

    // Persisted scroll anchor for HomeView. HomeView is rebuilt whenever we
    // swap to/from the detail page (the Group below), so its own @State can't
    // survive the round-trip. Holding the anchor here (DetailRouter persists
    // across that swap) lets Home restore its scroll position on Back.
    @State private var homeScrollAnchor: CaskMetadata.ID? = nil

    // Dedicated view model for search so live queries never clobber the
    // browse catalog's loaded/filtered state.
    @State private var searchViewModel = BrowseViewModel()

    // True when the user has typed enough to run a catalog search.
    private var isSearching: Bool {
        searchText.trimmingCharacters(in: .whitespaces).count >= 2
    }

    // The inventory sections (Installed, Homebrew Updates, Mac App Store & other
    // apps) own real lists of what is on THIS Mac, so their toolbar search must
    // filter that list in place rather than swapping in the global catalog
    // search overlay. For these sections the search text is handed down to the
    // section view as a page-local filter binding instead.
    private var isLocalSearchSection: Bool {
        switch selection {
        case .installed, .updates, .appUpdates, .appUpdatesOnly, .taps: return true
        default: return false
        }
    }

    // The category/subcategory the current sidebar selection represents, if any.
    // Used to scope search: searching while inside a category constrains results
    // to that category (with a one-tap "Search all" escape in the results view).
    private var scopeCategory: CaskCategory? {
        switch selection {
        case .category(let cat): return cat
        case .subcategory(let cat, _): return cat
        default: return nil
        }
    }
    private var scopeSubcategory: String? {
        if case .subcategory(_, let sub) = selection { return sub }
        return nil
    }

    var body: some View {
        Group {
            if let formula = selectedFormula {
                FormulaDetailView(formula: formula, onBack: { selectedFormula = nil })
            } else if let cask = selectedCask {
                DetailView(cask: cask, onBack: { selectedCask = nil })
            } else if isSearching && !isLocalSearchSection {
                // Catalog-style sections (Home, categories, Browse, formulae)
                // overlay the global search results. Inventory sections fall
                // through to sectionView, which filters its own list locally.
                SearchResultsView(query: $searchText,
                                  viewModel: searchViewModel,
                                  scopeCategory: scopeCategory,
                                  scopeSubcategory: scopeSubcategory,
                                  onCaskTapped: { selectedCask = $0 },
                                  onFormulaTapped: { selectedFormula = $0 },
                                  onBack: { searchText = "" })
            } else {
                sectionView
            }
        }
        // Switching sidebar sections always dismisses an open detail page
        // and clears any in-progress search.
        .onChange(of: selection) { _, _ in
            selectedCask = nil
            selectedFormula = nil
            searchText = ""
        }
        // Deep-link entry points (Spotlight result tap, OpenCaskIntent) publish a
        // request on the shared service; resolve it to an in-app detail page here.
        .onChange(of: appData.pendingDeepLink) { _, _ in
            resolveDeepLink()
        }
        // A Mac App / Other Apps row asked to adopt via the Maintenance flow
        // (rather than inline). Switch the sidebar to Maintenance; MaintenanceView
        // observes the same request and opens the Adopt sheet targeted at the app.
        .onChange(of: appData.adoptNavigationRequest) { _, request in
            if request != nil { selection = .maintenance }
        }
        // Cold launch: a deep-link can arrive before the catalogs finish loading,
        // so re-attempt resolution once casks or formulae become available.
        .onChange(of: appData.casks.count) { _, _ in
            resolveDeepLink()
        }
        .onChange(of: appData.formulae.count) { _, _ in
            resolveDeepLink()
        }
        .onAppear { resolveDeepLink() }
        // CRITICAL: pin the detail column to always fill the available space.
        // The body is a Group, which has no layout of its own and adopts the
        // size of whichever child it shows. When a child changes its ideal
        // height — e.g. the Installed view switching origin-filter segments,
        // which adds/removes rows and an explainer line — the Group reports a
        // new ideal size that bubbles up to the WindowGroup. With
        // windowResizability(.contentMinSize) the window then grows to fit and
        // runs off the bottom of the screen. Forcing maxWidth/maxHeight to
        // infinity makes the detail size stable (always fill), so content
        // changes can never resize the window again.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Resolves a pending deep-link request to a cask or formula detail page
    // (overlaying the current section; Back returns to it). Clears any active
    // search first so the detail page isn't hidden behind search results.
    //
    // Routing by kind:
    //  • .cask    → look up appData.casks; open the cask detail page.
    //  • .formula → look up appData.formulae; if missing from the browsable
    //               catalog (an installed deprecated/disabled formula), lazy-fetch
    //               it from the API so the detail page still opens.
    //  • .unknown → try casks first, then formulae (bare OpenCaskIntent token).
    //
    // The request is consumed (set to nil) once resolved against a loaded catalog
    // so the .onChange handlers don't loop. If the relevant catalog hasn't loaded
    // yet, the request is LEFT in place and the count .onChange handlers retry.
    private func resolveDeepLink() {
        guard let request = appData.pendingDeepLink else { return }
        let token = request.token

        switch request.kind {
        case .cask:
            guard !appData.casks.isEmpty else { return }   // catalog not ready; retry later
            if let match = appData.casks.first(where: { $0.token == token }) {
                searchText = ""
                selectedCask = match
            }
            appData.pendingDeepLink = nil

        case .formula:
            // If the catalog formula list is loaded, try it first.
            if let match = appData.formulae.first(where: { $0.name == token }) {
                searchText = ""
                selectedFormula = match
                appData.pendingDeepLink = nil
                return
            }
            // Not in the browsable catalog (or catalog not loaded yet). Lazy-fetch
            // from the API so installed deprecated/disabled formulae still open.
            // Consume the request now so the count .onChange handlers don't also
            // fire a duplicate fetch.
            appData.pendingDeepLink = nil
            Task {
                if let fetched = try? await appData.api.fetchFormula(name: token) {
                    searchText = ""
                    selectedFormula = fetched
                }
            }

        case .unknown:
            guard !appData.casks.isEmpty else { return }   // catalog not ready; retry later
            if let cask = appData.casks.first(where: { $0.token == token }) {
                searchText = ""
                selectedCask = cask
                appData.pendingDeepLink = nil
                return
            }
            if let formula = appData.formulae.first(where: { $0.name == token }) {
                searchText = ""
                selectedFormula = formula
            }
            // Consume even if unresolved against the loaded cask catalog so we
            // don't loop. (Unknown is the cask-only intent path; a missing token
            // means no such cask.)
            appData.pendingDeepLink = nil
        }
    }

    @ViewBuilder
    private var sectionView: some View {
        switch selection {
        case .home:
            HomeView(scrollAnchor: $homeScrollAnchor,
                     onCaskTapped: { selectedCask = $0 },
                     onFormulaTapped: { selectedFormula = $0 },
                     onShowSort: { selection = $0 })
        case .installed:
            InstalledView(onPackageTapped: { pkg in
                openDetail(for: pkg)
            }, searchText: $searchText)
        case .maintenance:
            MaintenanceView()
        case .updates:
            UpdatesView(onPackageTapped: { pkg in
                openDetail(for: pkg)
            }, searchText: $searchText)
        case .appUpdates:
            AppUpdatesView(searchText: $searchText)
        case .appUpdatesOnly:
            AppUpdatesView(searchText: $searchText, updatesOnly: true)
        case .taps:
            TapsView(searchText: $searchText)
        case .trending, .recentlyUpdated, .topPastYear, .browseAll, .category, .subcategory:
            BrowseView(viewModel: browseViewModel, onCaskTapped: { selectedCask = $0 })
                .onChange(of: selection, initial: true) { _, newValue in
                    applySidebarFilter(newValue)
                }
        case .formulaeRoot:
            FormulaBrowseView(subcategory: nil, onFormulaTapped: { selectedFormula = $0 })
        case .formulaSubcategory(let sub):
            FormulaBrowseView(subcategory: sub, onFormulaTapped: { selectedFormula = $0 })
        case .favorites:
            FavoritesView(onCaskTapped: { selectedCask = $0 })
        case .notes:
            NotesView(onPackageTapped: { token, type in
                openDetail(token: token, type: type)
            })
        case .parked:
            ParkedView()
        case .brewfile:
            BrewfileView()
        case .settings:
            // In-app Settings (sidebar): "Save and Exit" returns to Home rather
            // than closing the whole app window.
            SettingsView(onDone: { selection = .home })
        case .none:
            ComingSoonView(title: "Select a section")
        }
    }

    // Opens the detail page for a tapped installed package, routing by its type.
    //  • cask    → resolve the token against the cask catalog → cask detail page.
    //  • formula → resolve the name against the formula catalog; if absent (an
    //               installed deprecated/disabled formula not in the browsable
    //               list), lazy-fetch from the API so the page still opens.
    // Falls back to a no-op only if the cask catalog has no match.
    // Opens a detail page for a (token, type) pair. Used by the Tags pane in
    // Notes & Tags, where a tapped package is identified by token + type.
    private func openDetail(token: String, type: PackageType) {
        switch type {
        case .cask:
            if let match = appData.casks.first(where: { $0.token == token }) {
                selectedFormula = nil
                selectedCask = match
            }
        case .formula:
            if let match = appData.formulae.first(where: { $0.name == token }) {
                selectedCask = nil
                selectedFormula = match
            } else {
                Task {
                    if let fetched = try? await appData.api.fetchFormula(name: token) {
                        selectedCask = nil
                        selectedFormula = fetched
                    }
                }
            }
        }
    }

    private func openDetail(for pkg: InstalledPackage) {
        switch pkg.type {
        case .cask:
            if let match = appData.casks.first(where: { $0.token == pkg.token }) {
                selectedFormula = nil
                selectedCask = match
            }
        case .formula:
            if let match = appData.formulae.first(where: { $0.name == pkg.token }) {
                selectedCask = nil
                selectedFormula = match
            } else {
                let name = pkg.token
                Task {
                    if let fetched = try? await appData.api.fetchFormula(name: name) {
                        selectedCask = nil
                        selectedFormula = fetched
                    }
                }
            }
        }
    }

    // Maps a catalog-style sidebar item to the BrowseViewModel's filters so the
    // shared BrowseView reflects whatever the user picked in the sidebar.
    //
    // IMPORTANT: every assignment goes through the `set...` helpers below, which
    // only write when the value actually CHANGES. This modifier is attached with
    // `.onChange(of: selection, initial: true)`, so it re-fires every time the
    // BrowseView re-appears — including when the user taps Back from a detail
    // page (the detail/section Group rebuilds the BrowseView). The view model's
    // filter `didSet`s reset pagination (flatDisplayLimit) AND wipe the saved
    // `scrollAnchorID`; firing them on an unchanged value on every Back was
    // collapsing the list to page 1 and destroying the anchor, so scroll
    // restoration always snapped to the top. Skipping no-op writes preserves
    // both, which is what makes Back restore the prior scroll position.
    private func applySidebarFilter(_ item: SidebarItem?) {
        // Did the user genuinely move to a different sidebar item, or is this a
        // no-op re-appear (Back from detail) with the same selection?
        let isGenuineChange = (item != lastAppliedSidebarItem)
        lastAppliedSidebarItem = item
        switch item {
        case .trending:
            setCategory(nil); setFOSS(false); setCommercial(false); setSort(.trending)
        case .recentlyUpdated:
            // "3-Month Trend" reuses the existing .recentlyUpdated sidebar tag
            // (kept to avoid touching the SidebarItem identity); it now drives the
            // 90-day install sort instead of the old tapGitHead "newest" order.
            setCategory(nil); setFOSS(false); setCommercial(false); setSort(.allTimePopular)
        case .topPastYear:
            // "Top Past Year" drives the 365-day install sort — the longest
            // popularity window Homebrew analytics expose.
            setCategory(nil); setFOSS(false); setCommercial(false); setSort(.topPastYear)
        case .browseAll:
            // The full A–Z catalog. Force alphabetical so it reads as a complete
            // index rather than inheriting a trending sort from a prior selection.
            setCategory(nil); setFOSS(false); setCommercial(false); setSort(.alphabetical)
        case .category(let cat):
            // Categories sort by trending (30-day installs) so the most popular
            // app in the category surfaces first — best for discovery.
            setFOSS(false); setCommercial(false); setSubcategory(nil); setSort(.trending); setCategory(cat)
        case .subcategory(let cat, let sub):
            setFOSS(false); setCommercial(false); setSort(.trending)
            // Set the subcategory first so the category's didSet doesn't reset it.
            setSubcategory(sub); setCategory(cat)
        default:
            break
        }

        // Safety net for the browse grid. The change-guarded setters above skip
        // re-running applyFilters() when nothing changed value — which is what
        // preserves scroll position on Back. But that same skip can leave the
        // Trending/3-Month/Past-Year list stale or partial if applyFilters()
        // last ran against an incomplete catalog (a load() race at launch).
        // So: on a GENUINE selection change into a browse view, OR whenever the
        // displayed list is empty while the catalog is actually populated,
        // force a fresh in-memory filter/sort and reset pagination. This is
        // pure array work (no DB/network) and only runs on a real transition,
        // never on a Back re-appear with an unchanged selection.
        switch item {
        case .trending, .recentlyUpdated, .topPastYear, .browseAll, .category, .subcategory:
            let listEmptyButCatalogLoaded =
                browseViewModel.filteredCasks.isEmpty && !browseViewModel.casks.isEmpty
            if isGenuineChange || listEmptyButCatalogLoaded {
                browseViewModel.refreshDisplayedList()
            }
        default:
            break
        }
    }

    // Change-guarded setters: assign only when the new value differs, so the view
    // model's filter `didSet`s (which reset pagination + clear scrollAnchorID)
    // don't fire on a no-op re-application when the BrowseView re-appears.
    private func setCategory(_ value: CaskCategory?) {
        if browseViewModel.selectedCategory != value { browseViewModel.selectedCategory = value }
    }
    private func setSubcategory(_ value: String?) {
        if browseViewModel.selectedSubcategory != value { browseViewModel.selectedSubcategory = value }
    }
    private func setFOSS(_ value: Bool) {
        if browseViewModel.showFOSSOnly != value { browseViewModel.showFOSSOnly = value }
    }
    private func setCommercial(_ value: Bool) {
        if browseViewModel.showCommercialOnly != value { browseViewModel.showCommercialOnly = value }
    }
    private func setSort(_ value: SortOrder) {
        if browseViewModel.sortOrder != value { browseViewModel.sortOrder = value }
    }
}

struct ComingSoonView: View {
    let title: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hammer")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            Text("Coming soon")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

// MARK: - Window size guard
//
// AppKit-level safety net that makes the main window physically incapable of
// growing past the screen. SwiftUI's .windowResizability(.contentMinSize)
// lets the detail content drive the window size; a tall List ideal height was
// pushing the window to ~2200pt, running it off the bottom of a 1080p screen.
//
// windowWillResize(_:to:) is called by AppKit BEFORE any resize is applied -
// content-driven OR user drag - and we return a clamped size. Because we
// return a value (rather than calling setFrame during layout) this never
// re-enters the layout/constraint cycle, so it cannot crash the way the old
// didResize+setFrame observers did.
//
// SwiftUI installs its own window delegate, so we wrap it: keep a reference to
// the original delegate and forward every unrecognized selector to it, so all
// of SwiftUI's normal window behavior is preserved.
// Persists the main window's frame under a STABLE UserDefaults key, independent
// of SwiftUI's WindowGroup autosave key (which embeds the full view-type
// signature and is re-minted on every view-tree/content change, orphaning the
// saved size so the window reverts to .defaultSize on each launch). We save on
// resize/move and restore on first show, so the window reopens exactly where and
// how the user left it.
enum WindowFramePersistence {
    static let key = "ForgedBrewMainWindowFrame"
    static let sidebarKey = "ForgedBrewSidebarWidth"

    // While we are programmatically restoring the saved frame/sidebar at launch,
    // the resulting setFrame / divider moves fire windowDidResize. Without this
    // guard those echo-resizes (and SwiftUI's own content-driven resize that
    // lands a tick later) would SAVE the default size back over the user's
    // value. We only re-arm saving once the launch restore has fully settled.
    @MainActor static var isRestoring = false

    @MainActor static func save(_ window: NSWindow) {
        guard !isRestoring else { return }
        // Ignore zero/again-degenerate frames AppKit can momentarily report.
        guard window.frame.width > 1, window.frame.height > 1 else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: key)
        saveSidebarWidth(window)
    }

    static func restore(_ window: NSWindow) {
        guard let saved = UserDefaults.standard.string(forKey: key) else { return }
        let rect = NSRectFromString(saved)
        guard rect.width > 1, rect.height > 1 else { return }
        window.setFrame(rect, display: true)
    }

    // Find the sidebar split view AppKit creates for NavigationSplitView. It is
    // the first NSSplitView in the window's content view hierarchy.
    static func findSplitView(_ window: NSWindow) -> NSSplitView? {
        guard let content = window.contentView else { return nil }
        var stack: [NSView] = [content]
        while let v = stack.popLast() {
            if let split = v as? NSSplitView { return split }
            stack.append(contentsOf: v.subviews)
        }
        return nil
    }

    static func saveSidebarWidth(_ window: NSWindow) {
        guard let split = findSplitView(window),
              split.isVertical,
              split.arrangedSubviews.count >= 2 else { return }
        let w = split.arrangedSubviews[0].frame.width
        guard w > 1 else { return }
        UserDefaults.standard.set(Double(w), forKey: sidebarKey)
    }

    static func restoreSidebarWidth(_ window: NSWindow) {
        guard let split = findSplitView(window),
              split.isVertical,
              split.arrangedSubviews.count >= 2 else { return }
        let saved = UserDefaults.standard.double(forKey: sidebarKey)
        // If the user never adjusted it, default to a width that shows the full
        // sidebar labels (matches navigationSplitViewColumnWidth ideal/upper).
        let target: CGFloat = saved > 1 ? CGFloat(saved) : 360
        split.setPosition(target, ofDividerAt: 0)
    }

    // Enforce the saved frame + sidebar by re-applying them on a short repeating
    // timer for a fixed window, regardless of when SwiftUI's late
    // content-driven resize fires. Saving stays suppressed the whole time so
    // none of these echoes overwrite the user's saved value; we re-arm at the
    // end. A blanket 3s of enforcement is simple and reliably beats the race.
    @MainActor static func enforceRestore(on window: NSWindow, fit: @escaping (NSWindow) -> Void) {
        isRestoring = true
        let deadline = Date().addingTimeInterval(3.0)
        // Apply once immediately so the very first paint is already correct.
        restore(window)
        restoreSidebarWidth(window)
        fit(window)
        let timer = Timer(timeInterval: 0.025, repeats: true) { t in
            MainActor.assumeIsolated {
                restore(window)
                restoreSidebarWidth(window)
                fit(window)
                if Date() >= deadline {
                    t.invalidate()
                    // Re-arm saving a tick after enforcement ends so the final
                    // settle is not itself saved as churn.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isRestoring = false
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

final class WindowSizeGuard: NSObject, NSWindowDelegate {
    weak var forward: NSWindowDelegate?

    init(forwarding original: NSWindowDelegate?) {
        self.forward = original
    }

    private func cap(for window: NSWindow) -> NSSize {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size
            ?? NSSize(width: 1920, height: 1049)
        // Leave a small clearance below the menu bar so the title bar and the
        // first content row are never flush against (or clipped by) the menu
        // bar. Capping to the exact visibleFrame height let the window grow
        // edge-to-edge tall, which jammed the top chrome into the menu bar.
        let clearance: CGFloat = 12
        return NSSize(width: visible.width,
                      height: max(480, visible.height - clearance))
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let maxSize = cap(for: sender)
        var size = frameSize
        size.width = min(size.width, maxSize.width)
        size.height = min(size.height, maxSize.height)
        // If SwiftUI also wants a say, let it clamp further (never larger).
        if let forwarded = forward?.windowWillResize?(sender, to: size) {
            size.width = min(size.width, forwarded.width)
            size.height = min(size.height, forwarded.height)
        }
        return size
    }

    // After any resize completes, nudge the origin so every edge stays on the
    // usable screen. windowWillResize only caps the SIZE; if the window was
    // anchored near the top, capping the height can leave the title bar above
    // the menu bar (off the top) or the bottom below the Dock. AppKit uses a
    // bottom-left origin: clamp x into [minX, maxX - width] and y into
    // [minY, maxY - height]. setFrameOrigin is origin-only and does NOT re-enter
    // the constraint/layout cycle, so this is recursion-safe.
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let frame = window.frame
        var origin = frame.origin
        origin.x = min(max(origin.x, visible.minX), visible.maxX - frame.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - frame.height)
        if origin != frame.origin {
            window.setFrameOrigin(origin)
        }
        WindowFramePersistence.save(window)
        forward?.windowDidResize?(notification)
    }

    // Persist the window frame on MOVE too, so dragging the window (not just
    // resizing it) is remembered across launches.
    func windowDidMove(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            WindowFramePersistence.save(window)
        }
        forward?.windowDidMove?(notification)
    }

    // Forward everything else to SwiftUI's original delegate so standard
    // window behavior (close, miniaturize, key/main handling, etc.) is intact.
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return forward?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let f = forward, f.responds(to: aSelector) { return f }
        return super.forwardingTarget(for: aSelector)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Default a GENUINE first install to dark mode — but only that.
        // A fresh install has never shown the Welcome window, so
        // "forgedbrewLastWelcomeVersion" is still empty here (this runs before
        // showWelcomeIfNeeded() stamps it). We also require that no appearance
        // value has ever been written, so an explicit Light/Dark choice always
        // wins. Existing users (who already have a stamped welcome version) are
        // left untouched: with no saved appearance value they keep following
        // their prior Light/system look rather than being flipped to dark.
        let defaults = UserDefaults.standard
        let hasShownWelcomeBefore = !(defaults.string(forKey: "forgedbrewLastWelcomeVersion") ?? "").isEmpty
        let hasAppearancePreference = defaults.object(forKey: "forgedbrewPrefersDarkMode") != nil
        if !hasShownWelcomeBefore && !hasAppearancePreference {
            defaults.set(true, forKey: "forgedbrewPrefersDarkMode")
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        // Was this a login-item / automatic launch (vs. the user double-clicking
        // the app)? macOS reports false here when it launched us automatically.
        let isAutomaticLaunch =
            (notification.userInfo?["NSApplicationLaunchIsDefaultLaunchKey"] as? Bool) == false

        MainActor.assumeIsolated {
            // Re-apply the user's saved "Keep in Dock" preference on every launch
            // so the Dock-visibility choice persists across restarts/installs.
            StartupSettings.applySavedDockVisibilityAtLaunch()
            // Re-create the menu bar extra if the user had it enabled.
            StartupSettings.shared.applySavedMenuBarVisibilityAtLaunch()

            // "Show in menu bar" implies start-hidden: on an automatic (login)
            // launch, slip straight into menu-bar-only mode — no window, no Dock
            // bounce, no focus steal. The menu bar icon is the way back in.
            if isAutomaticLaunch && StartupSettings.shared.shouldStartHeadless {
                StartupSettings.shared.enterHeadlessMode()
            }
        }

        // Track window visibility so the temporary Dock icon (when Keep in Dock
        // is off) appears while a window is open and drops when it closes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameVisible(_:)),
            name: NSWindow.didBecomeMainNotification, object: nil)
        // Note: window close is handled by windowShouldClose(_:) (we become the
        // window's delegate), which hides-vs-closes and calls windowDidClose()
        // itself — so there's no separate willClose observer here.
    }

    // True for the app's auxiliary child windows (the ⌘, Settings window, the
    // User Manual window, the Welcome window). Their red X must close ONLY that
    // child window — it must never be retargeted to the menu-bar hide/terminate
    // path, which is meant solely for the main WindowGroup window. Without this
    // guard, closing the Settings window (when it was the key window) was hiding
    // it through the main-window path and, with the menu bar off, quitting the
    // whole app.
    private func isAuxiliaryWindow(_ window: NSWindow) -> Bool {
        let id = window.identifier?.rawValue ?? ""
        if id == WelcomeWindowID || id == UserManualWindowID { return true }
        // SwiftUI's Settings scene window identifies as "com.apple.SwiftUI.Settings".
        if id.localizedCaseInsensitiveContains("settings") { return true }
        if window.title == "Settings"
            || window.title == "ForgedBrew User Manual"
            || window.title == "Welcome to ForgedBrew" { return true }
        return false
    }

    @objc private func windowBecameVisible(_ note: Notification) {
        guard let window = note.object as? NSWindow, window.canBecomeMain else {
            return
        }
        MainActor.assumeIsolated {
            // Only the MAIN WindowGroup window gets the red-X retargeting. Leave
            // auxiliary child windows (Settings, User Manual, Welcome) on their
            // normal close behavior so their red X just closes that one window.
            guard !isAuxiliaryWindow(window) else {
                StartupSettings.shared.windowDidBecomeVisible()
                return
            }
            // Retarget the red close button so the red X HIDES the window instead
            // of closing/destroying it when ForgedBrew should live on in the menu
            // bar. We do this at the button level rather than via the window
            // delegate because SwiftUI owns the WindowGroup's delegate and its
            // close path was bypassing windowShouldClose, fully terminating the
            // app (and the menu bar icon with it). Repointing the close button
            // target/action is something SwiftUI does not override.
            if let closeButton = window.standardWindowButton(.closeButton),
               !(closeButton.target === self && closeButton.action == #selector(handleCloseButton(_:))) {
                closeButton.target = self
                closeButton.action = #selector(handleCloseButton(_:))
            }
            // Give the main window a stable autosave name and a sane minimum
            // size. SwiftUIs own window-frame key embeds the full view-type
            // signature, so every content change mints a brand-new key and the
            // saved on-screen position is lost. A fixed name keeps a good
            // position across launches AND code edits.
            // Floor the CONTENT min size at the detail card minimum (scroll
            // column + the fixed 260pt info sidebar + the navigation sidebar +
            // spacing). The window uses .windowResizability(.contentMinSize), so
            // its size tracks the largest content shown. The Home/browse views
            // are narrower/shorter than a detail card, so opening a card used to
            // make the window JUMP BIGGER (and that resize relayout also tucked
            // the sidebar "Discover" header under the title bar). Setting the
            // floor here at the AppKit window level — NOT via a SwiftUI .frame on
            // the split view, which pulls content up under the title bar — makes
            // .contentMinSize resolve to this constant for every view, so the
            // window opens at this size and never grows on navigation. AppKit
            // clamps the upper bound via maxSize / WindowSizeGuard just below.
            window.contentMinSize = NSSize(width: 1100, height: 720)
            // HARD CAP: install an AppKit-level size guard so the window can
            // never grow past the usable screen, no matter how tall the SwiftUI
            // detail content reports its ideal height. windowWillResize returns
            // a clamped size BEFORE every resize (content-driven or user), which
            // is recursion-free (unlike calling setFrame during layout). We wrap
            // SwiftUIs own delegate so its behavior is preserved. Also set
            // maxSize as a second line of defense.
            if let screen = window.screen ?? NSScreen.main {
                let visible = screen.visibleFrame.size
                // Match WindowSizeGuard.cap(): leave clearance below the menu bar.
                window.maxSize = NSSize(width: visible.width,
                                        height: max(480, visible.height - 12))
            }
            if !(window.delegate is WindowSizeGuard) {
                let guardDelegate = WindowSizeGuard(forwarding: window.delegate)
                windowSizeGuards.append(guardDelegate)
                window.delegate = guardDelegate
            }
            // Keep the window inside the visible screen. We do this ONCE, on the
            // next run-loop turn, OUTSIDE AppKits layout/constraint pass. Doing
            // it inside that pass (or from didResize/didMove observers that call
            // setFrame) re-enters the constraint-update cycle and AppKit traps
            // with an uncaught exception, crashing the app. A single deferred
            // pass corrects a late saved/oversized frame without recursing.
            // Restore the user's last size/position (our stable key), then clamp
            // it on-screen. Deferred one runloop tick so it runs AFTER SwiftUI's
            // own default-size pass and therefore wins.
            // Stop SwiftUI/AppKit's own window+splitview state restoration from
            // churning competing keys and re-resizing the window at launch; we
            // own restore via WindowFramePersistence below.
            window.isRestorable = false
            // Restore the user's last size/position AND sidebar width.
            //
            // The hard part is that SwiftUI's .contentMinSize re-evaluates the
            // window size on content layout, and that pass lands at an
            // unpredictable point AFTER first show — so a handful of fixed
            // deferred restores can lose the race and the window opens at the
            // DEFAULT size. Instead we ENFORCE the saved frame with a short
            // repeating timer: every ~25ms we re-apply the saved frame + sidebar
            // for up to ~3s, stopping early once the on-screen frame matches the
            // saved target (within a few points). Saving stays suppressed
            // (isRestoring) for the whole enforcement window so none of these
            // programmatic setFrame echoes — or SwiftUI's late resize — overwrite
            // the user's saved value. We then re-arm saving.
            WindowFramePersistence.enforceRestore(on: window) { [weak self] w in
                self?.fitWindowOnScreen(w)
            }
            StartupSettings.shared.windowDidBecomeVisible()
        }
    }

    // One-shot, run-loop-deferred correction: cap the window to the usable
    // screen and push every edge on-screen. AppKit uses a bottom-left origin,
    // so clamp x into [minX, maxX - width] and y into [minY, maxY - height].
    // NOTE: this is intentionally NOT wired to resize/move notifications -
    // calling setFrame from inside the windows own layout cycle recurses and
    // crashes. Running once, deferred, is enough because the stable autosave
    // name keeps a good frame from then on.
    private func fitWindowOnScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let clearance: CGFloat = 12
        let maxHeight = max(480, visible.height - clearance)
        let original = window.frame
        var frame = original
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, maxHeight)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        if frame != original {
            window.setFrame(frame, display: true)
        }
    }

    // Red-X close button action. When ForgedBrew should keep living in the menu
    // bar (menu bar on, a live status item, or running headless) and this is the
    // last window, HIDE the window (orderOut) so the WindowGroup scene — and the
    // process — stays alive. Otherwise perform the normal close (which lets the
    // app quit as before when the menu bar is off).
    // Timestamp of the most recent red-X close-button click. applicationShould
    // Terminate uses this to tell a window-close (which it should cancel when
    // the menu bar is on) apart from a real Cmd+Q / menu-bar Quit.
    private var lastCloseButtonClick: Date = .distantPast

    // Retains the window size guard delegate (NSWindow.delegate is weak).
    private var windowSizeGuards: [WindowSizeGuard] = []

    @objc private func handleCloseButton(_ sender: Any?) {
        lastCloseButtonClick = Date()
        MainActor.assumeIsolated {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow
                    ?? NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else { return }
            let s = StartupSettings.shared
            let liveInMenuBar = s.showInMenuBar || s.hasStatusItem || s.isRunningHeadless
            let othersOpen = NSApp.windows.contains {
                $0 !== window && $0.canBecomeMain && $0.isVisible
            }
            if liveInMenuBar && !othersOpen {
                // Hide, don't close: keeps the scene + process alive in the menu
                // bar. The menu bar "Open ForgedBrew" re-shows this same window.
                window.orderOut(nil)
                s.windowDidClose()
            } else {
                // Normal close (menu bar off, or not the last window).
                window.performClose(nil)
            }
        }
    }

    // Clicking the Dock icon (or otherwise reopening) when no window is visible
    // should bring ForgedBrew's window back. Returning true lets AppKit show the
    // existing window; windowDidBecomeVisible() then restores normal behavior.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !flag, let window = sender.windows.first(where: { $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            }
            StartupSettings.shared.windowDidBecomeVisible()
        }
        return true
    }

    // ForgedBrew quits when its last window closes UNLESS it's living in the menu
    // bar. Whenever "Show in Menu Bar" is on, the menu bar icon is the user's way
    // back to the window, so closing the window should leave the app running in
    // the menu bar — regardless of whether the Dock icon is also kept. (It also
    // stays alive when running headless after a hidden login launch.)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let liveInMenuBar = MainActor.assumeIsolated {
            StartupSettings.shared.isRunningHeadless
                || StartupSettings.shared.showInMenuBar
                || StartupSettings.shared.hasStatusItem
        }
        return !liveInMenuBar
    }

    // The real termination gate. macOS/SwiftUI calls this both when the user
    // explicitly quits AND when the last window closes. Returning .terminateNow
    // from the last-window-closed path is what was killing the app (and the
    // menu bar icon) the moment the window's close button hid the last window.
    //
    // Rule: terminate only if the user explicitly asked to quit via the menu
    // bar icon's "Quit ForgedBrew" item (which sets userRequestedQuit), or if the
    // app is NOT living in the menu bar. Otherwise — i.e. the menu bar is on and
    // this quit came from Cmd+Q, the app menu's Quit, or the last window closing
    // — CANCEL termination and just hide all windows, so the menu bar icon stays
    // and "Open ForgedBrew" brings the window back.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let (userQuit, installingUpdate, liveInMenuBar) = MainActor.assumeIsolated {
            (StartupSettings.shared.userRequestedQuit,
             StartupSettings.shared.isInstallingUpdate,
             StartupSettings.shared.isRunningHeadless
                || StartupSettings.shared.showInMenuBar
                || StartupSettings.shared.hasStatusItem)
        }
        // Keep-alive rule: when ForgedBrew should live on in the menu bar, the
        // ONLY thing that truly quits the process is the menu bar icon's "Quit
        // ForgedBrew" item (which sets userRequestedQuit via requestQuit()). Every
        // other quit attempt — Cmd+Q, the app menu's Quit item, or the last
        // window closing — is treated as "exit the app window" and is redirected
        // to hiding all windows so the menu bar icon (and the process) stays
        // resident. This is what makes "Show in Menu Bar" behave like a true
        // background menu bar agent: exiting the app leaves the icon running.
        // A Sparkle-initiated relaunch (installingUpdate) must always terminate,
        // exactly like an explicit user quit — otherwise the update install stalls.
        if userQuit || installingUpdate || !liveInMenuBar {
            return .terminateNow
        }
        // Stay alive in the menu bar: hide every window and cancel the quit.
        MainActor.assumeIsolated {
            for window in NSApp.windows where window.canBecomeMain {
                window.orderOut(nil)
            }
            StartupSettings.shared.windowDidClose()
        }
        return .terminateCancel
    }

    // Security: the admin (sudo) password the user may have entered to update
    // privileged casks lives in memory ONLY for the running session. Wipe it on
    // quit so a fresh launch always re-prompts. applicationWillTerminate runs on
    // the main thread, so we can touch the MainActor-isolated singleton directly.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppDataService.shared.wipeSessionSudoPassword()
        }
    }
}

@main
struct ForgedBrewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appDataService = AppDataService.shared
    @State private var sidebarSelection: SidebarItem? = .home
    @State private var browseViewModel = BrowseViewModel()
    // Global catalog search text, bound to the toolbar search field.
    @State private var searchText = ""
    // Sparkle auto-update controller (feed/key configured in Info.plist).
    @State private var updater = Updater()

    // Opens the Welcome window programmatically on first run / after an update.
    @Environment(\.openWindow) private var openWindow
    // Persisted record of the last app version that showed the Welcome window.
    // Empty = the app has never shown Welcome (i.e. a fresh first install).
    @AppStorage("forgedbrewLastWelcomeVersion") private var lastWelcomeVersion = ""

    // The number shown on the Dock badge / menu bar extra: every available
    // update the user can actually act on — Homebrew packages PLUS Mac/other
    // apps — with parked items already excluded by both sources.
    private var availableUpdateTotal: Int {
        appDataService.outdatedExcludingParked().count
            + AppUpdateService.shared.visibleUpdates().count
    }

    // Current marketing version, e.g. "1.2.0".
    private var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    // Shows the Welcome window automatically the first time the app ever runs,
    // and again whenever it runs a version it hasn't greeted the user on yet
    // (i.e. right after an update). Once shown, we stamp the current version so
    // it won't reappear on ordinary relaunches of the same version.
    private func showWelcomeIfNeeded() {
        let version = currentAppVersion
        guard !version.isEmpty else { return }
        guard lastWelcomeVersion != version else { return }
        lastWelcomeVersion = version
        openWindow(id: WelcomeWindowID)
    }

    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                SidebarView(selection: $sidebarSelection)
                    // Explicit sidebar column width for deterministic split-view
                    // sizing at launch.
                    .navigationSplitViewColumnWidth(min: 240, ideal: 360, max: 420)
            } detail: {
                DetailRouter(selection: $sidebarSelection,
                             browseViewModel: browseViewModel,
                             searchText: $searchText)
                    // Attach .searchable to the DETAIL content rather than the
                    // NavigationSplitView itself. When it sat on the split view,
                    // AppKit inserted the toolbar NSSearchField during the
                    // window's initial layout pass, which re-entered layout and
                    // produced the once-logged "_NSDetectedLayoutRecursion"
                    // warning at launch. Hosting it on the detail column lets that
                    // column finish its first layout before the search field
                    // participates, which removes the recursion. The binding is
                    // unchanged, so search behavior is identical.
                    .searchable(text: $searchText, placement: .toolbar, prompt: "Search apps, casks, and formulae")
                    // Hide the window toolbar's own background material. The
                    // detail-card fixed header now paints its OWN opaque
                    // windowBackgroundColor that extends up into the title-bar
                    // zone, so a separate visible toolbar background is both
                    // redundant and harmful: on macOS 26 the toolbar background
                    // is what the automatic scroll-edge effect blurs/fades,
                    // ghosting the header icon + title (the reported "black/
                    // opaque bar"). Removing the toolbar background removes the
                    // fade material entirely; the header's solid fill provides a
                    // clean band. No-op visual change for the browse grids, which
                    // already supply their own opaque header background.
                    .toolbarBackground(.hidden, for: .windowToolbar)
                    // macOS 26 applies an automatic "scroll edge effect" — a
                    // blur/fade — to content under the window toolbar. That fade
                    // is what ghosts the top of the detail-card header and the
                    // browse category chips (the reported "opaque bar"). Force
                    // the HARD style on the whole detail column so the toolbar
                    // uses a crisp cutoff (no fade) instead. Propagates to every
                    // descendant scroll view too. No-op before macOS 26.
                    .hardScrollEdge(.top)
            }
            // Spotlight result tap. macOS delivers the tap as a user activity of
            // type CSSearchableItemActionType; the tapped item's unique id
            // ("cask:<token>" / "formula:<token>", per SpotlightIndexer) is in
            // userInfo under CSSearchableItemActivityIdentifier. Forward it to the
            // shared deep-link coordinator, which DetailRouter turns into an in-app
            // detail page.
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                appDataService.requestDeepLink(spotlightID: id)
            }
            // App-wide spinner. Replaces the system circular ProgressView (an
            // AppKit-hosted view) with a pure-SwiftUI arc, which removes the
            // benign macOS layout-recursion / min<=max console warnings the
            // AppKit spinner emits inside flexible containers. Propagates via
            // the environment to every ProgressView in the app.
            .progressViewStyle(.forgedbrew)
            .environment(appDataService)
            .environment(updater)
            .task {
                // First run / post-update greeting. Skipped on headless login
                // launches (menu-bar-only start), where no main window is shown;
                // the user will see Welcome the next time they open the app.
                if !StartupSettings.shared.isRunningHeadless {
                    showWelcomeIfNeeded()
                }
                await appDataService.fetchBrewVersion()
                // Full app-wide refresh on launch: Homebrew data AND the
                // Mac/other-app scan, so every panel (Installed, Updates,
                // Mac/Other apps, Parked, disk/badges) is populated up front
                // instead of only when the user first visits each page (Bug 4).
                // refreshEverything() toggles isRefreshingEverything, which the
                // overlay below watches to show a non-blocking progress banner.
                await appDataService.refreshEverything()
                // Stamp the Dock (and menu bar) badge with the available-update
                // total once the first refresh lands.
                StartupSettings.shared.updateBadge(count: availableUpdateTotal)
                // Start the periodic background update checks (runs even in
                // menu-bar-only mode). Seed its notification baseline with the
                // count we just found so pre-existing updates do not fire a
                // notification — only NEW ones discovered on a later tick do.
                BackgroundRefreshCoordinator.shared.setBaseline(total: availableUpdateTotal)
                BackgroundRefreshCoordinator.shared.configure(appData: appDataService)
            }
            // Keep the badge in sync as Homebrew updates / parks change.
            .onChange(of: appDataService.outdatedExcludingParked().count) {
                StartupSettings.shared.updateBadge(count: availableUpdateTotal)
            }
            // Keep the badge in sync as Mac/other app updates are scanned/parked.
            .onChange(of: AppUpdateService.shared.visibleUpdates().count) {
                StartupSettings.shared.updateBadge(count: availableUpdateTotal)
            }
            // First-run gate: if Homebrew isn't installed, greet the user with
            // a sheet that explains why and offers a one-tap path to install it
            // (brew.sh + the copyable install command). fetchBrewVersion() above
            // sets brewMissing from a fast filesystem check.
            .sheet(isPresented: Bindable(appDataService).brewMissing) {
                HomebrewMissingSheet(
                    isPresented: Bindable(appDataService).brewMissing
                )
            }
            // Non-blocking "Refreshing your data…" indicator. Shown in the
            // bottom-trailing corner while a full app-wide refresh runs (launch
            // or global rescan) so the user knows panels are still filling in,
            // and removed automatically when refreshEverything() completes. It's
            // an overlay (not a sheet/alert) so the window stays fully usable.
            .overlay(alignment: .center) {
                // Centered so the launch "Refreshing your data…" notice is
                // easy to see — the bottom-trailing corner was easy to miss.
                if appDataService.isRefreshingEverything {
                    RefreshingDataIndicator()
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: appDataService.isRefreshingEverything)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1440, height: 860)
        // Pin the main window to a minimum content size instead of the default
        // automatic resizability. Without this, the WindowGroup sizes to the
        // detail content ideal width, which the Installed view (segmented
        // filters + badges + explainer) pushed past the physical screen width.
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater)
            }
            // Replace the default "ForgedBrew Help" item (which points at a help
            // book that does not exist, so it shows "ForgedBrew Help isn't
            // available") with our in-app User Manual window — the same scrollable
            // guide opened from Settings > About > Open User Manual.
            CommandGroup(replacing: .help) {
                Button("ForgedBrew Help") {
                    openWindow(id: UserManualWindowID)
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        // Standard macOS Settings window (ForgedBrew > Settings…, Cmd-,). It hosts
        // the SAME tabbed SettingsView the sidebar row shows, so both doors open
        // identical content. The Settings scene is a sibling of WindowGroup and
        // does NOT inherit its environment, so inject the shared services here.
        Settings {
            SettingsView()
                .environment(appDataService)
                .environment(updater)
                .progressViewStyle(.forgedbrew)
        }

        // In-app User Manual window (opened from Settings ▸ About ▸ Open User
        // Manual via openWindow(id: UserManualWindowID)). A dedicated, resizable,
        // scrollable window so users get the full guide — with screenshots and
        // how-tos — without leaving the app for a README on GitHub. Like the
        // Settings scene, this is a sibling of WindowGroup and does NOT inherit
        // its environment, so inject the shared services here too.
        Window("ForgedBrew User Manual", id: UserManualWindowID) {
            UserManualView()
                .environment(appDataService)
                .environment(updater)
                .progressViewStyle(.forgedbrew)
        }
        .defaultSize(width: 820, height: 760)
        .windowResizability(.contentMinSize)

        // Welcome window. Shown automatically on first install and after each
        // update (see showWelcomeIfNeeded), and openable any time. A sibling of
        // WindowGroup, so it does NOT inherit its environment.
        Window("Welcome to ForgedBrew", id: WelcomeWindowID) {
            WelcomeView()
                .environment(appDataService)
                .environment(updater)
                .progressViewStyle(.forgedbrew)
        }
        .defaultSize(width: 560, height: 620)
        .windowResizability(.contentSize)
    }
}

// MARK: - RefreshingDataIndicator
//
// The small, non-blocking "Refreshing your data…" pill shown in the corner of
// the main window while a full app-wide refresh runs at launch (or after a
// global rescan). It's purely informational — a spinner + label in a capsule
// — so the window stays interactive while panels fill in behind it. The
// parent toggles its visibility on AppDataService.isRefreshingEverything.
private struct RefreshingDataIndicator: View {
    // A deep, restful forest green — easy on the eyes (the earlier bright green
    // was too glaring against the white text).
    private static let darkGreen = Color(red: 0.09, green: 0.34, blue: 0.18)

    var body: some View {
        HStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            VStack(alignment: .leading, spacing: 4) {
                Text("Refreshing your data…")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Text("Updating installed apps, updates, and more.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .background(
            Self.darkGreen,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 16, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Refreshing your data")
    }
}
