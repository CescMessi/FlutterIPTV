#!/bin/bash
# ==============================================================================
# Patch media_kit_libs_android_video build.gradle to use FULL FFmpeg variant.
#
# The default FFmpeg build strips many audio decoders (including E-AC-3).
# The full variant includes all codecs needed for E-AC-3 / Dolby Digital Plus.
# ==============================================================================
set -euo pipefail

echo "=== Patching media_kit_libs_android_video to use full FFmpeg variant ==="

# Find the build.gradle in the pub cache
BUILD_GRADLE=$(find ~/.pub-cache -path "*/media_kit_libs_android_video*/android/build.gradle" 2>/dev/null | head -1)

if [ -z "$BUILD_GRADLE" ]; then
  echo "ERROR: media_kit_libs_android_video build.gradle not found in pub cache."
  echo "Run 'flutter pub get' first, or check ~/.pub-cache/hosted/pub.dev/"
  exit 1
fi

echo "Found: $BUILD_GRADLE"

# Verify the file contains the expected default variant URLs
if ! grep -q "default-arm64-v8a.jar" "$BUILD_GRADLE"; then
  echo "ERROR: build.gradle does not contain expected default-arm64-v8a.jar references."
  echo "The file may already be patched or is an unexpected version."
  exit 1
fi

# Patch: v1.1.7 -> v1.1.11, default-* -> full-*, and update MD5 checksums
# Full variant JAR MD5s (from v1.1.11 release):
#   full-arm64-v8a.jar:   86f2c8faeb66af1878b3a16f67831cb3
#   full-armeabi-v7a.jar: 93542d40e44f3afad3aa773674e8eaa5
#   full-x86_64.jar:      44b7efdbaf3626d6b24afaf5d497a369
#   full-x86.jar:         e69a9bbd7fb587deb33dd10fecc2fecc

sed -i \
  -e 's|default-arm64-v8a.jar|full-arm64-v8a.jar|g' \
  -e 's|default-armeabi-v7a.jar|full-armeabi-v7a.jar|g' \
  -e 's|default-x86_64.jar|full-x86_64.jar|g' \
  -e 's|default-x86.jar|full-x86.jar|g' \
  -e 's|v1\.1\.7/|v1.1.11/|g' \
  -e 's|"83df25b61193af8fa815e373143ac9af"|"86f2c8faeb66af1878b3a16f67831cb3"|g' \
  -e 's|"22e21526fefc0a2b8f17adbec9f57590"|"93542d40e44f3afad3aa773674e8eaa5"|g' \
  -e 's|"6fa26bf0459b11f1c0b0dbc29e5b940d"|"44b7efdbaf3626d6b24afaf5d497a369"|g' \
  -e 's|"0d742b756dc9d1fcd84ea271d8b68f32"|"e69a9bbd7fb587deb33dd10fecc2fecc"|g' \
  "$BUILD_GRADLE"

echo "Patch applied successfully."

# Clean the Gradle build cache for this module so jars are re-downloaded.
# The module output directory is inside the Gradle build cache.
echo "Cleaning Gradle build cache for media_kit_libs_android_video..."
MODULE_DIR=$(dirname "$(dirname "$BUILD_GRADLE")")
GRADLE_BUILD_DIR="$MODULE_DIR/.gradle"
if [ -d "$GRADLE_BUILD_DIR" ]; then
  rm -rf "$GRADLE_BUILD_DIR"
  echo "Cleaned: $GRADLE_BUILD_DIR"
fi

# Also clean any build/ directory inside the module
if [ -d "$MODULE_DIR/build" ]; then
  rm -rf "$MODULE_DIR/build"
  echo "Cleaned: $MODULE_DIR/build"
fi

echo "=== Patch complete ==="
