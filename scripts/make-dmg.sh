#!/bin/sh
# Packs a signed app into a signed disk image that shows the app next to an Applications link.
#
#   scripts/make-dmg.sh <app> <dmg>              sign the image
#   scripts/make-dmg.sh <app> <dmg> --notarize   also notarize and staple it
#
# The app must already be signed (and, for a release, notarized and stapled): the image only carries it.
# Uses the same certificate and notarytool profile as release.sh.
set -eu

app="$1"
dmg="$2"
notarize="${3:-}"
identity=${SLASHCOMMAND_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
profile=${SLASHCOMMAND_NOTARY_PROFILE:-slashcommand-notary}
[ -n "$identity" ] || { echo "make-dmg: no Developer ID Application certificate in the keychain" >&2; exit 1; }
[ -d "$app" ] || { echo "make-dmg: no app at $app" >&2; exit 1; }

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/$(basename "$app")"
ln -s /Applications "$stage/Applications"

rm -f "$dmg"
hdiutil create -quiet -volname "Slash Command" -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"
if [ "$notarize" = --notarize ]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
    # Fails unless Apple accepted the image, so a rejected submission stops here.
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature -vv "$dmg"
fi
