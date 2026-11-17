#!/bin/zsh
# Regenerates the README screenshots (docs/screenshots/*.png) and the website's (site/assets/*.jpg)
# from demo data. It captures only the notch's own window and your desktop picture, so windows and
# menu-bar items never end up in them, then puts the notch over the top-center of the desktop
# picture (scripts/compose-screenshots.py, needs Pillow).
#   ./build.sh && ./scripts/screenshots.sh
set -e
cd "$(dirname "$0")/.."
APP=$PWD/BetterT3Notch.app
RAW=$(mktemp -d)
DOMAIN=me.kainoa.better-t3-notch
trap 'rm -rf "$RAW"' EXIT

# The notch's window id, or with "wallpaper" the desktop picture behind it (the Dock draws one
# window per display; this picks the one the notch is on).
cat > "$RAW/winid.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
func rect(_ w: [String: Any]) -> CGRect { CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary) ?? .null }
guard let notch = list.first(where: { ($0[kCGWindowOwnerName as String] as? String) == "Better T3 Notch"
    && ($0[kCGWindowLayer as String] as? Int) == 27 }) else { exit(1) }
if CommandLine.arguments.count > 1 {
    let center = CGPoint(x: rect(notch).midX, y: 1)
    let wall = list.first { ($0[kCGWindowOwnerName as String] as? String) == "Dock"
        && (($0[kCGWindowName as String] as? String) ?? "").hasPrefix("Wallpaper-") && rect($0).contains(center) }
    guard let wall else { exit(1) }
    let r = rect(wall)
    print(wall[kCGWindowNumber as String]!, Int(rect(notch).midX - r.minX))
} else {
    print(notch[kCGWindowNumber as String]!)
}
SWIFT
swiftc -o "$RAW/winid" "$RAW/winid.swift" 2>/dev/null

previous=$(defaults read $DOMAIN displayChoice 2>/dev/null || echo "")
defaults write $DOMAIN displayChoice builtin

shot() { # name, env...
  local name=$1; shift
  pkill -f "$APP/Contents/MacOS" 2>/dev/null || true; sleep 1.5
  open -g -n --env T3NOTCH_ALLOW_CAPTURE=1 "$@" "$APP"
  sleep 6 # let the springs settle
  screencapture -x -o -l "$("$RAW/winid")" "$RAW/$name.png"
  echo "captured $name"
}

shot compact --env T3NOTCH_DEMO=list
# Your desktop picture, captured on its own (no windows or menu bar), as the backdrop.
read WALL CENTER < <("$RAW/winid" wallpaper)
screencapture -x -o -l "$WALL" "$RAW/wallpaper.png"
echo "$CENTER" > "$RAW/wallpaper-center.txt"
shot expanded --env T3NOTCH_DEMO=list --env T3NOTCH_FORCE_EXPANDED=1
shot approval --env T3NOTCH_DEMO=approval
shot question --env T3NOTCH_DEMO=question
shot finished --env T3NOTCH_DEMO=finished
pkill -f "$APP/Contents/MacOS" 2>/dev/null || true

if [[ -n "$previous" ]]; then defaults write $DOMAIN displayChoice "$previous"; else defaults delete $DOMAIN displayChoice; fi
python3 scripts/compose-screenshots.py "$RAW"
