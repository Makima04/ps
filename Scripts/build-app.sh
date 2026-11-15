#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
python3 Scripts/prepare-models.py
swift build --disable-sandbox --configuration release --product Ps
build_bin_dir="$(swift build --disable-sandbox --configuration release --show-bin-path)"
app_bundle_dir="${1:-$PWD/.build/调色工作室.app}"

mkdir -p "$app_bundle_dir/Contents/MacOS"
cp "$build_bin_dir/Ps" "$app_bundle_dir/Contents/MacOS/Ps"
mkdir -p "$app_bundle_dir/Contents/Resources"
ditto "$build_bin_dir/Ps_ColorEngine.bundle" "$app_bundle_dir/Contents/Resources/Ps_ColorEngine.bundle"
cat > "$app_bundle_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Ps</string>
    <key>CFBundleIdentifier</key><string>local.ps.colorstudio</string>
    <key>CFBundleName</key><string>调色工作室</string>
    <key>CFBundleDisplayName</key><string>调色工作室</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app_bundle_dir"
echo "$app_bundle_dir"
