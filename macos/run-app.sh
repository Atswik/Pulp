#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -j 4
products="$PWD/.build/out/Products/Debug"
mkdir -p "$PWD/build"
stage="$(mktemp -d "$PWD/build/.notes-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Pulp.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$products/Pulp" "$app/Contents/MacOS/Pulp"
rm -f "$app/Contents/MacOS/libpdfium.dylib"
cp "$products/libpdfium.dylib" "$app/Contents/MacOS/libpdfium.dylib"
for bundle in "$products"/*.bundle; do rm -rf "$app/Contents/Resources/$(basename "$bundle")"; cp -R "$bundle" "$app/Contents/Resources/"; done
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Pulp</string>
<key>CFBundleIdentifier</key><string>local.pulp.dev</string>
<key>CFBundleName</key><string>Pulp</string>
<key>CFBundleDisplayName</key><string>Pulp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app"
rm -rf "$PWD/build/Pulp.app"
mv "$app" "$PWD/build/Pulp.app"
app="$PWD/build/Pulp.app"
if [[ "${1:-}" == "--build-only" ]]; then
  exit 0
fi
if [[ -n "${NOTES_MODEL_DIR:-}" ]]; then
  open -n "$app" --env "NOTES_MODEL_DIR=$NOTES_MODEL_DIR"
else
  open -n "$app"
fi
