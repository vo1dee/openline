#!/bin/bash
# Builds pinned Opus and PJSIP static libraries for arm64 macOS and packages
# them as Vendor/CPJSIP.xcframework. Idempotent: delete Vendor/ to rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
SRC="$VENDOR/src"
PREFIX="$VENDOR/install"
# Separate prefix: --with-opus puts it on the include path, where a previous
# PJSIP install would shadow the current config_site.h.
OPUS_PREFIX="$VENDOR/opus"
OUT="$VENDOR/CPJSIP.xcframework"

PJSIP_VERSION=2.17
PJSIP_SHA256=065fe06c06788d97c35f563796d59f00ce52fe9558a52d7b490a042a966facce
PJSIP_URL="https://github.com/pjsip/pjproject/archive/refs/tags/$PJSIP_VERSION.tar.gz"
OPUS_VERSION=1.6.1
OPUS_SHA256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
OPUS_URL="https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz"

export MACOSX_DEPLOYMENT_TARGET=27.0
export CC="$(xcrun -f clang)" CXX="$(xcrun -f clang++)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
FLAGS="-arch arm64 -isysroot $SDK -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -O2 -g -DNDEBUG"
JOBS="$(sysctl -n hw.ncpu)"

if [ -d "$OUT" ] && [ "${1:-}" != "--force" ]; then
    echo "$OUT already built; pass --force to rebuild"
    exit 0
fi

fetch() { # url sha256 dest
    [ -f "$3" ] || curl -fsSL -o "$3" "$1"
    echo "$2  $3" | shasum -a 256 -c - >/dev/null
}

rm -rf "$PREFIX" "$OPUS_PREFIX"
mkdir -p "$SRC" "$PREFIX" "$OPUS_PREFIX"
fetch "$PJSIP_URL" "$PJSIP_SHA256" "$SRC/pjproject-$PJSIP_VERSION.tar.gz"
fetch "$OPUS_URL" "$OPUS_SHA256" "$SRC/opus-$OPUS_VERSION.tar.gz"

echo "==> Opus $OPUS_VERSION"
rm -rf "$SRC/opus-$OPUS_VERSION"
tar xzf "$SRC/opus-$OPUS_VERSION.tar.gz" -C "$SRC"
(
    cd "$SRC/opus-$OPUS_VERSION"
    CFLAGS="$FLAGS" ./configure --host=aarch64-apple-darwin --prefix="$OPUS_PREFIX" \
        --disable-shared --enable-static --disable-doc --disable-extra-programs >/dev/null
    make -j"$JOBS" install >/dev/null
)

echo "==> PJSIP $PJSIP_VERSION"
rm -rf "$SRC/pjproject-$PJSIP_VERSION"
tar xzf "$SRC/pjproject-$PJSIP_VERSION.tar.gz" -C "$SRC"
PJ="$SRC/pjproject-$PJSIP_VERSION"
cp "$ROOT/scripts/config_site.h" "$PJ/pjlib/include/pj/config_site.h"
(
    cd "$PJ"
    CFLAGS="$FLAGS" CXXFLAGS="$FLAGS -std=c++17" LDFLAGS="-arch arm64 -isysroot $SDK" \
    ./configure --host=aarch64-apple-darwin --prefix="$PREFIX" \
        --with-opus="$OPUS_PREFIX" \
        --disable-video --disable-libyuv --disable-sdl --disable-ffmpeg \
        --disable-v4l2 --disable-openh264 --disable-vpx --disable-upnp \
        --disable-gsm-codec --disable-speex-codec --disable-ilbc-codec \
        --disable-g7221-codec --disable-opencore-amr --disable-silk \
        --disable-bcg729 --disable-lyra --disable-android-mediacodec \
        --disable-darwin-ssl --disable-ssl \
        --disable-speex-aec --enable-libwebrtc-aec3 >"$PREFIX/pjsip-configure.log"
    make dep -j"$JOBS" >/dev/null 2>&1
    make lib -j"$JOBS" >"$PREFIX/pjsip-make.log" 2>&1
    make install >/dev/null 2>&1
)

echo "==> Packaging"
MERGED="$VENDOR/build"
rm -rf "$MERGED" "$OUT"
mkdir -p "$MERGED"
libtool -static -no_warning_for_no_symbols -o "$MERGED/libCPJSIP.a" "$PREFIX"/lib/*.a "$OPUS_PREFIX/lib/libopus.a"
cp -R "$PREFIX/include" "$MERGED/Headers"
cat >"$MERGED/Headers/module.modulemap" <<'EOF'
module CPJSIP [system] {
    header "pjsua-lib/pjsua.h"
    export *
}
EOF
xcodebuild -create-xcframework -library "$MERGED/libCPJSIP.a" -headers "$MERGED/Headers" -output "$OUT" >/dev/null
echo "Built $OUT"
