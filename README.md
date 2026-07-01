# ForgedBrew

**A tough, beautiful GUI for Homebrew on macOS.**

ForgedBrew turns Homebrew — the command-line package manager millions of Mac
users rely on — into a fast, native Mac app you can actually see. Discover and
install apps, keep everything up to date, organize your software, and keep your
Mac healthy and secure — all without touching the Terminal.

> Built for macOS · Apple Silicon · SwiftUI · powered by Homebrew

---

## Screenshots

| | |
|---|---|
| ![Home — Discover, Featured & Trending](docs/screenshots/01-home.png) | ![Browse the full catalog](docs/screenshots/02-browse.png) |
| **Home** — Discover, Featured & Trending | **Browse** — the full catalog |
| ![Browse by category with sort & filters](docs/screenshots/06-category-browse.png) | ![Installed apps & formulae](docs/screenshots/03-installed.png) |
| **Categories** — filter & sort the catalog | **Installed** — everything Homebrew manages |
| ![Homebrew Updates](docs/screenshots/04-updates.png) | ![Maintenance & security tools](docs/screenshots/05-maintenance.png) |
| **Updates** — apply updates individually or all at once | **Maintenance** — health, diagnostics & security |
| ![Settings](docs/screenshots/07-settings.png) | ![About](docs/screenshots/08-settings-about.png) |
| **Settings** — appearance, startup & updates | **About** — version & attribution |
| ![Built-in User Manual](docs/screenshots/09-user-manual.png) | ![Welcome screen](docs/screenshots/10-welcome.png) |
| **User Manual** — searchable, with annotated wireframes | **Welcome** — first-run onboarding |

---

## What's new in 2.4.2

A focused follow-up to 2.4.1 that widens the security scan and fixes a cosmetic
install-date glitch.

- **The Security Scan now covers every installed app.** Previously it checked
  only apps Homebrew installed as casks; it now runs macOS's own signature,
  notarization, and Gatekeeper checks against **every app** in /Applications,
  ~/Applications, and your custom folders — including apps you installed
  yourself and ForgedBrew itself. Results are still listed A–Z and remembered
  for 24 hours, so the larger sweep only re-runs occasionally.
- **No more "Installed Dec 31, 1903."** After an in-app update, ForgedBrew (and
  any app updated in place) could show a nonsensical 1903 install date. The date
  is now read correctly, which also fixes sorting by install date.
- **Clearer quarantine wording.** The quarantine sheet no longer hardcodes
  "/Applications and ~/Applications" — it reflects all the folders ForgedBrew
  actually scans, including your custom ones.

---

## What's new in 2.4.1

Sharper, faster **Trust Management Screening** and security scanning ahead of
Homebrew's **September 1, 2026** cask-quarantine change — plus a broad round of
cleanup and refinement across the app.

**Trust Management & security scanning**

- **No more false alarms on large apps.** Big application bundles — Microsoft
  Teams, Word, Excel, Outlook, and Affinity, for example — can take 20–30
  seconds for macOS to fully assess. Those scans now get the time they need, and
  a scan that still can't finish is reported as *inconclusive* rather than as a
  Gatekeeper failure. Healthy, fully-trusted apps no longer appear in the
  at-risk list.
- **Online notarization is now recognized.** Some apps are notarized by Apple
  without stapling the ticket into the app bundle (Microsoft's Office and Edge
  builds, for example). ForgedBrew now reads macOS Gatekeeper's own verdict, so
  these correctly show as **notarized** instead of a false "not notarized"
  warning.
- **Scans are remembered.** Security and Trust results are now saved with a
  **"Last scanned…"** timestamp and a **Re-scan** button. Reopening a scan
  screen shows your most recent results instantly instead of re-running
  everything; a fresh scan kicks off automatically only when the saved one is
  more than 24 hours old.
- **More precise vulnerability severity.** CVE results now carry a proper CVSS
  v3 severity rating instead of falling back to "Unknown" when an advisory
  publishes only a CVSS vector.

These scanning changes only make the verdicts *more* accurate — genuinely
untrusted apps (an invalid signature, or one that was never notarized) are still
flagged exactly as before.

**Cleanup & refinement**

