#!/bin/zsh
# Builds BetterT3Notch.app (agent app: no Dock icon, no menu bar).
#   SIGN_IDENTITY=<sha1 or name>  sign with a specific certificate
#                                 (default: first "Apple Development", or "Developer ID Application" with RELEASE=1)
#   RELEASE=1                     universal (Apple silicon + Intel), Developer ID, secure timestamp, in-app updates on
#   VERSION=1.2.3                 version to stamp (default: version.txt)
set -e
cd "$(dirname "$0")"

VERSION=${VERSION:-$(<version.txt)}
VERSION=${VERSION#v}
# Sparkle's public key. The private half is the SPARKLE_ED_PRIVATE_KEY repo secret, backed up in the
# login keychain of the machine that made it (service https://sparkle-project.org, account ed25519).
SPARKLE_PUBLIC_KEY="xIp/RN4xP0g/2hVqwmLK7fLkXJeL7U3kYrey4295uRQ="
FEED_URL="https://github.com/notkainoa/better-t3-notch/releases/latest/download/appcast.xml"

if [[ -n "$RELEASE" ]]; then
  BUILD_ARGS=(-c release --arch arm64 --arch x86_64)
else
  BUILD_ARGS=(-c release)
fi
swift build $BUILD_ARGS
BIN=$(swift build $BUILD_ARGS --show-bin-path)

APP=BetterT3Notch.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources $APP/Contents/Frameworks
cp $BIN/BetterT3Notch $APP/Contents/MacOS/BetterT3Notch
ditto $BIN/Sparkle.framework $APP/Contents/Frameworks/Sparkle.framework
cp Resources/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
cp -R Resources/Logos $APP/Contents/Resources/Logos
cp -R Resources/Sounds $APP/Contents/Resources/Sounds

# Only release builds update themselves: a local build would otherwise replace itself with the download.
UPDATES=""
if [[ -n "$RELEASE" ]]; then
  UPDATES="<key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>"
fi
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Better T3 Notch</string>
  <key>CFBundleDisplayName</key><string>Better T3 Notch</string>
  <key>CFBundleIdentifier</key><string>me.kainoa.better-t3-notch</string>
  <key>CFBundleExecutable</key><string>BetterT3Notch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  $UPDATES
</dict></plist>
PLIST

# A stable identity keeps macOS's trust (Launch at Login, Keychain) across rebuilds;
# ad-hoc signatures change every build. Names can be ambiguous, so pick by SHA-1.
KIND=${RELEASE:+Developer ID Application}
KIND=${KIND:-Apple Development}
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -v k="\"$KIND" 'index($0, k) { print $2; exit }')}
if [[ -n "$RELEASE" && -z "$IDENTITY" ]]; then
  echo "RELEASE=1 needs a Developer ID Application certificate" >&2
  exit 1
fi

if [[ -n "$IDENTITY" ]]; then
  TS=${RELEASE:+--timestamp}
  TS=${TS:---timestamp=none}
  sign() { codesign --force --options runtime $TS --sign "$IDENTITY" "$@" >/dev/null }
  # Inside out: Sparkle's helpers first, then the framework, then the app.
  SP=$APP/Contents/Frameworks/Sparkle.framework/Versions/B
  sign $SP/XPCServices/Installer.xpc
  sign --preserve-metadata=entitlements $SP/XPCServices/Downloader.xpc
  sign $SP/Autoupdate
  sign $SP/Updater.app
  sign $APP/Contents/Frameworks/Sparkle.framework
  sign $APP
  echo "Signed with $(codesign -dvv $APP 2>&1 | awk -F= '/^Authority/ { print $2; exit }')"
else
  codesign --force --deep --sign - $APP >/dev/null
  echo "No signing certificate found; signed ad-hoc"
fi
echo "Built $PWD/$APP ($VERSION)"
