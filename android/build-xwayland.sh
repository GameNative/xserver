#!/usr/bin/env bash
# build-xwayland.sh — NDK cross-build of Xwayland for GameNative.
#
# Produces: build-android/hw/xwayland/Xwayland
#
# Android support is carried directly in this tree (source of truth), derived
# from the termux-packages x11-packages/xwayland recipe with the runtime
# payload prefix substituted. There is no patch train to apply: the Android
# changes are committed in os/ (access, backtrace, osinit, utils), xkb/
# (ddxLoad), Xext/shm.c (ashmem) and hw/xwayland/ (shm + glamor).
#
# Env overrides:
#   GN_XWAYLAND_NDK         Android NDK root (default: $HOME/Android/Sdk/ndk/27.3.13750724)
#   GN_XWAYLAND_DEPS_PREFIX  build-time aarch64 sysroot (default: termux prefix)
#   GN_XWAYLAND_PREFIX       on-device runtime prefix (default: app filesDir)

set -euo pipefail

XS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="${GN_XWAYLAND_DEPS_PREFIX:-$HOME/termuxfs/aarch64/data/data/com.termux/files/usr}"
RUNTIME="${GN_XWAYLAND_PREFIX:-/data/user/0/app.gamenative/files/gamescope}"
NDK="${GN_XWAYLAND_NDK:-$HOME/Android/Sdk/ndk/27.3.13750724}"
NDK_BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"

# --- cross file ---------------------------------------------------------------
# android/cross/aarch64-linux-android.txt is generated from the committed .txt.in
# template and the settings above, so no absolute path is stored in the tree.
# Regenerated on every run; meson reads it at every setup/reconfigure.
CROSS_IN="$XS_DIR/android/cross/aarch64-linux-android.txt.in"
CROSS_OUT="$XS_DIR/android/cross/aarch64-linux-android.txt"
sed -e "s|@NDK_BIN@|$NDK_BIN|g" \
    -e "s|@DEPS@|$DEPS|g" \
    -e "s|@REPO_DIR@|$XS_DIR|g" \
    "$CROSS_IN" > "$CROSS_OUT"
if grep -q '@NDK_BIN@\|@DEPS@\|@REPO_DIR@' "$CROSS_OUT"; then
    echo "cross file still has unsubstituted placeholders: $CROSS_OUT" >&2
    exit 1
fi

