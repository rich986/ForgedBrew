#!/usr/bin/env bash
#
# release.sh — Full ForgedBrew release pipeline.
#
# Does everything in one command:
#   1. Reads the current version from the Xcode project
#   2. Archives + exports (Developer ID signed)
#   3. Notarizes the .app and staples the ticket
#   4. Packages into a DMG with an /Applications symlink
#   5. Verifies the DMG structure (no double-nesting)
#   6. Signs the DMG with Sparkle's EdDSA key
#   7. Prepends a new item to appcast.xml
#   8. Commits appcast.xml + the version bump, tags, pushes, and
#      creates a GitHub release with the DMG attached
#
# Usage:
#   ./scripts/release.sh [--notes "What changed in this release"]
#
# Requires:
#   • Xcode command-line tools
#   • `gh` (GitHub CLI) — `brew install gh` and `gh auth login`
#   • Sparkle sign_update (built automatically when you archive)
#   • notarytool credentials stored via:
#       xcrun notarytool store-credentials "ForgedBrew"

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
REPO_DIR="/Users/rich/Developer/ForgedBrew"
SCHEME="ForgedBrew"
PROJECT="$REPO_DIR/ForgedBrew.xcodeproj"
BUNDLE_ID="com.highfieldlondon.ForgedBrew"
KEYCHAIN_PROFILE="ForgedBrew"
GITHUB_REPO="HighfieldLondon/ForgedBrew"
VOLNAME="ForgedBrew"
EXPORT_OPTIONS="$REPO_DIR/scripts/ExportOptions.plist"

# ── Args ──────────────────────────────────────────────────────────────────────
NOTES=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --notes) NOTES="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
fail()  { red "ERROR: $*"; exit 1; }

# ── Read version from project ─────────────────────────────────────────────────
VERSION=$(grep "MARKETING_VERSION" "$PROJECT/project.pbxproj" | head -1 \
    | sed 's/.*MARKETING_VERSION = \(.*\);/\1/' | tr -d ' \t')
BUILD=$(grep "CURRENT_PROJECT_VERSION" "$PROJECT/project.pbxproj" | head -1 \
    | sed 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/' | tr -d ' \t')

[ -n "$VERSION" ] || fail "Could not read MARKETING_VERSION from project."
[ -n "$BUILD" ]   || fail "Could not read CURRENT_PROJECT_VERSION from project."

bold "==> ForgedBrew $VERSION (build $BUILD)"

# ── Release notes ─────────────────────────────────────────────────────────────
if [ -z "$NOTES" ]; then
    echo ""
    echo "Enter release notes (press Enter twice when done):"
    NOTES=""
    while IFS= read -r line; do
        [ -z "$line" ] && break
        NOTES="$NOTES$line "
    done
    NOTES="${NOTES%" "}"
fi
[ -n "$NOTES" ] || NOTES="Bug fixes and improvements."

# ── Paths ─────────────────────────────────────────────────────────────────────
BUILD_DIR="$REPO_DIR/build"
ARCHIVE="$BUILD_DIR/ForgedBrew.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/ForgedBrew.app"
DMG_PATH="$BUILD_DIR/ForgedBrew.dmg"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ── 1. Archive ────────────────────────────────────────────────────────────────
bold "==> Archiving (Release)…"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    | grep -E "^(==>|error:|warning: )" || true
[ -d "$ARCHIVE" ] || fail "Archive not found at $ARCHIVE"
green "    Archive complete."

# ── 2. Export (Developer ID signed) ──────────────────────────────────────────
bold "==> Exporting (Developer ID)…"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    | grep -E "^(==>|error:|warning: )" || true
[ -d "$APP_PATH" ] || fail "Exported app not found at $APP_PATH"
green "    Export complete."

# Confirm the exported app identity matches
EXPORTED_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$APP_PATH/Contents/Info.plist")
EXPORTED_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
    "$APP_PATH/Contents/Info.plist")
[ "$EXPORTED_ID" = "$BUNDLE_ID" ] \
    || fail "Bundle ID mismatch: got $EXPORTED_ID, expected $BUNDLE_ID"
[ "$EXPORTED_VER" = "$VERSION" ] \
    || fail "Version mismatch: app reports $EXPORTED_VER, project says $VERSION"

# ── 3. Notarize ───────────────────────────────────────────────────────────────
bold "==> Notarizing (this may take a few minutes)…"
APP_ZIP="$BUILD_DIR/ForgedBrew.zip"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait
rm -f "$APP_ZIP"
green "    Notarization accepted."

