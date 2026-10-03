#!/usr/bin/env bash
# package-xwayland.sh — produce the GameNative-bundled XWayland payload:
#
#   <GameNative>/app/src/main/assets/xwayland-gamenative-<date>.tzst
#   tar+zstd rooted at bin/ lib/ share/ tmp/, absorbed into the gamescope
#   package root by package-gamescope.sh (same runtime prefix
#   filesDir/gamescope/ — a single asset for XServerScreen.refreshComponentsFiles).
#
# Usage: android/package-xwayland.sh [YYYYMMDD]   (default: today)
#
# Library resolution is recursive over DT_NEEDED (same algorithm as
# package-gamescope.sh), pulling from the termux prefix, skipping bionic /
# NDK-public system libs. Runtime resolution is LD_LIBRARY_PATH (launcher
# prepends filesDir/gamescope/lib) — no rpath, no patchelf.

set -euo pipefail

XS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GN_DIR="${GN_DIR:-$(dirname "$XS_DIR")/GameNative}"
DEPS="${GN_XWAYLAND_DEPS_PREFIX:-$HOME/termuxfs/aarch64/data/data/com.termux/files/usr}"
DATE="${1:-$(date +%Y%m%d)}"
ASSET_NAME="xwayland-gamenative-$DATE.tzst"
OUT_ASSETS="$GN_DIR/app/src/main/assets"

XWAYLAND_BIN="$XS_DIR/build-android/hw/xwayland/Xwayland"
XKBCOMP_BIN="$XS_DIR/android/deps/xkbcomp-build/xkbcomp"

# --- prerequisites ------------------------------------------------------------
[ -x "$XWAYLAND_BIN" ] || bash "$XS_DIR/android/build-xwayland.sh"
for f in "$XWAYLAND_BIN" "$XKBCOMP_BIN"; do
    [ -e "$f" ] || { echo "error: missing $f" >&2; exit 1; }
done

# --- staging ------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/share" "$STAGE/tmp/xkb"

cp "$XWAYLAND_BIN" "$STAGE/bin/Xwayland"
cp "$XKBCOMP_BIN" "$STAGE/bin/xkbcomp"

# --- recursive DT_NEEDED resolver (mirrors package-gamescope.sh) --------------
resolve_libs() {
    local queue=("$@") name path elf
    local -A seen=()
    while ((${#queue[@]})); do
        elf="${queue[0]}"; queue=("${queue[@]:1}")
        while read -r name; do
            [ -n "$name" ] || continue
            case "$name" in
                # bionic / NDK-public system libs (present on every device)
                libc.so|libm.so|libdl.so|liblog.so|libandroid.so|libz.so|libz.so.*|\
                libEGL.so*|libGLESv*.so|ld-android.so)
                    continue ;;
            esac
            [ "${seen[$name]:-}" ] && continue
            seen[$name]=1
            path="$(find "$DEPS/lib" -maxdepth 1 -name "$name" 2>/dev/null | head -1)"
            if [ -z "$path" ]; then
                echo "  UNRESOLVED: $name (needed by ${elf##*/})" >&2
                continue
            fi
            cp -L "$path" "$STAGE/lib/$name"
            queue+=("$STAGE/lib/$name")
        done < <(readelf -d "$elf" | grep NEEDED | sed -E 's/.*\[(.*)\]/\1/')
    done
}
resolve_libs "$STAGE/bin/Xwayland" "$STAGE/bin/xkbcomp"

# --- xkeyboard-config data (architecture-independent keymap data) -------------
cp -r "$DEPS/share/X11" "$STAGE/share/"
# xkb compiled-keymap cache must be empty at runtime (app-private tmp).
rm -rf "$STAGE/share/X11/xkb/compiled"

# keep empty runtime dirs in the tarball
touch "$STAGE/tmp/xkb/.keep"

# --- permission normalization -------------------------------------------------
# The staged tree inherits its modes from the termux prefix (dirs 0700, files
# 0600, libs 0700) and tar stores them verbatim, so the payload could ship a
# read-only, owner-only tree. Normalize: directories 0755, regular files 0644,
# executable files 0755. Symlinks are left untouched.
find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE" -type f -perm /111 -exec chmod 0755 {} +
find "$STAGE" -type f ! -perm /111 -exec chmod 0644 {} +

# --- archive ------------------------------------------------------------------
rm -f "$OUT_ASSETS"/xwayland-gamenative-*.tzst
tar --owner=0 --group=0 --numeric-owner -C "$STAGE" -cf - bin lib share tmp \
    | zstd -19 -T0 -o "$OUT_ASSETS/$ASSET_NAME"

echo
echo "=== payload ==="
ls -lh "$OUT_ASSETS/$ASSET_NAME"
echo "staged libs:"
ls "$STAGE/lib"
echo
echo "If the tag changed, add it to refreshComponentsFiles in XServerScreen.kt."
