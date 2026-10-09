#!/usr/bin/env bash
# Build PhotoCraft for Android: produces $DIST/photocraft-android-<version>.apk
#
# Usage: packaging/android/package.sh [--release|--debug]
#
# Requirements:
# - Android SDK (ANDROID_HOME or ANDROID_SDK_ROOT)
# - Android NDK (ANDROID_NDK_HOME, ANDROID_NDK_ROOT, or in $ANDROID_HOME/ndk/)
# - Rust targets: aarch64-linux-android, and optionally x86_64-linux-android
set -euo pipefail
# shellcheck source=../env.sh
. "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
HERE="$ROOT/packaging/android"

BUILD_MODE="release"
for arg in "$@"; do
  case "$arg" in
    --debug) BUILD_MODE="debug" ;;
    --release) BUILD_MODE="release" ;;
    *) ;;
  esac
done

if [ -n "${BUILD_TYPE:-}" ]; then
  BUILD_MODE="$BUILD_TYPE"
fi

echo "Building PhotoCraft Android APK ($BUILD_MODE mode)..."

mkdir -p "$DIST"
WORK="$CARGO_TARGET_DIR/android-package"
rm -rf "$WORK"
mkdir -p "$WORK"

APK_NAME="photocraft-android-$VERSION.apk"
FINAL_APK="$DIST/$APK_NAME"

GRADLE_DIR="$HERE/gradle"
JNILIBS_DIR="$GRADLE_DIR/app/src/main/jniLibs"
mkdir -p "$JNILIBS_DIR"

# 1. Compile native libraries via cargo-ndk
if command -v cargo-ndk >/dev/null 2>&1; then
  echo "Compiling native libraries using cargo-ndk..."
  TARGETS=("aarch64-linux-android" "x86_64-linux-android")
  CARGO_FLAGS=()
  if [ "$BUILD_MODE" = "release" ]; then
    CARGO_FLAGS+=(--release)
  fi

  for tgt in "${TARGETS[@]}"; do
    if rustup target list --installed | grep -q "^$tgt$"; then
      echo "Compiling for $tgt..."
      cargo ndk -t "$tgt" -o "$JNILIBS_DIR" build -p photocraft-android "${CARGO_FLAGS[@]}"
    else
      warn "Rust target $tgt is not installed, skipping"
    fi
  done
fi

# 2. Package APK using Gradle (primary pipeline)
GRADLE_CMD=""
if [ -x "$GRADLE_DIR/gradlew" ]; then
  GRADLE_CMD="./gradlew"
elif command -v gradle >/dev/null 2>&1; then
  GRADLE_CMD="gradle"
fi

if [ -n "$GRADLE_CMD" ]; then
  echo "Building APK with Gradle ($GRADLE_CMD)..."
  GRADLE_TASK="assembleDebug"
  if [ "$BUILD_MODE" = "release" ]; then
    GRADLE_TASK="assembleRelease"
  fi
  (cd "$GRADLE_DIR" && $GRADLE_CMD "$GRADLE_TASK" --no-daemon)
  GRADLE_APK="$(find "$GRADLE_DIR/app/build/outputs/apk" -name "*.apk" | head -n 1)"
  if [ -n "$GRADLE_APK" ] && [ -f "$GRADLE_APK" ]; then
    echo "Found Gradle APK: $GRADLE_APK"
    cp "$GRADLE_APK" "$FINAL_APK"
  fi
fi

# 3. Fallback: package APK using Android SDK build-tools (aapt2) if Gradle was not available
SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
BUILD_TOOLS_DIR=""
if [ -n "$SDK_ROOT" ] && [ -d "$SDK_ROOT/build-tools" ]; then
  BUILD_TOOLS_DIR="$(find "$SDK_ROOT/build-tools" -maxdepth 1 -mindepth 1 | sort -V | tail -n 1)"
fi

if [ ! -f "$FINAL_APK" ] && [ -n "$SDK_ROOT" ] && [ -n "$BUILD_TOOLS_DIR" ]; then
  echo "Assembling APK via Android SDK aapt2 pipeline..."
  PLATFORM_JAR="$(find "$SDK_ROOT/platforms" -name "android.jar" | sort -V | tail -n 1)"
  AAPT2="$BUILD_TOOLS_DIR/aapt2"
  MANIFEST="$ROOT/apps/photocraft-android/AndroidManifest.xml"
  RES_DIR="$ROOT/apps/photocraft-android/res"

  if [ -f "$PLATFORM_JAR" ] && [ -x "$AAPT2" ] && [ -f "$MANIFEST" ]; then
    mkdir -p "$WORK/compiled_res"
    "$AAPT2" compile --dir "$RES_DIR" -o "$WORK/compiled_res.zip" || true
    LINK_ARGS=()
    if [ -f "$WORK/compiled_res.zip" ]; then
      LINK_ARGS+=("$WORK/compiled_res.zip")
    fi
    "$AAPT2" link -I "$PLATFORM_JAR" --manifest "$MANIFEST" "${LINK_ARGS[@]}" -o "$WORK/base.apk"
    
    mkdir -p "$WORK/apk_content/lib"
    cp -r "$JNILIBS_DIR/." "$WORK/apk_content/lib/" 2>/dev/null || true
    (cd "$WORK/apk_content" && zip -ur "$WORK/base.apk" lib)
    cp "$WORK/base.apk" "$FINAL_APK"
  fi
fi

if [ ! -f "$FINAL_APK" ]; then
  echo "error: failed to generate $FINAL_APK" >&2
  exit 1
fi

# 4. Sign and align APK if not already signed
if [ -n "$BUILD_TOOLS_DIR" ]; then
  ZIPALIGN="$BUILD_TOOLS_DIR/zipalign"
  APKSIGNER="$BUILD_TOOLS_DIR/apksigner"

  if [ -x "$APKSIGNER" ] && command -v keytool >/dev/null 2>&1; then
    # Check if APK is already signed
    if ! "$APKSIGNER" verify "$FINAL_APK" >/dev/null 2>&1; then
      echo "Signing APK with apksigner..."
      KEYSTORE="$WORK/debug.keystore"
      keytool -genkeypair -v -keystore "$KEYSTORE" -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 -storepass android -keypass android -dname "CN=PhotoCraft,O=Android,C=US"

      if [ -x "$ZIPALIGN" ]; then
        ALIGNED_APK="$WORK/aligned.apk"
        "$ZIPALIGN" -p -f 4 "$FINAL_APK" "$ALIGNED_APK"
        mv "$ALIGNED_APK" "$FINAL_APK"
      fi

      "$APKSIGNER" sign --ks "$KEYSTORE" --ks-pass pass:android --ks-key-alias androiddebugkey --key-pass pass:android "$FINAL_APK"
    fi
    echo "APK verification:"
    "$APKSIGNER" verify --verbose "$FINAL_APK" || true
  fi
fi

SHA="$(sha256 "$FINAL_APK")"
echo "$SHA  $APK_NAME" > "$FINAL_APK.sha256"
echo "Successfully generated $FINAL_APK"
echo "SHA256: $SHA"
ls -lh "$FINAL_APK"
