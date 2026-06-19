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
- **Mac Store / Other Apps** — ForgedBrew also surfaces updates for apps
  *outside* Homebrew, so you have one place to keep your whole Mac current.

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

1. Download **ForgedBrew-2.3.2.dmg** from the
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
