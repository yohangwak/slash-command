#!/bin/sh
# Builds the release zip: a universal app, signed with Developer ID, notarized and stapled.
#
#   scripts/release.sh                 build, sign, notarize, staple, zip → dist/Slash-Command.zip
#   scripts/release.sh --no-notarize   stop after signing (to check the build without Apple's service)
#
# Needs, in the login keychain of this Mac:
#   - a "Developer ID Application" certificate (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates)
#   - a notarytool profile:  xcrun notarytool store-credentials slashcommand-notary
# Set SLASHCOMMAND_SIGN_IDENTITY or SLASHCOMMAND_NOTARY_PROFILE to use other names.
# Run it in a login session: over ssh the keychain is locked and codesign fails with errSecInternalComponent.
set -eu
cd "$(dirname "$0")/.."

notarize=yes
[ "${1:-}" = "--no-notarize" ] && notarize=no
profile=${SLASHCOMMAND_NOTARY_PROFILE:-slashcommand-notary}
identity=${SLASHCOMMAND_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
[ -n "$identity" ] || { echo "release: no Developer ID Application certificate in the keychain" >&2; exit 1; }

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" scripts/Info.plist)
grep -q "^## $version\$" CHANGELOG.md || { echo "release: CHANGELOG.md has no section for $version" >&2; exit 1; }

SLASHCOMMAND_UNIVERSAL=1 SLASHCOMMAND_SIGN_IDENTITY="$identity" ./scripts/build-app.sh

app="dist/Slash Command.app"
zip="dist/Slash-Command.zip"
for binary in SlashCommand slashcommand-cli; do
    archs=$(lipo -archs "$app/Contents/MacOS/$binary")
    case "$archs" in *arm64*x86_64*|*x86_64*arm64*) ;; *) echo "release: $binary is not universal ($archs)" >&2; exit 1;; esac
done
codesign --verify --deep --strict "$app"

rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
if [ "$notarize" = yes ]; then
    xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
    xcrun stapler staple "$app"
    # The stapled ticket is part of the bundle, so zip again.
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    spctl --assess --type execute -vv "$app"
fi

echo "release: $zip  (version $version, sha256 $(shasum -a 256 "$zip" | cut -d' ' -f1))"
[ "$notarize" = yes ] && echo "publish: gh release create v$version $zip --title \"Slash Command $version\" --notes-file <notes>"
exit 0
