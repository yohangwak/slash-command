#!/bin/sh
# Builds "Slash Command.app" into dist/. With `--install`, copies it to ~/Applications and relaunches it.
set -eu
cd "$(dirname "$0")/.."

# With SLASHCOMMAND_UNIVERSAL=1, builds an executable containing both Apple silicon and Intel (for releases; Xcode is required).
if [ "${SLASHCOMMAND_UNIVERSAL:-}" = 1 ]; then
    swift build -c release --arch arm64 --arch x86_64
    bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
else
    swift build -c release
    bin=$(swift build -c release --show-bin-path)
fi

app="dist/Slash Command.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/SlashCommandApp" "$app/Contents/MacOS/SlashCommand"
# The default macOS file system is case-insensitive, so naming it `slashcommand` would overwrite the `SlashCommand` above.
cp "$bin/slashcommand" "$app/Contents/MacOS/slashcommand-cli"
cp scripts/Info.plist "$app/Contents/Info.plist"
# The icon is regenerated with scripts/make-icon.swift.
mkdir -p "$app/Contents/Resources"
cp scripts/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# Translations: Resources/<language>.lproj is copied in as is. The system looks at these folders to choose the app's language (it also shows up in per-app language settings).
cp -R Resources/*.lproj "$app/Contents/Resources/"

# If a development certificate is present, sign with it, so the Ghostty control permission (Automation) is kept across rebuilds.
# Without one it falls back to ad-hoc signing, and then the permission is asked again on every build.
# The certificate can be set with SLASHCOMMAND_SIGN_IDENTITY (releases use "Developer ID Application: …", see scripts/release.sh).
identity=${SLASHCOMMAND_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}
if [ -n "$identity" ]; then
    # When signing with a certificate, turn on the Hardened Runtime (a notarization requirement; it also makes development builds run under the same conditions as releases).
    # The command-line tool inside must be signed separately: signing the bundle does not sign that file again.
    for item in "$app/Contents/MacOS/slashcommand-cli" "$app"; do
        codesign --force --options runtime --timestamp --entitlements scripts/SlashCommand.entitlements --sign "$identity" "$item"
    done
else
    codesign --force --sign - "$app"
fi
echo "Signing: ${identity:-ad-hoc}"

if [ "${1:-}" = "--install" ]; then
    dest="$HOME/Applications/Slash Command.app"
    mkdir -p "$HOME/Applications"
    osascript -e 'tell application id "com.yohangwak.slashcommand" to quit' >/dev/null 2>&1 || true
    rm -rf "$dest"
    cp -R "$app" "$dest"
    # Link it so it can be used as `slashcommand` from a terminal too (if another file is already there, leave it alone).
    link="$HOME/.local/bin/slashcommand"
    if [ -d "$HOME/.local/bin" ] && { [ -L "$link" ] || [ ! -e "$link" ]; }; then
        ln -sf "$dest/Contents/MacOS/slashcommand-cli" "$link"
    fi
    # Reopening an app that was just quit sometimes fails (-600). Wait a moment and open it once more.
    open "$dest" 2>/dev/null || { sleep 2; open "$dest"; }
    echo "Installed: $dest"
else
    echo "Done: $app"
fi
