#!/bin/bash
#
# Sign bundled executables and dylibs for distribution
#
# Usage:
#   ./sign-bundled-binaries.sh                    # Uses Apple Development cert
#   ./sign-bundled-binaries.sh "Developer ID Application: Your Name (TEAMID)"
#
# For Mac App Store: Use Xcode's automatic signing
# For Direct Download: Get "Developer ID Application" cert from developer.apple.com
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOURCES_DIR="$SCRIPT_DIR/P2toMXF/Resources"

# Default to Apple Development cert if no argument provided
if [ -n "$1" ]; then
    IDENTITY="$1"
else
    # Use SHA-1 hash to avoid ambiguity with revoked certs
    IDENTITY="2D26CB1211F32FD4E3C6EF413EC1EDD6F30631AA"
fi

echo "Signing with identity: $IDENTITY"
echo ""

# Entitlements for bundled tools (they need these to run under hardened runtime)
ENTITLEMENTS=$(mktemp)
cat > "$ENTITLEMENTS" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
EOF

echo "=== Signing dylibs ==="
for dylib in "$RESOURCES_DIR/lib/"*.dylib; do
    echo "  Signing $(basename "$dylib")"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$dylib"
done

echo ""
echo "=== Signing executables ==="
for exe in bmxtranswrap mxf2raw; do
    echo "  Signing $exe"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" \
        --entitlements "$ENTITLEMENTS" "$RESOURCES_DIR/$exe"
done

# FFmpeg already has hardened runtime, but resign with your identity
echo "  Signing ffmpeg"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS" "$RESOURCES_DIR/ffmpeg"

rm "$ENTITLEMENTS"

echo ""
echo "=== Verification ==="
for file in "$RESOURCES_DIR/ffmpeg" "$RESOURCES_DIR/bmxtranswrap" "$RESOURCES_DIR/mxf2raw" "$RESOURCES_DIR/lib/"*.dylib; do
    name=$(basename "$file")
    flags=$(codesign -dv "$file" 2>&1 | grep "flags=" | sed 's/.*flags=//')
    team=$(codesign -dv "$file" 2>&1 | grep "TeamIdentifier=" | sed 's/.*TeamIdentifier=//')
    echo "  $name: flags=$flags team=$team"
done

echo ""
echo "Done! All binaries signed with Hardened Runtime."
echo ""
echo "Next steps:"
echo "  1. In Xcode: Build Settings > Enable Hardened Runtime = YES"
echo "  2. Build the app"
echo "  3. For notarization: xcrun notarytool submit ..."
