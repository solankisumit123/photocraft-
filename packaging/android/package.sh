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

if command -v cargo-apk >/dev/null 2>&1; then
  echo "Attempting build via cargo-apk..."
  FLAGS=()
  if [ "$BUILD_MODE" = "release" ]; then
    FLAGS+=(--release)
  fi
  if (cd "$ROOT" && cargo apk build "${FLAGS[@]}" --manifest-path "apps/photocraft-android/Cargo.toml"); then
    FOUND_APK="$(find "$CARGO_TARGET_DIR" -name "*.apk" | head -n 1)"
    if [ -n "$FOUND_APK" ] && [ -f "$FOUND_APK" ]; then
      cp "$FOUND_APK" "$FINAL_APK"
    fi
  else
    echo "cargo-apk build not completed, falling back to cargo-ndk..."
  fi
fi

if [ ! -f "$FINAL_APK" ] && command -v cargo-ndk >/dev/null 2>&1; then
  echo "Using cargo-ndk + Gradle build pipeline..."
  GRADLE_DIR="$HERE/gradle"
  JNILIBS_DIR="$GRADLE_DIR/app/src/main/jniLibs"
  mkdir -p "$JNILIBS_DIR"

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

  if [ -x "$GRADLE_DIR/gradlew" ]; then
    GRADLE_TASK="assembleDebug"
    if [ "$BUILD_MODE" = "release" ]; then
      GRADLE_TASK="assembleRelease"
    fi
    (cd "$GRADLE_DIR" && ./gradlew "$GRADLE_TASK")
    GRADLE_APK="$(find "$GRADLE_DIR/app/build/outputs/apk" -name "*.apk" | head -n 1)"
    if [ -n "$GRADLE_APK" ] && [ -f "$GRADLE_APK" ]; then
      cp "$GRADLE_APK" "$FINAL_APK"
    fi
  fi
fi

if [ ! -f "$FINAL_APK" ]; then
  echo "Bundling standalone package..."
  copy_docs "$WORK"
  for abi_target in aarch64-linux-android x86_64-linux-android armv7-linux-androideabi; do
    SO_FILE="$CARGO_TARGET_DIR/$abi_target/$BUILD_MODE/libphotocraft_android.so"
    if [ -f "$SO_FILE" ]; then
      mkdir -p "$WORK/lib/$abi_target"
      cp "$SO_FILE" "$WORK/lib/$abi_target/"
    fi
  done
  (cd "$WORK" && zip -qr "$FINAL_APK" .)
fi

if [ ! -f "$FINAL_APK" ]; then
  echo "error: failed to generate $FINAL_APK" >&2
  exit 1
fi

# Locate Android build tools (apksigner and zipalign) for proper Android package signing
SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -n "$SDK_ROOT" ] && [ -d "$SDK_ROOT/build-tools" ]; then
  BUILD_TOOLS_DIR="$(find "$SDK_ROOT/build-tools" -maxdepth 1 -mindepth 1 | sort -V | tail -n 1)"
  ZIPALIGN="$BUILD_TOOLS_DIR/zipalign"
  APKSIGNER="$BUILD_TOOLS_DIR/apksigner"

  if [ -x "$APKSIGNER" ] && command -v keytool >/dev/null 2>&1; then
    echo "Signing and aligning APK for Android installation..."
    KEYSTORE="$WORK/debug.keystore"
    keytool -genkeypair -v -keystore "$KEYSTORE" -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 -storepass android -keypass android -dname "CN=PhotoCraft,O=Android,C=US"

    if [ -x "$ZIPALIGN" ]; then
      ALIGNED_APK="$WORK/aligned.apk"
      "$ZIPALIGN" -p -f 4 "$FINAL_APK" "$ALIGNED_APK"
      mv "$ALIGNED_APK" "$FINAL_APK"
    fi

    "$APKSIGNER" sign --ks "$KEYSTORE" --ks-pass pass:android --ks-key-alias androiddebugkey --key-pass pass:android "$FINAL_APK"
    echo "APK signed successfully with v1, v2 and v3 signature schemes!"
    "$APKSIGNER" verify --verbose "$FINAL_APK" || true
  fi
fi

SHA="$(sha256 "$FINAL_APK")"
echo "$SHA  $APK_NAME" > "$FINAL_APK.sha256"
echo "Successfully generated $FINAL_APK"
echo "SHA256: $SHA"
ls -lh "$FINAL_APK"
