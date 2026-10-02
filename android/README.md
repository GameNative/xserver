# gamenative-xwayland — Android support

NDK cross-build of Xwayland (xserver `xwayland-24.1.13`) for GameNative's
gamescope display path. Upstream tree stays clean in git; everything Android
lives here in `android/` and is applied to the working tree uncommitted
(same patch-train model as `gamescope/android/`).

## Layout

- `build-xwayland.sh` — one entry point: applies `patches/` (GNU patch,
  idempotent dry-run gate, `@TERMUX_PREFIX@` → runtime prefix substitution),
  meson + ninja Xwayland, then autotools-builds xkbcomp 1.4.7.
- `package-xwayland.sh [YYYYMMDD]` — stages `bin/` (Xwayland, xkbcomp),
  `lib/` (recursive DT_NEEDED from the termux prefix, system libs skipped),
  `share/X11/xkb` (xkeyboard-config data) and `tmp/` into
  `GameNative/app/src/main/assets/xwayland-gamenative-<date>.tzst`.
- `cross/aarch64-linux-android.txt` — meson cross file (NDK 27.3, API 28,
  16 KB pages; `android/deps/prefix` pkg-config overlay first).
- `patches/` — from the termux-packages `x11-packages/xwayland` recipe.
- `patches-xtrans/` — applied to the xtrans overlay copy at deps time:
  `0001` makes the X11 unix-socket dir follow `TMPDIR` (bionic has no
  writable /tmp; the container's libxcb dials `$TMPDIR/.X11-unix/X<n>`,
  so the listener must meet it there).
- `deps/` — build-time only: `prefix/` overlay (xtrans headers, absent from
  the termux prefix), `src/` tarball cache, `xkbcomp-build/`.

## Patch deviations from the termux recipe

- `stubmain.c.patch` **dropped** — references `xf86LogFile`, gone in 24.1;
  Xwayland opens no log file by default (`osinit.c: LogInit(NULL, NULL)`).
- `..._Xext_xf86bigfont.c.patch` **dropped** — extension disabled
  (`-Dxf86bigfont=false`).
- Remaining 7 patches apply as-is (prefix placeholder substituted at build
  time): ashmem MIT-SHM, memfd fallback, /tmp + /etc path relocation,
  setuid/setpgid removal, lock-file `rename()` (no hard links on FUSE).

## Meson profile

SHM-only server: `glamor/glx/dri3/drm=false` (game vulkan frames bypass X11
via the gn ICD shim; GBM doesn't exist on Android), `mitshm=true` over
libandroid-shmem, `libdecor=false`, `xdmcp/xres/xv/xinerama/xace/xcsecurity/
screensaver=false`, `sha1=libcrypto`, `listen_tcp=false`. xkb dirs compile
to the runtime payload prefix (`/data/user/0/app.gamenative/files/xwayland`);
built-in fonts cover `fixed`, so no font files ship.

## Runtime integration (GameNative, X4)

- Payload extracts to `filesDir/xwayland/`; gamescope finds the binary via
  the upstream `WLR_XWAYLAND` env var (no patch needed).
- `LD_LIBRARY_PATH` prepends `filesDir/xwayland/lib` (resolver model, same
  as the gamescope payload).
- `share/X11/xkb` provides keymap data; `xkbcomp` execs from `bin/`;
  `tmp/xkb` is the compiled-keymap output dir.

## Verification

- `build-xwayland.sh` prints `file` output for both artifacts: aarch64 ELF,
  `/system/bin/linker64`, Android 28.
- NEEDED list contains no `libdecor`, no `libdrm`; all non-system libs land
  in the payload `lib/` (packager prints the staged list; any `UNRESOLVED`
  line is an error).
