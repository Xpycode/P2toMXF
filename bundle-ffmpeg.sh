#!/bin/bash
# Script to bundle FFmpeg into the P2toMXF app
#
# Usage: ./bundle-ffmpeg.sh [path-to-ffmpeg]
#
# If no path is provided, it will try to find FFmpeg in common locations.

set -e

APP_NAME="P2toMXF"
RESOURCES_DIR="$APP_NAME/$APP_NAME/Resources"

# Find FFmpeg
if [ -n "$1" ]; then
    FFMPEG_PATH="$1"
elif [ -x "/opt/homebrew/bin/ffmpeg" ]; then
    FFMPEG_PATH="/opt/homebrew/bin/ffmpeg"
elif [ -x "/usr/local/bin/ffmpeg" ]; then
    FFMPEG_PATH="/usr/local/bin/ffmpeg"
else
    echo "Error: FFmpeg not found. Please install it via Homebrew:"
    echo "  brew install ffmpeg"
    echo ""
    echo "Or provide the path as an argument:"
    echo "  ./bundle-ffmpeg.sh /path/to/ffmpeg"
    exit 1
fi

echo "Found FFmpeg at: $FFMPEG_PATH"
echo "FFmpeg version: $($FFMPEG_PATH -version | head -1)"
echo ""

# Create Resources directory if it doesn't exist
mkdir -p "$RESOURCES_DIR"

# Copy FFmpeg binary
echo "Copying FFmpeg to $RESOURCES_DIR..."
cp "$FFMPEG_PATH" "$RESOURCES_DIR/ffmpeg"
chmod +x "$RESOURCES_DIR/ffmpeg"

echo ""
echo "Done! FFmpeg has been bundled."
echo ""
echo "Note: For App Store distribution, you'll need to:"
echo "  1. Use a static FFmpeg build (no dynamic library dependencies)"
echo "  2. Codesign the FFmpeg binary with your Developer ID"
echo ""
echo "For local development, the app will also try to use:"
echo "  - /opt/homebrew/bin/ffmpeg (Apple Silicon)"
echo "  - /usr/local/bin/ffmpeg (Intel)"