- **Reliable installs from every screen.** Installing a cask or formula from
  Home, Browse, Search, or Favorites now uses the same secure, password-aware
  path as the detail page — so an app that needs administrator rights asks for
  your password instead of silently stalling.
- **⌘Q now quits.** With the menu-bar icon enabled, ⌘Q (and the app menu's Quit)
  now fully quit ForgedBrew; the red close button still tucks it back into the
  menu bar.
- **More accurate update detection.** A build-number suffix on one side of a
  version (e.g. "2.0.1 (4521)") no longer triggers a phantom "update available,"
  while genuine point releases (2.0 → 2.0.1) are reliably detected.
- **Better search.** Multi-word searches match again even when the words aren't
  adjacent, and queries with symbols like `c++` or `node-red` no longer come up
  empty.
- **Faster, lighter catalog.** The formula catalog now revalidates with the
  server and skips a full re-download when nothing changed, and several internal
  caches are bounded so memory stays in check during long sessions.
- **Steadier window restore.** ForgedBrew reopens at the size you left it
  (including after an in-app update) and no longer fights you if you drag the
  sidebar right after launch.
- **Under the hood.** A thorough internal documentation pass plus multiple rounds
  of automated QA hardened correctness, concurrency, and security across the app.

---

## What's new in 2.4.0

A round of cleanup, refinement, bug fixes, and improvements:

- **Fixed a stray spinner** that could briefly appear at the top of the
  Maintenance scan sheets during Security, Vulnerability, and other streaming
  scans.
- **More reliable background refresh** — overlapping refreshes no longer drop
  results or leave a stale update badge or notification behind.
- **Tidier, safer install & cleanup** — the install/cleanup log is capped so
  long operations stay responsive, and background `brew cleanup` is now tracked
  and cancelled cleanly when a new operation starts.
- **Fresher details** — analytics, GitHub stars, license, and "last updated"
  dates refresh efficiently instead of occasionally showing stale values, while
  the large catalog stays fast.
- **No more hangs from stuck helpers** — a wedged `mas` or `du` system process
  can no longer stall a scan; these are now timed out and cleaned up.
- **Snappier Installed & Updates lists** on large libraries.
- **More accurate vulnerability severity** — a true "None" rating for items with
  a CVSS score of 0.0, distinct from "Unknown."
- **Security hardening** — added protection against server-side request forgery
  when fetching update info from app metadata, and the optional SerpApi key is
  no longer retained in the on-disk network cache.

---

<details>
<summary><strong>Earlier releases</strong></summary>

### 2.3.7

A round of correctness, performance, and reliability polish:

- **More reliable update detection** — apps that bump only their build number
  (common for self-updating apps like browsers and Office) are no longer
  missed, and version comparison handles `v`-prefixed and parenthesised build
  versions correctly.
- **Smoother Installed & Updates lists** — date formatting and the update HUD
  were optimised to do less work while you scroll, so large libraries feel
  snappier.
- **Sturdier networking** — catalog and detail requests now have explicit
  timeouts, so a slow or flaky connection can no longer hang a load for a full
  minute.
- **Lighter memory use** — the in-memory caches for README, About, and
  Wikipedia text are now bounded, keeping memory in check during long browsing
  sessions.
- **Smarter Shortcuts/Siri install** — the "Install Cask" intent now asks for
  confirmation before installing and reports success based on what was actually
  installed, not by guessing from log text.
- **More accurate Open-Source & security info** — GitHub repository detection
  ignores query strings and non-repository links, improving the "Open Source"
  badge and vulnerability lookups.
- **Hardened admin-password handling** and a more accurate description of how
  your password is used, plus a startup-robustness fix so a stale local cache
  entry can never prevent the app from opening.

</details>

---

## Why ForgedBrew

Homebrew is incredibly powerful, but it lives entirely in the Terminal. That
means typing exact package names, remembering commands, and never really
*seeing* what you have installed or what needs attention. ForgedBrew gives
Homebrew a strong, modern face:

- **See everything** — every app and command-line tool Homebrew manages, in one
  place, with icons, descriptions, and version info. You will see a Summary Card View
  and Detailed Card View with everything you need to see within the ForgedBrew GUI!
- **Find anything fast** — search the entire catalog by name, by Homebrew token,
  or by *what an app does* ("password manager", "screenshot").
- **One-click install & update** — ForgedBrew runs Homebrew for you and shows
  live progress. No commands to memorize.
- **Stay healthy & safe** — built-in maintenance and security tools that keep
  your Homebrew install clean and flag risky software.

### A quick vocabulary

ForgedBrew uses Homebrew's own terms, explained in plain language throughout the
app:

- **Cask** — a Mac app installed by Homebrew (for example, VS Code or Firefox).
- **Formula** — a command-line tool installed by Homebrew (for example, `git`
  or `wget`).
- **Tap** — an extra source of Homebrew recipes beyond the official catalog.

---

## Features

### Discover
- **Home** — a curated starting grid of featured and popular apps.
- **Currently Trending · 3-Month Trend · Top Past Year** — discover great
  software ranked by real Homebrew install popularity.
- **Browse All / Categories & Formulae** — browse the full catalog by category,
  including command-line tools (formulae).
- **Search** — always in the toolbar, on every screen. Searches Mac apps (casks)
  and command-line tools (formulae) at once, across names, Homebrew tokens, and
  descriptions, so you can find things by *what they do*, not just what they're
  called. Results rank exact matches and popularity first.

### Organize
- **The detail card** — a rich view of any app or tool: description, version,
  homepage, license, dependencies, disk footprint, screenshots, and a one-click
  Install / Uninstall.
- **Favorites** — heart the apps you care about for quick access.
- **Notes & Tags** — annotate and organize your software your way.
- **Parked** — hold an individual app's updates so it's skipped by "Update All."

### Installed & Updates
- **Installed Apps & Formulae** — everything Homebrew manages on your Mac.
- **Homebrew Updates** — see every available update and apply them individually
  or all at once.
- **Mac Store / Other Apps** — ForgedBrew also surfaces *available* updates for
  apps *outside* Homebrew (Mac App Store and direct downloads), so you can see at
  a glance what's out of date across your whole Mac and open each app to update it.

### Maintain & Secure
- **Maintenance tools** — keep your Homebrew installation healthy (cleanup,
  diagnostics, orphaned-package detection, duplicate detection, and more).
- **Security scanning** — surface Gatekeeper risks, clear quarantine, and flag
  known vulnerabilities so you know what's safe and what isn't.
- **Trust Management Screening** — get ahead of the Homebrew cask quarantine
  change landing **September 1, 2026** (see below).
- **Cache, Backup & Restore** — manage ForgedBrew's on-disk cache and back up /
  restore your setup.

#### Trust Management Screening

Homebrew is changing how it handles casks: starting **September 1, 2026**,
Homebrew will no longer remove the `com.apple.quarantine` flag from cask apps on
your behalf. After that date, any cask app that macOS Gatekeeper does **not**
fully trust can be blocked from launching — or forced through a manual
right-click → Open workaround — when it's downloaded fresh.

Trust Management Screening evaluates **every Homebrew cask app** on your Mac
against the four signals macOS Gatekeeper uses to decide whether an app is
trusted, and tells you — app by app — exactly which ones would have trouble
after Sept 1 and *why*. It checks:

1. **Code signature** — the app's signature is present and valid
   (`codesign --verify`). A broken or missing signature fails Gatekeeper.
2. **Developer ID / Team** — the app is signed with a recognized Apple
   Developer ID rather than ad-hoc or self-signed (`codesign -dv`).
3. **Notarization** — Apple has notarized the app and a notarization ticket is
   stapled to it, so macOS can confirm it was scanned and approved.
4. **Gatekeeper assessment** — macOS's own final verdict
   (`spctl --assess --type execute`). This is the check that ultimately decides
   whether the app is allowed to run.

> **The quarantine flag is *not* one of these four checks.** It's a separate
> "downloaded from the internet" tag macOS attaches to files. An app can have
> the quarantine flag and still pass all four trust checks, and an app can be
> missing the flag yet still *fail* Gatekeeper. That's why Trust Management
> Screening reports on trust signals directly instead of just looking for the
> flag.

Results are grouped into two tiers:

- **Trust now** — apps that currently carry the quarantine flag *and* fail
  Gatekeeper. These are actionable today: clicking **Trust** removes the
  quarantine flag (the same action as Maintenance ▸ Remove Quarantine) so the
  app launches normally.
- **Watch for Sept 1** — apps that fail one or more trust checks but don't have
  the quarantine flag right now. They run fine today, but a fresh download
  after Sept 1, 2026 could be blocked, so keep an eye on them.

Each row shows the specific check(s) that failed and the app's signing authority,
and you trust apps **one at a time** with a deliberate per-app **Trust** button —
there is intentionally no "Trust All."

### Settings
- **Appearance** — choose Light, Dark, or System (matches the quick toggle at the
  bottom of the sidebar). ForgedBrew opens in dark mode by default.
- **Load on startup** — open ForgedBrew automatically when you log in.
- **Keep in Dock** — show the icon (with an update-count badge) in the Dock, or
  hide it to keep the Dock clear.
- **Show in menu bar** — add a menu-bar icon with the update count; combined with
  launch-at-login, ForgedBrew can start quietly in the menu bar.
- **Self-updating apps** — optionally include apps that update themselves (Office,
  Chrome, Claude) in update checks.
- **App Locations** — choose which folders ForgedBrew scans for installed apps;
  the standard Applications folders are on by default, plus up to five custom
  folders.
- **APIs (optional)** — app screenshots come from each app's GitHub README and
  repository preview with no setup. You can optionally add a personal SerpApi key
  to also find screenshots for apps that don't publish one. The key is stored
  only on your Mac and is never bundled or shared.

### Polished & private
- Native SwiftUI app with a clean two-pane layout and a complete, built-in
  **User Manual** (searchable, with annotated wireframes of every screen). It
  appears automatically on first install and after each update via the Welcome
  window, and is always one click away from Settings ▸ About.
- Optional menu-bar mode that can start hidden at login.
- Automatic updates via Sparkle.
- Your data lives locally in `~/Library/Application Support/ForgedBrew/`.

---

## Requirements

- macOS (Apple Silicon).
- [Homebrew](https://brew.sh) — ForgedBrew will guide you if it isn't installed yet.

## Installing

1. Download **ForgedBrew.dmg** from the
   [latest release](https://github.com/HighfieldLondon/ForgedBrew/releases/latest).
2. Open the DMG and drag **ForgedBrew** into your **Applications** folder.
3. Double-click to launch.

> **First launch:** macOS will ask once — *"ForgedBrew was downloaded from the
> Internet. Are you sure you want to open it?"* — just click **Open**. This is
> normal and expected for any app downloaded from the web. Because ForgedBrew is
> signed with an Apple Developer ID and notarized by Apple, you get a simple
> one-click confirmation (not a security block), and macOS won't ask again after
> the first open.
>
> _(Heads up: starting **September 1, 2026**, Homebrew will stop clearing the
> quarantine flag from cask apps automatically — the change ForgedBrew's own
> Trust Management Screening helps you stay ahead of.)_

ForgedBrew is signed with an Apple Developer ID and **notarized by Apple**, so it
opens normally with a standard double-click — no right-click or security
workaround needed.

## Updates

ForgedBrew updates itself automatically using the Sparkle framework, checking a
signed appcast so you always have the latest version. You can also check on
demand from Settings ▸ General & Updates.

## Development & testing

ForgedBrew is a single-target SwiftUI app — open `ForgedBrew.xcodeproj` in Xcode
and build; no code generation or extra tooling required.

The correctness- and security-critical *pure* logic is covered by a unit-test
suite (Swift Testing) in `ForgedBrewTests/`, which I run locally before cutting a
release:

```sh
xcodebuild test -project ForgedBrew.xcodeproj -scheme ForgedBrew \
  -destination 'platform=macOS'
```

(or press ⌘U in Xcode). It currently covers version comparison (update
detection), the CVSS base-score calculator, terminal/ANSI output parsing, the
SSRF URL guard, and bundle install-date handling — the spots most prone to subtle
regressions. These run locally rather than in CI.

---

## About

ForgedBrew is developed by Highfield-London. Website: **ForgedBrew.com**.

Homebrew and the Homebrew logo are trademarks of the Homebrew project;
ForgedBrew is an independent GUI client and is not affiliated with or endorsed
by the Homebrew project.

© 2026 Highfield-London

## License

ForgedBrew is licensed under the Apache License 2.0.
See the [LICENSE](LICENSE) file for details.

© 2026 Highfield-London
