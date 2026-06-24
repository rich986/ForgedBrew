import SwiftUI

struct SearchResultRow: View {
    let cask: CaskMetadata
    let isInstalled: Bool
    let isOutdated: Bool
    // Fired when the user taps "Update" on an already-installed-but-outdated app.
    let onInstall: () -> Void
    // Fired when the user taps "Get" on a not-installed app: opens the detail
    // page so they can review everything and choose to install from there,
    // rather than firing an install command straight from the result row.
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(token: cask.token, displayName: cask.displayName, homepage: cask.homepage, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                highlightedName

                HStack(spacing: 6) {
                    Text(cask.token)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(cask.category.displayName)
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                        .foregroundStyle(.secondary)
                }

                Text(cask.desc ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                // "Get" (not installed) opens the detail page; "Update"
                // (installed + outdated) runs the upgrade in place.
                if isInstalled && isOutdated {
                    onInstall()
                } else {
                    onOpen()
                }
            } label: {
                Text(isInstalled ? (isOutdated ? "Update" : "Installed") : "Get")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AnyShapeStyle(.white))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(
                        isInstalled && !isOutdated
                            ? AnyShapeStyle(ActionColors.installed.opacity(0.85))
                            : AnyShapeStyle(Color.accentColor),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .disabled(isInstalled && !isOutdated)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // Attempts to create an AttributedString with the first occurrence of queryText highlighted bold.
    // Falls back to plain Text if AttributedString creation fails.
    private var highlightedName: some View {
        Text(cask.displayName)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
    }
}

// A search result row for a CLI formula. Mirrors SearchResultRow's layout but
// uses formula fields (no app icon — formulae have no bundle) and shows the
// 30-day install count instead of an install button (formula install/manage
// happens from the detail page).
struct FormulaSearchResultRow: View {
    let formula: FormulaMetadata
    let isInstalled: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Terminal glyph stands in for the (nonexistent) app icon.
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                Image(systemName: "terminal")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(formula.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(formula.fullName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("Formula")
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                        .foregroundStyle(.secondary)
                    if formula.deprecated || formula.disabled {
                        Text(formula.disabled ? "Disabled" : "Deprecated")
                            .font(.system(size: 10))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }

                Text(formula.desc ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if isInstalled {
                    Text("Installed")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if formula.installCount30d > 0 {
                    Text("\(formula.installCount30d.formatted())")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("installs / 30d")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

struct SearchResultsView: View {
    @Binding var query: String
    @Bindable var viewModel: BrowseViewModel
    @Environment(AppDataService.self) var appData
    // When set, the search is scoped to this category (and optionally
    // subcategory) — the user was browsing inside it when they searched.
    var scopeCategory: CaskCategory? = nil
    var scopeSubcategory: String? = nil
    // Called when a result row is tapped; the parent opens the detail page.
    var onCaskTapped: ((CaskMetadata) -> Void)? = nil
    // Called when a formula result row is tapped; opens the formula detail page.
    var onFormulaTapped: ((FormulaMetadata) -> Void)? = nil
    // Called when the Back button is tapped; the parent clears the search and
    // returns to the previous section (home, trending, etc.).
    var onBack: (() -> Void)? = nil

    // User can widen a scoped search to the whole catalog via "Search all".
    // Resets to false (re-scoped) whenever the incoming scope changes.
    @State private var searchEverything = false

    // Formula matches for the current query, filtered in-memory from the full
    // formula catalog (appData.formulae). Casks are searched by the view model
    // (DB FTS / scoped catalog filter); formulae are simpler to match directly
    // since the whole catalog is already loaded for the home Formulae feed.
    @State private var formulaResults: [FormulaMetadata] = []

    // The scope actually in effect right now (nil = whole catalog).
    private var effectiveScopeCategory: CaskCategory? {
        searchEverything ? nil : scopeCategory
    }

    // Total matches across both catalogs, for the header count.
    private var totalResultCount: Int {
        viewModel.filteredCasks.count + formulaResults.count
    }

    private var hasAnyResults: Bool {
        !viewModel.filteredCasks.isEmpty || !formulaResults.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: result count or status message
            headerBar

            Divider()

            // Main content
            if query.count < 2 {
                centeredHint("Keep typing…", icon: "magnifyingglass")
            } else if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasAnyResults {
                if let scopeName = effectiveScopeCategory?.displayName {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("No results for \"\(query)\" in \(scopeName)")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Button("Search all apps instead") { searchEverything = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    centeredHint("No results for \"\(query)\"", icon: "magnifyingglass")
                }
            } else {
                List {
                    // Apps & Casks section.
                    if !viewModel.filteredCasks.isEmpty {
                        Section {
                            ForEach(viewModel.filteredCasks) { cask in
                                let installed = appData.installedByToken[cask.token]
                                SearchResultRow(
                                    cask: cask,
                                    isInstalled: installed != nil,
                                    isOutdated: installed?.isOutdated ?? false,
                                    onInstall: {
                                        Task { for await _ in appData.install(cask: cask.token) {} }
                                    },
                                    onOpen: { onCaskTapped?(cask) }
                                )
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .contentShape(Rectangle())
                                .onTapGesture { onCaskTapped?(cask) }
                            }
                        } header: {
                            sectionHeader("Apps & Casks", count: viewModel.filteredCasks.count)
                        }
                    }

                    // Formulae section.
                    if !formulaResults.isEmpty {
                        Section {
                            ForEach(formulaResults) { formula in
                                FormulaSearchResultRow(
                                    formula: formula,
                                    isInstalled: appData.installedByToken[formula.name] != nil
                                )
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .contentShape(Rectangle())
                                .onTapGesture { onFormulaTapped?(formula) }
                            }
                        } header: {
                            sectionHeader("Formulae", count: formulaResults.count)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        // Re-run whenever the query OR the effective scope changes (the latter
        // covers tapping "Search all" / "Search only in …").
        .task(id: TaskKey(query: query, scope: effectiveScopeCategory, sub: searchEverything ? nil : scopeSubcategory)) {
            // Seed the full catalog so scoped search can filter the complete set
            // (the DB FTS path is capped at 50 rows — too few once scoped).
            viewModel.seedCatalog(appData.casks)
            viewModel.scopeCategory = effectiveScopeCategory
            viewModel.scopeSubcategory = searchEverything ? nil : scopeSubcategory
            guard query.count >= 2 else {
                viewModel.applyFilters()
                formulaResults = []
                return
            }
            await viewModel.search(query: query, db: appData.db)
            // Formulae aren't categorized like casks, so a category scope simply
            // hides them (the scope is a cask taxonomy). Unscoped searches show
            // both catalogs.
            formulaResults = searchFormulae(query: query, scoped: effectiveScopeCategory != nil)
        }
        // A brand-new scope (navigated to a different category) re-scopes.
        .onChange(of: scopeCategory) { _, _ in searchEverything = false }
    }

    // Filters the in-memory formula catalog by name / full name / description,
    // ranking exact and prefix name matches first, then by 30-day installs.
    // When a cask category scope is active, formulae are excluded (they don't
    // belong to the cask taxonomy) so a scoped search stays apps-only.
    private func searchFormulae(query: String, scoped: Bool) -> [FormulaMetadata] {
        guard !scoped else { return [] }
        let q = query.lowercased()
        let matches = appData.formulae.filter { f in
            f.name.lowercased().contains(q) ||
            f.fullName.lowercased().contains(q) ||
            (f.desc ?? "").lowercased().contains(q)
        }
        return matches.sorted { a, b in
            let an = a.name.lowercased()
            let bn = b.name.lowercased()
            // Exact name match wins, then prefix match, then install popularity.
            let aExact = an == q, bExact = bn == q
            if aExact != bExact { return aExact }
            let aPrefix = an.hasPrefix(q), bPrefix = bn.hasPrefix(q)
            if aPrefix != bPrefix { return aPrefix }
            return a.installCount30d > b.installCount30d
        }
    }

    // Identity key for .task so it re-fires on query or scope changes.
    private struct TaskKey: Equatable {
        let query: String
        let scope: CaskCategory?
        let sub: String?
    }

    // A grouped-section header: bold title plus a muted match count.
    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .textCase(nil)
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            // Standard Back control, mirroring the detail pages — returns to the
            // section the user was browsing before they started searching.
            if onBack != nil {
                Button {
                    onBack?()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            if query.count >= 2 && !viewModel.isLoading {
                Text("\(totalResultCount) result\(totalResultCount == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // Scope pill + toggle, shown only when a category scope is available.
            if let scopeCat = scopeCategory {
                if let scopeName = effectiveScopeCategory?.displayName {
                    Label("in \(scopeName)", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    Button("Search all apps") { searchEverything = true }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                } else {
                    // Currently searching everything — offer to re-scope.
                    Button("Search only in \(scopeCat.displayName)") { searchEverything = false }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func centeredHint(_ message: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    SearchResultsView(
        query: .constant("code"),
        viewModel: BrowseViewModel()
    )
    .environment(AppDataService.shared)
    .frame(width: 800, height: 600)
}
