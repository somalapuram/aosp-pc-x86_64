#!/usr/bin/env bash
#
# Cross-build Mesa for the Android guest, out of tree, with the NDK.
#
#   ./build.sh mesa            build and install into the device tree
#   ./build.sh mesa clean      wipe the build directories first
#
# AOSP's external/mesa3d/Android.bp builds only gfxstream/virtio guest modules
# -- grep it for any gallium driver name and you get nothing -- while the full
# upstream source sits right there in src/gallium/drivers. So Soong cannot
# build us a GL driver, and this is doc/05-graphics.md section 4.3 (Option B):
# build with meson and the NDK, ship the result as vendor prebuilts.
#
# Output goes to android_17/device/pcx86/pc_x86_64/mesa/, which is gitignored:
# the recipe is version-controlled, the ~40 MB of binaries are not, exactly as
# the kernel and AOSP trees are pinned rather than vendored.
#
# Environment overrides:
#   DRIVERS=virgl              gallium drivers to build
#   ABIS="x86_64 x86"          which ABIs to build (both are needed, see below)
#   NDK_VERSION=r27c           NDK to fetch if none is present
#   JOBS=64                    ninja parallelism
#
set -euo pipefail

X86_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MESA_SRC="$X86_ROOT/android_17/external/mesa3d"
DRM_SRC="$X86_ROOT/android_17/external/libdrm"
WORK="$X86_ROOT/out/mesa"
INSTALL="$X86_ROOT/android_17/device/pcx86/pc_x86_64/mesa"

DRIVERS="${DRIVERS:-virgl}"
ABIS="${ABIS:-x86_64 x86}"
NDK_VERSION="${NDK_VERSION:-r27c}"
JOBS="${JOBS:-$(nproc)}"
API=35   # highest sysroot in r27c; vendor libs are not tied to the platform SDK

if [[ -t 1 ]]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else R=''; G=''; Y=''; B=''; N=''; fi
info() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarn%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

[[ "${1:-}" == "clean" ]] && { info "wiping build dirs"; rm -rf "$WORK"/build-* "$WORK"/drm-* "$WORK"/prefix-*; }

# ------------------------------------------------------------- prereqs ----
for t in meson ninja pkg-config; do
    command -v "$t" >/dev/null || die "$t missing.  sudo apt install meson ninja-build pkg-config"
done
python3 -c 'import mako' 2>/dev/null || die "python mako missing.  sudo apt install python3-mako
     Mesa generates much of its source with mako templates; without it meson
     fails late, at 'Python (3.x) mako module >= 0.8.0 required to build mesa'."

# ----------------------------------------------------------------- ndk ----
# AOSP's own prebuilts/ndk holds only 'sources' -- no sysroot, no toolchain --
# so it cannot be used for this.
NDK_DIR="$WORK/ndk/android-ndk-$NDK_VERSION"
TOOLCHAIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
if [[ ! -x "$TOOLCHAIN/bin/clang" ]]; then
    info "fetching NDK $NDK_VERSION (~640 MB)"
    mkdir -p "$WORK/ndk"
    curl -L -o "$WORK/ndk/ndk.zip" --progress-bar \
        "https://dl.google.com/android/repository/android-ndk-$NDK_VERSION-linux.zip"
    (cd "$WORK/ndk" && unzip -q -o ndk.zip && rm -f ndk.zip)
fi
[[ -x "$TOOLCHAIN/bin/clang" ]] || die "NDK toolchain missing at $TOOLCHAIN"
ok "ndk: $("$TOOLCHAIN/bin/clang" --version | head -1 | sed 's/ (http.*//')"

mkdir -p "$WORK"

# Both ABIs are needed, not just 64-bit.
#
# Android forks a 32-bit zygote (app_process32) unless the product is
# explicitly 64-bit-only, and every process it spawns loads its own EGL driver.
# With 64-bit Mesa alone, SurfaceFlinger renders happily on virgl -- the log
# even reports "renderer : virgl (NVIDIA ...)" -- while every app process dies:
#     F DEBUG  : Executable: /system/bin/app_process32
#     F zygote : couldn't find an OpenGL ES implementation
# 64-bit installs to lib64/, 32-bit to lib/.
abi_triple() { case "$1" in x86_64) echo x86_64-linux-android ;; x86) echo i686-linux-android ;; esac; }
abi_libdir() { case "$1" in x86_64) echo lib64 ;; x86) echo lib ;; esac; }

