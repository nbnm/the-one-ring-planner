#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product TheOneRingPlanner
APP_DIR="$PWD/build/The One Ring Planner.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" build/AppIcon.iconset
cp .build/release/TheOneRingPlanner "$APP_DIR/Contents/MacOS/"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Sources/RingPlanner/Assets/OneRing.png "$APP_DIR/Contents/Resources/OneRing.png"
cp Sources/RingPlanner/Assets/EyeOfSauron.png "$APP_DIR/Contents/Resources/EyeOfSauron.png"
swift scripts/GenerateIcon.swift "$PWD/build/AppIcon-1024.png" "$PWD/Sources/RingPlanner/Assets/OneRing.png"
for n in 16 32 128 256 512; do
    sips -z "$n" "$n" build/AppIcon-1024.png --out "build/AppIcon.iconset/icon_${n}x${n}.png" >/dev/null
    double=$((n * 2))
    sips -z "$double" "$double" build/AppIcon-1024.png --out "build/AppIcon.iconset/icon_${n}x${n}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP_DIR/Contents/Resources/AppIcon.icns"
PLANNER_SIGNER=$(python3 scripts/setup-signing.py)
PLANNER_REQUIREMENT='=designated => identifier "com.t1a.the-one-ring-planner" and certificate leaf = H"'"$PLANNER_SIGNER"'"'
codesign --force --sign "$PLANNER_SIGNER" --timestamp=none --requirements "$PLANNER_REQUIREMENT" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
printf '%s\n' "Built: $APP_DIR"
if [[ "${1:-}" == "--install" ]]; then
    INSTALL_DIR="$HOME/Applications/The One Ring Planner.app"
    mkdir -p "$HOME/Applications"
    if pgrep -f '^.*/TheOneRingPlanner($| )' >/dev/null; then
        printf '%s\n' 'Quit the running planner first, then rerun with --install. Recordings and processing are never stopped by this script.' >&2
        exit 1
    fi
    ditto "$APP_DIR" "$INSTALL_DIR"
    open "$INSTALL_DIR"
    printf '%s\n' "Installed and launched: $INSTALL_DIR"
fi
