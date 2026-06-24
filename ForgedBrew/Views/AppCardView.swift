import SwiftUI

struct AppIconPlaceholder: View {
    let token: String
    let size: CGFloat

    // Derives a color from token.hashValue, cycling through 8 colors
    private var color: Color {
        let colors: [Color] = [
            Color(red: 0.2, green: 0.5, blue: 1.0),   // blue
            Color(red: 0.2, green: 0.7, blue: 0.4),   // green
            Color(red: 0.8, green: 0.3, blue: 0.6),   // pink
            Color(red: 0.9, green: 0.5, blue: 0.1),   // orange
            Color(red: 0.5, green: 0.3, blue: 0.9),   // purple
            Color(red: 0.1, green: 0.7, blue: 0.8),   // cyan
            Color(red: 0.8, green: 0.2, blue: 0.2),   // red
            Color(red: 0.6, green: 0.6, blue: 0.1),   // olive
        ]
        let index = abs(token.hashValue) % colors.count
        return colors[index]
    }

    // First letter of token, uppercased
    private var letter: String {
        String((token.first ?? "?").uppercased())
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(letter)
                    .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
    }
}


// Shows the best available icon for a cask, in priority order:
//   1. The real local .app icon, when the app is installed (instant, cached).
//   2. The homepage favicon, fetched + cached on disk, for not-installed apps.
//   3. The generated colored-letter placeholder, while the favicon loads or
//      when none is available.
// The local-icon lookup runs OFF the main thread (AppIconService.resolvedIcon)
// via a `.task`, with a cache-only peek on appear, so scrolling stays smooth
// even during a fast fling; the favicon fallback is likewise async + cached.
struct AppIconView: View {
    let token: String
    var displayName: String = ""
    // Homepage used to derive a favicon when the app isn't installed locally.
    var homepage: String? = nil
    let size: CGFloat

    @State private var faviconImage: NSImage? = nil
    // Resolved local app icon, held in @State so a fast scroll re-evaluating
    // `body` many times never re-runs the resolve. Seeded synchronously from
    // the cache-ONLY peek below; the (possibly expensive) first-time resolve is
    // pushed into `.task`, OFF the hot body path. See AppIconService.cachedIcon.
    @State private var localIcon: NSImage? = nil

    var body: some View {
        Group {
            if let icon = localIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else if let favicon = faviconImage {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: size * 0.22))
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            } else {
                AppIconPlaceholder(token: token, size: size)
            }
        }
        // Cheap, synchronous, cache-ONLY peek on appear: if this token's icon was
        // already resolved (the common case while re-scrolling a list), show it
        // instantly without any disk/NSWorkspace work on the main thread.
        .onAppear {
            if localIcon == nil, let cached = AppIconService.shared.cachedIcon(token: token) {
                localIcon = cached
            }
        }
        .task(id: token) {
            let name = displayName.isEmpty ? token : displayName
            // Resolve the local app icon ONCE, asynchronously, so the expensive
            // first-time NSWorkspace.icon(forFile:) lookup never runs inside a
            // body evaluation during a fast scroll-fling. `icon(...)` is itself
            // cached, so this is a dictionary hit for already-seen tokens.
            if localIcon == nil {
                // resolvedIcon does the disk match + NSWorkspace.icon read on a
                // DETACHED background task, so a fast scroll-fling that realizes
                // many cards at once never blocks the main thread (the freeze).
                let resolved = await AppIconService.shared.resolvedIcon(token: token, displayName: name)
                // Guard against a stale result if this view was recycled to a
                // different token mid-resolve (LazyVGrid reuses views).
                if !Task.isCancelled, let resolved { localIcon = resolved }
            }
            // Only attempt a favicon when there's no local app icon and we have
            // a homepage to derive one from.
            guard localIcon == nil, let homepage, !homepage.isEmpty else { return }
            let favicon = await AppIconService.shared.favicon(homepage: homepage)
            if let favicon { faviconImage = favicon }
        }
    }
}

enum InstallButtonState {
    case get          // not installed
    case installed    // installed, up to date
    case update       // installed, outdated
}

struct InstallButton: View {
    let state: InstallButtonState
    let action: () -> Void

    private var label: String {
        switch state {
        case .get: return "Get"
        case .installed: return "Installed"
        case .update: return "Update"
        }
    }