# --- deps overlay -------------------------------------------------------------
# xtrans (header-only) is absent from the termux prefix; install into our own
# overlay prefix (pkg_config_libdir in the cross file lists it first).
XTRANS_VER="1.6.0"
SRC_CACHE="$XS_DIR/android/deps/src"
OVERLAY="$XS_DIR/android/deps/prefix"
if [ ! -f "$OVERLAY/include/X11/Xtrans/Xtrans.h" ]; then
    mkdir -p "$SRC_CACHE" "$OVERLAY/include/X11/Xtrans" "$OVERLAY/lib/pkgconfig"
    TARBALL="$SRC_CACHE/xtrans-$XTRANS_VER.tar.xz"
    [ -f "$TARBALL" ] || curl -fSL -o "$TARBALL" \
        "https://xorg.freedesktop.org/releases/individual/lib/xtrans-$XTRANS_VER.tar.xz"
    XT="$(mktemp -d)"
    tar -xf "$TARBALL" -C "$XT" --strip-components=1
    cp "$XT"/*.h "$XT"/*.c "$OVERLAY/include/X11/Xtrans/"
    sed -e "s|@prefix@|$OVERLAY|;s|@exec_prefix@|\${prefix}|" \
        -e "s|@libdir@|\${exec_prefix}/lib|;s|@includedir@|\${prefix}/include|" \
        -e "s|@PACKAGE_VERSION@|$XTRANS_VER|;s|@fchown_define@||;s|@sticky_bit_define@||" \
        "$XT/xtrans.pc.in" > "$OVERLAY/lib/pkgconfig/xtrans.pc"
    rm -rf "$XT"
    echo "installed xtrans $XTRANS_VER into deps/prefix"
fi
# xtrans overlay patches (e.g. TMPDIR unix-socket dir — the container's
# libxcb dials $TMPDIR/.X11-unix/X<n>, so the listener must follow TMPDIR).
for p in "$XS_DIR"/android/patches-xtrans/*.patch; do
    if patch -d "$OVERLAY/include/X11/Xtrans" -p0 --dry-run -f -i "$p" >/dev/null 2>&1; then
        patch -d "$OVERLAY/include/X11/Xtrans" -p0 -f -i "$p" >/dev/null
        echo "applied xtrans/$(basename "$p")"
    elif patch -d "$OVERLAY/include/X11/Xtrans" -p0 --dry-run -f -R -i "$p" >/dev/null 2>&1; then
        echo "already applied: xtrans/$(basename "$p")"
    else
        echo "PATCH DOES NOT APPLY: $p — xtrans overlay drifted" >&2
        exit 1
    fi
done
find "$OVERLAY" -name '*.orig' -delete

# gbm.h: Mesa's GBM client header. The termux prefix ships libgbm and its
# pkg-config but not the header (only gbm_backend_abi.h), and glamor's GBM
# path needs it. Vendored into the overlay (like xtrans below) so the
# Xwayland tree stays upstream-clean and the header tracks the vendored copy.
if [ ! -f "$OVERLAY/include/gbm.h" ]; then
    mkdir -p "$OVERLAY/include"
    cp "$XS_DIR/android/deps/gbm.h" "$OVERLAY/include/gbm.h"
    echo "installed vendored gbm.h into deps/prefix"
fi

# --- meson ------------------------------------------------------------------
# glamor/dri3/drm/present enabled: the gamenative-drm daemon serves a render
# node (GEM/PRIME/syncobj) that glamor's GBM device probes and uses, so
# Xwayland runs the GPU path instead of shm-only. Gamescope no longer needs its
# content-override hack for the guest's frames: they reach the X11 window as a
# real dma-buf through the same device (see
# gamescope/android/08-xwayland-render-node.md). glx stays off (no GLX
# clients); the present extension itself is unconditional in this tree.
# xkb dirs point at the runtime payload layout; xkeyboard-config data is
# staged by package-xwayland.sh.
RECONF=""
if [ -d "$XS_DIR/build-android/meson-info" ]; then
    RECONF="--reconfigure"
elif [ -d "$XS_DIR/build-android" ]; then
    rm -rf "$XS_DIR/build-android"
fi
# Both directories are named rather than relying on the caller's cwd: with one
# positional argument meson takes the *current* directory as the source tree, and
# this script is called from other trees (gamescope's package script runs it from
# the gamescope checkout), where the build dir then gets configured against the
# wrong source — 'cpp compiler binary not defined', because Xwayland's cross file
# is C-only and gamescope's meson.build is C++.
meson setup "$XS_DIR/build-android" "$XS_DIR" \
    --cross-file "$XS_DIR/android/cross/aarch64-linux-android.txt" \
    -Dprefix="$RUNTIME" \
    -Dxvfb=false \
    -Dglamor=true -Dglx=false -Ddri3=true -Ddrm=true \
    -Dlisten_tcp=false \
    -Dlibdecor=false \
    -Dmitshm=true \
    -Dxdmcp=false -Dxdm-auth-1=false -Dsecure-rpc=false -Dlibunwind=false \
    -Dxinerama=false -Dxv=false -Dxres=true \
    -Dxace=false -Dxcsecurity=false \
    -Dxf86bigfont=false -Dscreensaver=false \
    -Dipv6=true \
    -Dsha1=libcrypto \
    -Dxkb_dir="$RUNTIME/share/X11/xkb" \
    -Dxkb_bin_dir="$RUNTIME/bin" \
    -Dxkb_output_dir="$RUNTIME/tmp/xkb" \
    -Ddefault_font_path="$RUNTIME/share/fonts" \
    $RECONF

ninja -C "$XS_DIR/build-android"

echo
echo "=== artifact ==="
file "$XS_DIR/build-android/hw/xwayland/Xwayland"

# --- xkbcomp ----------------------------------------------------------------
# The X server execs xkbcomp (from xkb_bin_dir) to compile keymaps; build our
# own from xorg sources rather than shipping a prebuilt binary.
XKBCOMP_VER="1.4.7"
KBD_BUILD="$XS_DIR/android/deps/xkbcomp-build"
mkdir -p "$SRC_CACHE"
TARBALL="$SRC_CACHE/xkbcomp-$XKBCOMP_VER.tar.xz"
[ -f "$TARBALL" ] || curl -fSL -o "$TARBALL" \
    "https://xorg.freedesktop.org/releases/individual/app/xkbcomp-$XKBCOMP_VER.tar.xz"
rm -rf "$KBD_BUILD"
mkdir -p "$KBD_BUILD"
tar -xf "$TARBALL" -C "$KBD_BUILD" --strip-components=1

(
    cd "$KBD_BUILD"
    CC="$NDK_BIN/aarch64-linux-android28-clang" \
    PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig:$DEPS/share/pkgconfig" \
    LDFLAGS="-Wl,-z,max-page-size=16384" \
    ./configure --host=aarch64-linux-android --prefix="$RUNTIME" \
        --disable-option-checking >/dev/null
    make -j"$(nproc)" >/dev/null
)
echo "=== artifact ==="
file "$KBD_BUILD/xkbcomp"

# --- xkeyboard-config ---------------------------------------------------------
# Keymap data (rules/symbols/…, architecture-independent) that xkbcomp reads
# at runtime from xkb_dir. Data-only meson project — install into the deps
# overlay; package-xwayland.sh stages $DEPS/share/X11 into the payload.
XKBCFG_VER="2.42"
XKBCFG_BUILD="$XS_DIR/android/deps/xkeyboard-config-build"
TARBALL="$SRC_CACHE/xkeyboard-config-$XKBCFG_VER.tar.xz"
[ -f "$TARBALL" ] || curl -fSL -o "$TARBALL" \
    "https://xorg.freedesktop.org/archive/individual/data/xkeyboard-config/xkeyboard-config-$XKBCFG_VER.tar.xz"
rm -rf "$XKBCFG_BUILD"
mkdir -p "$XKBCFG_BUILD"
tar -xf "$TARBALL" -C "$XKBCFG_BUILD" --strip-components=1
# The termux prefix ships share/X11/xkb as a dangling symlink to the on-device
# xkeyboard-config-2 dir; meson can't install through it — replace with a real
# directory tree.
[ -L "$DEPS/share/X11/xkb" ] && rm "$DEPS/share/X11/xkb"
meson setup "$XKBCFG_BUILD/build" "$XKBCFG_BUILD" --prefix="$DEPS" >/dev/null
ninja -C "$XKBCFG_BUILD/build" install >/dev/null
ls "$DEPS/share/X11/xkb/rules/evdev" >/dev/null