build_abi() {
    local ABI="$1" TRIPLE PFX CROSS LIBDIR found
    TRIPLE=$(abi_triple "$ABI")
    PFX="$WORK/prefix-$ABI"
    CROSS="$WORK/cross-$ABI.txt"
    LIBDIR=$(abi_libdir "$ABI")

    cat > "$CROSS" <<EOF
[binaries]
c          = ['$TOOLCHAIN/bin/$TRIPLE$API-clang']
cpp        = ['$TOOLCHAIN/bin/$TRIPLE$API-clang++']
ar         = '$TOOLCHAIN/bin/llvm-ar'
strip      = '$TOOLCHAIN/bin/llvm-strip'
pkg-config = ['/usr/bin/pkg-config']
llvm-config = 'false'

[host_machine]
system     = 'android'
cpu_family = '$ABI'
cpu        = '$ABI'
endian     = 'little'

[properties]
needs_exe_wrapper = true

[built-in options]
# Link the C++ runtime statically.
#
# The NDK links C++ against its own libc++_shared.so, which does not exist in
# Android's vendor linker namespace -- the platform ships libc++.so instead. So
# the driver installs correctly and then cannot be loaded at all:
#     E vndksupport: Could not load /vendor/lib64/egl/libEGL_mesa.so from sphal
#                    namespace: dlopen failed: library "libc++_shared.so" not found
#     D libEGL   : Failed to load drivers from property ro.hardware.egl with value mesa
#     F SurfaceFlinger: couldn't find an OpenGL ES implementation
# Shipping the NDK's libc++_shared.so alongside would put two C++ runtimes in
# one process; linking it statically removes the dependency entirely.
cpp_link_args = ['-static-libstdc++']
EOF

    # Mesa needs libdrm and the NDK does not ship one. external/mesa3d has a
    # libdrm.wrap, but with no [provide] section, so --force-fallback-for=libdrm
    # silently does nothing and meson still reports "tried pkgconfig". Build
    # AOSP's own libdrm instead -- the version this tree ships is what the guest
    # actually runs against.
    if [[ ! -f "$PFX/lib/pkgconfig/libdrm.pc" ]]; then
        info "[$ABI] building libdrm"
        rm -rf "$WORK/drm-$ABI"
        meson setup "$WORK/drm-$ABI" "$DRM_SRC" --cross-file "$CROSS" \
            --prefix "$PFX" --libdir lib -Dbuildtype=release \
            -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled \
            -Dvmwgfx=disabled -Dvc4=disabled -Dfreedreno=disabled -Detnaviv=disabled \
            -Dman-pages=disabled -Dtests=false -Dcairo-tests=disabled -Dvalgrind=disabled \
            >/dev/null
        ninja -C "$WORK/drm-$ABI" -j"$JOBS" install >/dev/null
    fi

    # Always configure from scratch rather than 'meson configure' on an existing
    # build dir. Reconfiguring re-runs dependency detection WITHOUT the pinned
    # PKG_CONFIG_LIBDIR below and starts finding host libraries: a working build
    # began failing on a missing zstd.h that way, having picked up the host's
    # zstd for an Android target.
    info "[$ABI] configuring mesa (drivers: $DRIVERS)"
    rm -rf "$WORK/build-$ABI"
    PKG_CONFIG_LIBDIR="$PFX/lib/pkgconfig" \
    meson setup "$WORK/build-$ABI" "$MESA_SRC" --cross-file "$CROSS" \
        --prefix "$PFX" --libdir lib -Dbuildtype=release \
        -Dplatforms=android -Dandroid-stub=true \
        -Dgallium-drivers="$DRIVERS" -Dvulkan-drivers= \
        -Dllvm=disabled -Degl=enabled -Dgles1=disabled -Dgles2=enabled \
        -Dgbm=enabled -Dglx=disabled -Dandroid-libbacktrace=disabled \
        -Degl-lib-suffix=_mesa -Dgles-lib-suffix=_mesa \
        >/dev/null

    info "[$ABI] building with $JOBS jobs"
    ninja -C "$WORK/build-$ABI" -j"$JOBS"

    # Android's EGL loader resolves libEGL_<ro.hardware.egl>.so under
    # <libdir>/egl. The _mesa suffix has to be in the SONAME, not just the
    # filename -- that is what the *-lib-suffix options above do. Otherwise the
    # SONAME stays libEGL.so and collides with Android's own loader.
    info "[$ABI] installing to $LIBDIR/"
    mkdir -p "$INSTALL/$LIBDIR/egl"
    for lib in libEGL_mesa.so libGLESv2_mesa.so; do
        found=$(find "$WORK/build-$ABI" -path '*android_stub*' -prune -o -name "$lib" -print | head -1)
        [[ -n "$found" ]] || die "[$ABI] built $lib not found"
        cp "$found" "$INSTALL/$LIBDIR/egl/$lib"
    done
    # libgallium_dri.so is a direct NEEDED of libEGL_mesa.so, not something
    # dlopened out of a dri/ directory, so it belongs on the plain library path.
    found=$(find "$WORK/build-$ABI" -path '*android_stub*' -prune -o -name libgallium_dri.so -print | head -1)
    cp "$found" "$INSTALL/$LIBDIR/libgallium_dri.so"
}

# Stage into a temporary directory and swap at the end. An earlier version
# wiped $INSTALL up front, so a configure failure -- iris needing LLVM, say --
# left no libraries at all and broke the product build too, turning one failed
# experiment into a broken tree.
STAGE="$WORK/stage"
rm -rf "$STAGE"
INSTALL_REAL="$INSTALL"; INSTALL="$STAGE"
for abi in $ABIS; do build_abi "$abi"; done
INSTALL="$INSTALL_REAL"
rm -rf "$INSTALL"; mkdir -p "$(dirname "$INSTALL")"; mv "$STAGE" "$INSTALL"

# The android_stub/*.so are link-time stubs for liblog, libcutils,
# libnativewindow and friends. They are deliberately NOT shipped: the real
# Android libraries provide those at runtime, and stubs would shadow them.
echo
ok "installed:"
( cd "$INSTALL" && find . -name '*.so' -printf '    %-42p %s bytes\n' | sort )

cat <<'EOF'

  device.mk declares these through PRODUCT_PACKAGES (see Android.bp) and sets
  ro.hardware.egl=mesa. ANGLE and SwiftShader remain installed, so reverting is
  a single property change back to 'angle'.
EOF