# ── 4. Staple ─────────────────────────────────────────────────────────────────
bold "==> Stapling notarization ticket…"
xcrun stapler staple "$APP_PATH"
green "    Stapled."

# ── 5. Verify signature + Gatekeeper ─────────────────────────────────────────
bold "==> Verifying app signature and Gatekeeper…"
codesign --verify --strict --verbose=2 "$APP_PATH" \
    || fail "codesign --verify failed on exported app."
spctl --assess --type execute --verbose=2 "$APP_PATH" 2>&1 | grep -q "accepted" \
    || fail "Gatekeeper did not accept the app — check notarization."
green "    Signature and Gatekeeper OK."

# ── 6. Package DMG ───────────────────────────────────────────────────────────
bold "==> Building DMG…"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP_PATH" "$STAGE/ForgedBrew.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO \
    "$DMG_PATH" >/dev/null
green "    DMG created: $DMG_PATH"

# Guard: verify structure is not double-nested
MNT="$(mktemp -d)"
hdiutil attach "$DMG_PATH" -nobrowse -mountpoint "$MNT" -quiet
cleanup_mnt() { hdiutil detach "$MNT" -quiet 2>/dev/null || true; }
trap 'cleanup_mnt; rm -rf "$STAGE"' EXIT

[ -f "$MNT/ForgedBrew.app/Contents/Info.plist" ] \
    || fail "DMG structure invalid — app is missing or double-nested."
codesign --verify --strict "$MNT/ForgedBrew.app" >/dev/null 2>&1 \
    || fail "App inside DMG failed codesign --verify."
cleanup_mnt
trap 'rm -rf "$STAGE"' EXIT
green "    DMG structure verified."

# ── 7. Sign DMG with Sparkle EdDSA ───────────────────────────────────────────
bold "==> Signing DMG with Sparkle…"
SIGN="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -name sign_update -type f 2>/dev/null | head -1)"
[ -n "$SIGN" ] || fail "sign_update not found in DerivedData. Build the app first."
SIG_LINE="$("$SIGN" "$DMG_PATH")"
DMG_LEN=$(stat -f%z "$DMG_PATH")
green "    Signed. Length: $DMG_LEN  Sig: $SIG_LINE"

# ── 8. Update appcast.xml ─────────────────────────────────────────────────────
bold "==> Updating appcast.xml…"
PUBDATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/ForgedBrew.dmg"

# Extract just the edSignature value from the sign_update output
ED_SIG=$(echo "$SIG_LINE" | sed 's/sparkle:edSignature="\([^"]*\)".*/\1/')

python3 - "$REPO_DIR/appcast.xml" <<PYEOF
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

new_item = """        <item>
            <title>Version $VERSION</title>
            <description><![CDATA[
                <h2>ForgedBrew $VERSION</h2>
                <p>$NOTES</p>
            ]]></description>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.6</sparkle:minimumSystemVersion>
            <enclosure
                url="$DOWNLOAD_URL"
                sparkle:version="$BUILD"
                sparkle:shortVersionString="$VERSION"
                length="$DMG_LEN"
                type="application/octet-stream"
                sparkle:edSignature="$ED_SIG" />
        </item>"""

# Insert after the opening <channel> block, before the first <item>
content = content.replace('<item>', new_item + '\n        <item>', 1)
with open(path, 'w') as f:
    f.write(content)
print("    appcast.xml updated.")
PYEOF

green "    appcast.xml updated."

# ── 9. Commit, tag, push, GitHub release ─────────────────────────────────────
bold "==> Committing and tagging v$VERSION…"
cd "$REPO_DIR"
git add ForgedBrew.xcodeproj/project.pbxproj appcast.xml
git commit -m "Release $VERSION: batch-update password fix"
git tag "v$VERSION"
git push origin main
git push origin "v$VERSION"
green "    Pushed."

bold "==> Creating GitHub release v$VERSION…"
gh release create "v$VERSION" "$DMG_PATH" \
    --repo "$GITHUB_REPO" \
    --title "v$VERSION" \
    --notes "$NOTES"
green "    GitHub release created."

green ""
green "══════════════════════════════════════════════"
green "  ForgedBrew $VERSION released successfully!"
green "══════════════════════════════════════════════"
echo  "  DMG:     $DMG_PATH"
echo  "  Tag:     v$VERSION"
echo  "  Release: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
