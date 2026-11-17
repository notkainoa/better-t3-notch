#!/bin/zsh
# Builds a release: signed app → DMG → notarized and stapled → Sparkle appcast. Output in dist/.
# Runs in CI (.github/workflows/release.yml) and locally, with the same inputs:
#   VERSION                 e.g. 0.3.0 (default: version.txt)
#   NOTARY_KEY_PATH         App Store Connect API key (.p8)
#   NOTARY_KEY_ID           its Key ID
#   NOTARY_ISSUER_ID        its Issuer ID
#   SPARKLE_KEY_FILE        Sparkle EdDSA private key, base64 (default: the login keychain item)
#   RELEASE_NOTES_HTML      optional file with this version's notes as HTML, shown in the update window
#   SKIP_NOTARIZE=1         sign and package only (for trying it out)
set -e
cd "$(dirname "$0")/.."

VERSION=${VERSION:-$(<version.txt)}
VERSION=${VERSION#v}
REPO=notkainoa/better-t3-notch
DMG_NAME=BetterT3Notch.dmg
DIST=dist
rm -rf $DIST && mkdir -p $DIST

RELEASE=1 VERSION=$VERSION ./build.sh
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Developer ID Application/ { print $2; exit }')}

# DMG: the app next to an Applications shortcut, so installing is one drag.
STAGE=$(mktemp -d)
ditto BetterT3Notch.app "$STAGE/Better T3 Notch.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Better T3 Notch" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov $DIST/$DMG_NAME
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" $DIST/$DMG_NAME

if [[ -z "$SKIP_NOTARIZE" ]]; then
  echo "Notarizing (usually 1–5 minutes)…"
  OUT=$(xcrun notarytool submit $DIST/$DMG_NAME --wait --output-format json \
    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  echo "$OUT"
  if [[ $(echo "$OUT" | plutil -extract status raw -o - -) != "Accepted" ]]; then
    ID=$(echo "$OUT" | plutil -extract id raw -o - -)
    xcrun notarytool log "$ID" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
    exit 1
  fi
  xcrun stapler staple $DIST/$DMG_NAME
  spctl --assess --type open --context context:primary-signature -vv $DIST/$DMG_NAME
fi

# Sparkle: sign the download and describe it in a one-item feed. The app reads the feed from
# releases/latest, so the newest release's appcast.xml is always the one that counts.
SIGN_UPDATE=$(find .build/artifacts -path '*Sparkle/bin/sign_update' | head -1)
if [[ -n "$SPARKLE_KEY_FILE" ]]; then
  ED=$($SIGN_UPDATE --ed-key-file "$SPARKLE_KEY_FILE" $DIST/$DMG_NAME)
else
  ED=$($SIGN_UPDATE $DIST/$DMG_NAME)
fi
NOTES=""
if [[ -n "$RELEASE_NOTES_HTML" && -s "$RELEASE_NOTES_HTML" ]]; then
  NOTES="<description><![CDATA[$(<$RELEASE_NOTES_HTML)]]></description>"
fi
cat > $DIST/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Better T3 Notch</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      $NOTES
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/$DMG_NAME" type="application/octet-stream" $ED/>
    </item>
  </channel>
</rss>
XML
echo "Release files in $PWD/$DIST:"
ls -lh $DIST