    private var color: Color {
        switch state {
        case .get: return .accentColor
        case .installed: return ActionColors.installed
        case .update: return .orange
        }
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AnyShapeStyle(.white))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    state == .installed
                        ? AnyShapeStyle(ActionColors.installed.opacity(0.85))
                        : AnyShapeStyle(color),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .disabled(state == .installed)
    }
}

// Small category tag shown on the card so users can see what bucket an app
// belongs to at a glance (addresses "cards feel too sparse" feedback). Uses the
// in-memory classifier — no network.
struct CardCategoryChip: View {
    let cask: CaskMetadata

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: cask.category.sfSymbol)
                .font(.system(size: 8, weight: .semibold))
            Text(cask.subcategory)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.10), in: Capsule())
    }
}

// A single icon+text metadata pill used in the card's meta row (version,
// dependency count, etc.). All data is already in CaskMetadata — no network.
struct CardMetaPill: View {
    let systemImage: String
    let text: String
    // Tint for the pill. Defaults to .secondary (the standard muted look used
    // by every existing pill); the Status pill overrides it to amber so a
    // Deprecated cask stands out.
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
    }
}

// A compact banner thumbnail shown at the top of a card (Phase B). The image
// source is the cask's GitHub social-preview banner (a plain CDN image, NOT a
// GitHub API call — so it costs nothing against the 60/hr API cap). Resolution
// is lazy and cache-first: because grids use LazyVGrid, this `.task` only runs
// for cards actually scrolled into view. Once resolved, the result (image or a
// ".none" marker) is persisted to disk, so a card never re-fetches.
//
// The view renders NOTHING (zero height) when there's no banner — the ~89% of
// casks without a GitHub repo, or one whose banner failed — so those cards look
// exactly as they did before Phase B and the grid stays uniform.
struct CardThumbnailView: View {
    let cask: CaskMetadata
    var height: CGFloat = 84

    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    }
                    .padding(.bottom, 10)
            }
        }
        .task(id: cask.token) {
            await load()
        }
    }

    private func load() async {
        let cache = ForgedBrewCacheService.shared

        // Cache-first: show an existing thumbnail without any network.
        if let local = await cache.cachedThumbnail(token: cask.token),
           let nsImage = await AppIconService.decodeImage(at: local) {
            image = nsImage
            return
        }

        // Prefer a real README screenshot when one is ALREADY cached on disk
        // from a prior detail-page visit. The detail page resolves README
        // images first (then web-search, then the social-preview banner) and
        // caches the downscaled set keyed by token+version, so reusing its lead
        // image gives the card an authentic screenshot at ZERO network cost. We
        // only read what's already cached — we never fetch a README per card
        // (that would be a GitHub API call against the 60/hr cap for every card
        // scrolled into view). Promote it into the thumbnail slot so it sticks
        // and we don't re-check the screenshot cache on every scroll.
        if let shot = await cache.firstCachedScreenshot(token: cask.token, version: cask.version),
           let stored = await cache.storeThumbnail(fromLocal: shot, token: cask.token),
           let nsImage = await AppIconService.decodeImage(at: stored) {
            image = nsImage
            return
        }

        // Already resolved (e.g. a ".none" marker) — nothing to show, no re-fetch.
        if await cache.hasResolvedThumbnail(token: cask.token) { return }

        // Fallback: the GitHub social-preview banner (a plain CDN image, no API
        // call). Only casks with a GitHub repo have one. Fetch + downscale +
        // persist once, then display.
        guard let remote = cask.socialPreviewURL else { return }
        if let stored = await cache.storeThumbnail(remoteURL: remote, token: cask.token),
           let nsImage = await AppIconService.decodeImage(at: stored) {
            image = nsImage
        }
    }
}

struct AppCardView: View {
    let cask: CaskMetadata
    let installed: InstalledPackage?
    let installCount: Int          // install count for the active period, from caller
    // Caption suffix describing which analytics window installCount covers
    // (e.g. "30d", "90d", "1y"). When nil, the caption reads just "N installs";
    // when set, it reads "N installs / <periodLabel>" so the number is never
    // ambiguous across the Trending / 3-Month / Past-Year lists, which each
    // pass their own periods count and label.
    var periodLabel: String? = nil
    let onTap: (CaskMetadata) -> Void
    let onInstall: (CaskMetadata) -> Void

    @State private var isHovered: Bool = false

    private var buttonState: InstallButtonState {
        guard let pkg = installed else { return .get }
        return pkg.isOutdated ? .update : .installed
    }

    // Number of cask dependencies this app pulls in, when the API reported any.
    private var dependencyCount: Int {
        cask.dependsOn?.cask?.count ?? 0
    }

    // Short version label for the meta row (Homebrew versions can be long, so
    // truncate defensively even though we also lineLimit(1)).
    private var versionLabel: String? {
        guard let v = cask.version, !v.isEmpty, v != "latest" else { return nil }
        return v.count > 14 ? String(v.prefix(14)) + "…" : v
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Banner thumbnail (Phase B) — self-hides when the cask has no
            // GitHub social-preview banner, so most cards are unchanged.
            CardThumbnailView(cask: cask)

            // Top section: icon + favorite star. (License type is intentionally
            // shown only on the detail page, not on catalog cards.)
            HStack(alignment: .top, spacing: 8) {
                AppIconView(token: cask.token, displayName: cask.displayName, homepage: cask.homepage, size: 48)
                Spacer()
                FavoriteButton(token: cask.token, showHint: isHovered)
            }
            .padding(.bottom, 10)

            // Name
            Text(cask.displayName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)

            // Token
            Text(cask.token)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.bottom, 4)

            // Description. Homebrew's `desc` is a single terse blurb (median ~37
            // chars across the catalog; none exceed 80), so 2 lines is plenty —
            // a 3rd line never fills with this data. Richer/longer descriptions
            // would have to come from GitHub (Phase B, gated on detail caching).
            Text(cask.desc ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)

            // Category chip + at-a-glance metadata (all from CaskMetadata).
            CardCategoryChip(cask: cask)
                .padding(.bottom, 6)

            HStack(spacing: 10) {
                if let versionLabel {
                    CardMetaPill(systemImage: "number", text: versionLabel)
                }
                // On-disk size, shown only for installed apps (Homebrew
                // doesn't publish a size for not-installed casks).
                if let size = installed?.sizeDisplay {
                    CardMetaPill(systemImage: "internaldrive", text: size)
                }
                if cask.autoUpdates == true {
                    CardMetaPill(systemImage: "arrow.triangle.2.circlepath", text: "Auto-updates")
                }
                if dependencyCount > 0 {
                    CardMetaPill(
                        systemImage: "shippingbox",
                        text: "\(dependencyCount) dep\(dependencyCount == 1 ? "" : "s")"
                    )
                }
                // Status: flagged only when the cask is Deprecated (the
                // actionable signal). Amber, matching the detail card's Status
                // box. Active casks show no pill so the card stays uncluttered.
                if cask.deprecated {
                    CardMetaPill(systemImage: "exclamationmark.triangle", text: "Deprecated", color: .orange)
                }
            }

            Spacer(minLength: 8)

            // Bottom row: install count + button
            HStack(alignment: .bottom) {
                if installCount > 0 {
                    Text(periodLabel.map { "\(installCount.formatted()) installs / \($0)" }
                            ?? "\(installCount.formatted()) installs")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                InstallButton(state: buttonState) {
                    // "Get" (not-installed) opens the detail page so the user can
                    // review everything about the app and choose to install from
                    // there — it no longer fires an install command directly.
                    // "Update" still kicks off the upgrade in place.
                    switch buttonState {
                    case .get:
                        onTap(cask)
                    case .update:
                        onInstall(cask)
                    case .installed:
                        break
                    }
                }
            }
        }
        .padding(14)
        .frame(minHeight: 184)
        .background {
            RoundedRectangle(cornerRadius: 13)
                .fill(.background)
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .strokeBorder(.separator, lineWidth: 0.5)
                }
                .shadow(
                    color: .black.opacity(isHovered ? 0.12 : 0.04),
                    radius: isHovered ? 8 : 3,
                    y: isHovered ? 2 : 1
                )
        }
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in isHovered = hovering }
        .onTapGesture { onTap(cask) }
        .contentShape(RoundedRectangle(cornerRadius: 13))
    }
}

#Preview {
    AppCardView(
        cask: CaskMetadata(
            token: "visual-studio-code",
            name: ["Visual Studio Code"],
            desc: "Open-source code editor made by Microsoft",
            homepage: "https://code.visualstudio.com",
            version: "1.89.0",
            autoUpdates: true,
            deprecated: false,
            tapGitHead: nil,
            dependsOn: nil,
            rubySourcePath: nil
        ),
        installed: nil,
        installCount: 28432,
        onTap: { _ in },
        onInstall: { _ in }
    )
    .frame(width: 200)
    .padding()
}
