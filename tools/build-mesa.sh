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
ELF_SRC="$X86_ROOT/android_17/external/elfutils"
WORK="$X86_ROOT/out/mesa"
INSTALL="$X86_ROOT/android_17/device/pcx86/pc_x86_64/mesa"

# One image, every desktop GPU. Mesa's DRI loader picks the driver at runtime
# from the kernel driver name, exactly the way it does on a Linux distro, so a
# single libgallium_dri.so carrying all of them auto-detects the hardware and
# no per-vendor image is needed.
#
#   iris      Intel Gen8+       i915 / xe
#   radeonsi  AMD GCN+          amdgpu
#   nouveau   NVIDIA Fermi+     nouveau
#   virgl     virtio-gpu        QEMU
#
# radeonsi without LLVM is the part that changed. meson.build:57 makes the LLVM
# requirement conditional on amd-use-llvm, and radeonsi/si_pipe.c:663 switches
# every shader stage to ACO when AMD_LLVM_AVAILABLE is 0. ACO is Mesa's own AMD
# compiler and needs no LLVM at all. doc/08-roadmap.md called this "the hardest
# build problem in the project" on the assumption that LLVM had to be
# cross-compiled for Android; that is no longer true, and -Damd-use-llvm=false
# below is the whole of it.
#
# nouveau never needed LLVM -- nvc0 carries its own codegen under
# src/gallium/drivers/nouveau/codegen.
# softpipe is the safety net, and it is not optional on a machine you have not
# booted before. mesa is the ONLY EGL implementation this image installs -- there
# is no libEGL_angle.so and no SwiftShader GL anywhere on the partitions -- so if
# Mesa cannot produce a context, zygote aborts with "couldn't find an OpenGL ES
# implementation" and the device crash-loops with no GUI at all. That is exactly
# what the AMD workstation did when amdgpu failed to bind and simpledrm was the
# only DRM card present: no gallium driver matched, EGL failed, zygote died every
# 15 seconds. softpipe matches anything, needs no LLVM (llvmpipe would, and LLVM
# is disabled for the target), and is slow -- but slow is a usable desktop and a
# crash loop is not.
DRIVERS="${DRIVERS:-iris,radeonsi,nouveau,virgl,softpipe}"
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
# meson and the llvm-config shim are installed into the ROOTLESS deps prefix
# ($D below), not into /usr, and nothing else puts that on PATH. Without this
# the check underneath dies with "meson missing" and then tells you to apt
# install a meson that is already present -- and because ./build.sh mesa exits
# non-zero having printed almost nothing else, a following ./build.sh android
# SUCCEEDS against the previous libgallium_dri.so and silently ships an
# unchanged Mesa. That cost a boot cycle on 2026-09-11: the driver's mtime
# never moved off the earlier build and the flicker fix was not in the image.
PATH="$HOME/.local/aosp-deps/usr/bin:$PATH"
# Same story for python: the prefix is rootless, so `pip install --prefix` put
# mako in its own dist-packages, which is on nobody's sys.path. Mesa generates
# much of its source from mako templates in BOTH the host and the cross build,
# so this is exported rather than scoped to one of them.
export PYTHONPATH="$HOME/.local/aosp-deps/usr/lib/python3/dist-packages${PYTHONPATH:+:$PYTHONPATH}"
# And bison has its data path compiled in as /usr/share/bison, which does not
# exist on a rootless install -- it fails as
#     bison: /usr/share/bison/m4sugar/m4sugar.m4: cannot open
# generating glcpp-parse.c, roughly 34 targets in. bison, flex, meson and
# llvm-config all exist ONLY in this prefix (nothing is in /usr/bin), so the
# prefix is not an override here, it is the only source.
export BISON_PKGDATADIR="$HOME/.local/aosp-deps/usr/share/bison"
# bison finds m4 through $M4, falling back to the absolute path it was
# CONFIGURED with (/usr/bin/m4), not by searching PATH -- so putting the prefix
# on PATH is not enough and it fails as "m4 subprocess failed: No such file or
# directory". m4 is in the prefix like everything else.
export M4="$HOME/.local/aosp-deps/usr/bin/m4"

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

# ------------------------------------------------------- native mesa-clc ----
# Mesa 26.1 compiles some driver internals from OpenCL C. iris, crocus and the
# Intel/nouveau Vulkan drivers all appear in meson.build's with_driver_using_cl
# list (915), so asking for iris turns with_clc on, and with_clc enables LLVM
# unconditionally:
#
#     ERROR: Feature llvm cannot be disabled: CLC requires LLVM
#
# -Dmesa-clc=system takes the other branch: the cross build then does no CLC of
# its own and instead calls two binaries that must already be on PATH. They are
# ordinary host x86_64 programs -- they run at build time and nothing of them
# ships -- so they link the *host's* LLVM and no LLVM is ever cross-compiled for
# Android. That is what makes -Dllvm=disabled possible on the target side.
#
# Built once and cached; delete out/mesa/prefix-native to force a rebuild.
CLC_PFX="$WORK/prefix-native"
if [[ ! -x "$CLC_PFX/bin/mesa_clc" || ! -x "$CLC_PFX/bin/vtn_bindgen2" ]]; then
    for t in llvm-config-21 llvm-config; do command -v "$t" >/dev/null && break; done
    command -v llvm-config-21 >/dev/null || command -v llvm-config >/dev/null || die \
"host LLVM missing, needed to build mesa_clc.
  sudo apt install llvm-21-dev clang-21 libclang-21-dev \\
                   libclc-21-dev libllvmspirvlib-21-dev spirv-tools-dev cmake"
    # libclc, SPIRV-Tools and friends live in the rootless ~/.local/aosp-deps
    # prefix, which the HOST pkg-config knows nothing about. The cross builds
    # below pass their own pkg-config path; this native one runs against the
    # system default and dies at configure:
    #
    #     ERROR: Dependency "libclc" not found (tried pkg-config and cmake)
    #
    # Worth knowing how that failed: the whole mesa build exits 1 having printed
    # nothing beyond this line, and a following `./build.sh android` then
    # succeeds against the PREVIOUS libgallium_dri.so -- so the image builds
    # cleanly and silently ships an unchanged driver. Check the mesa exit code,
    # not just the AOSP one.
    # BOTH directories. The prefix is split the Debian multiarch way, and the
    # two dependencies live one in each:
    #     usr/lib/pkgconfig/                 libclc.pc, SPIRV-Tools.pc
    #     usr/lib/x86_64-linux-gnu/pkgconfig/  LLVMSPIRVLib.pc
    # Adding only the first gets past libclc and then dies on LLVMSPIRVLib, one
    # dependency at a time. This is the third time this prefix's multiarch split
    # has cost a build -- the kernel's OpenSSL headers were the same shape
    # (usr/include vs usr/include/x86_64-linux-gnu). Add both, always.
    D="$HOME/.local/aosp-deps/usr"
    PKG_CONFIG_PATH="$D/lib/pkgconfig:$D/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

    # One compiler family for both languages, or meson mixes them.
    #
    # This host has gcc but no g++, so meson picks gcc for C and clang++ for
    # C++. meson.build:606 then probes -mtls-dialect=gnu2 with the C compiler,
    # gcc 13 accepts it, and the flag is applied to C++ too -- where clang 18
    # does not support it and every .cpp fails:
    #
    #     c++: error: unsupported argument 'gnu2' to option '-mtls-dialect='
    #
    # Forcing both to clang makes the probe fail honestly, so the flag is never
    # added. Installing g++ would work too; this needs no root.
    CC=clang; CXX=clang++

    # clang's own development headers, for src/compiler/clc/clc_helpers.cpp.
    #
    #     fatal error: 'clang/Config/config.h' file not found
    #
    # They live under the prefix's llvm-18 tree, which llvm-config does not put
    # on the include path here. Nothing in meson adds it either, so it has to
    # come in through CXXFLAGS. This is the last of four host-toolchain gaps
    # between a clean checkout and a Mesa that actually rebuilds on this
    # machine; the other three are pkg-config paths and the C/C++ compiler
    # mismatch above.
    for _llvm in "$D"/lib/llvm-*; do
        [[ -d "$_llvm/include" ]] && CXXFLAGS="-I$_llvm/include ${CXXFLAGS:-}"
    done

    # ...and the libraries those headers belong to.
    #
    #     /usr/bin/ld: cannot find -lLLVMSPIRVLib
    #
    # pkg-config knowing about a .pc file is not the same as the linker knowing
    # where the .so is: LLVMSPIRVLib.pc lives in lib/x86_64-linux-gnu/pkgconfig
    # and reports a -L the system linker has no reason to search. -rpath as well
    # as -L, because mesa_clc is then RUN during the cross build and would
    # otherwise fail to start for the same reason it failed to link.
    LDFLAGS="-L$D/lib -L$D/lib/x86_64-linux-gnu -Wl,-rpath,$D/lib -Wl,-rpath,$D/lib/x86_64-linux-gnu ${LDFLAGS:-}"
    LD_LIBRARY_PATH="$D/lib:$D/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    # Everything above is exported HERE and nowhere else.
    #
    # These are host-toolchain settings for a host build. Exporting them at
    # script scope leaks them into the NDK cross builds further down, where they
    # are actively wrong: LDFLAGS pointing at host x86_64 library directories
    # made the cross link fail on a library it had always found before --
    #
    #     FAILED: src/amd/common/ac_ib_parser
    #     ld.lld: error: unable to find library -lelf
    #
    # -- which looks like the cross build regressing and is nothing of the kind.
    # The subshell is the fix: the native build gets them, nothing else does.
    info "building native mesa_clc + vtn_bindgen2 (host LLVM, one time)"
    rm -rf "$WORK/native-clc"
    (
    export PKG_CONFIG_PATH CC CXX CXXFLAGS LDFLAGS LD_LIBRARY_PATH
    # Everything a driver would need is switched off: this build exists only to
    # produce the two compilers, so it wants no GPU driver, no window system.
    meson setup "$WORK/native-clc" "$MESA_SRC" \
        --prefix "$CLC_PFX" --libdir lib -Dbuildtype=release \
        -Dinstall-mesa-clc=true -Dmesa-clc=enabled \
        -Dgallium-drivers= -Dvulkan-drivers= -Dplatforms= \
        -Dglx=disabled -Degl=disabled -Dgbm=disabled \
        -Dopengl=false -Dgles2=disabled -Dvideo-codecs= \
        -Dllvm=enabled -Dshared-llvm=enabled \
        >/dev/null
    ninja -C "$WORK/native-clc" -j"$JOBS"
    ninja -C "$WORK/native-clc" install >/dev/null
    )
fi
[[ -x "$CLC_PFX/bin/mesa_clc" ]] || die "mesa_clc did not build"
export PATH="$CLC_PFX/bin:$PATH"
ok "mesa-clc: $(command -v mesa_clc)"

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
    # Guard on the sub-library pkg-config files, not just libdrm.pc. A prefix
    # built when amdgpu/nouveau were disabled still has a perfectly good
    # libdrm.pc, so keying the cache on that alone silently reuses a libdrm that
    # is missing exactly what the current driver list needs, and configure then
    # dies on "Dependency libdrm_amdgpu not found" with a prefix that looks
    # populated.
    drm_stale=
    for pc in libdrm libdrm_amdgpu libdrm_nouveau; do
        [[ -f "$PFX/lib/pkgconfig/$pc.pc" ]] || drm_stale=1
    done
    if [[ -n "$drm_stale" ]]; then
        info "[$ABI] building libdrm"
        # amdgpu and nouveau are enabled because radeonsi and the nouveau
        # gallium driver link them. mesa/meson.build:1841 does a hard
        # dependency('libdrm_amdgpu') and fails configure outright without
        # it -- "Dependency libdrm_amdgpu not found (tried pkg-config)",
        # with nothing pointing at the libdrm built a few lines above as
        # the thing that has to provide it. intel stays disabled: iris does
        # not use libdrm_intel, it drives i915/xe through ioctls directly.
        rm -rf "$WORK/drm-$ABI"
        meson setup "$WORK/drm-$ABI" "$DRM_SRC" --cross-file "$CROSS" \
            --prefix "$PFX" --libdir lib -Dbuildtype=release \
            -Dintel=disabled -Dradeon=disabled -Damdgpu=enabled -Dnouveau=enabled \
            -Dvmwgfx=disabled -Dvc4=disabled -Dfreedreno=disabled -Detnaviv=disabled \
            -Dman-pages=disabled -Dtests=false -Dcairo-tests=disabled -Dvalgrind=disabled \
            >/dev/null
        ninja -C "$WORK/drm-$ABI" -j"$JOBS" install >/dev/null
    fi

    # libelf, for radeonsi.
    #
    # Mesa stops configure with "Gallium driver radeonsi requires libelf", and
    # that check (meson.build:2037) is stale -- it predates ACO and demands
    # libelf whatever the shader compiler is. The build system already knows
    # better: src/amd/common/meson.build:206 compiles ac_rtld.c only when
    # dep_elf is found, and si_shader_llvm.c is gated on amd_with_llvm. But
    # si_shader_binary.c and si_debug_gfx_compute.c call ac_rtld unguarded, so
    # deleting the error just trades a configure failure for a link failure.
    # Supplying libelf is the smaller, patch-free answer.
    #
    # elfutils is already in the tree and already builds for Android:
    # external/elfutils/Android.bp marks libelf vendor_available and ships a
    # ready-made config.h, so these sources are known good against bionic.
    # No autotools or meson run here -- compile the file list that Android.bp
    # names and hand-write the .pc meson looks for.
    if [[ ! -f "$PFX/lib/pkgconfig/libelf.pc" ]]; then
        info "[$ABI] building libelf (radeonsi needs it)"
        rm -rf "$WORK/elf-$ABI"; mkdir -p "$WORK/elf-$ABI"
        local ECC="$TOOLCHAIN/bin/$TRIPLE$API-clang"
        # These four flags are not optional and are not guesswork: they are what
        # external/elfutils/Android.bp's elfutils_defaults + the android: target
        # block pass. bionic has no libintl.h and no error(), so the tree ships
        # bionic-fixup/ with stubs for both, force-included through AndroidFixup.h.
        # Drop either and every single file fails on <libintl.h>.
        # elf_compress.c is not optional -- elf_strptr() calls into it, and
        # ac_rtld.c calls elf_strptr() -- but elfutils' config.h turns on
        # USE_ZSTD, and there is no zstd in the NDK sysroot. Rather than
        # cross-build all of external/zstd for a path that cannot run (AMD
        # shader ELFs are never compressed), shadow config.h with a two-line
        # shim that chains to the real one and switches zstd back off. zlib is
        # in the sysroot, so USE_ZLIB stays as it is.
        cat > "$WORK/elf-$ABI/config.h" <<'SHIM'
#include_next <config.h>
#undef USE_ZSTD
#undef USE_ZSTD_COMPRESS
SHIM
        local ECFLAGS=(-DHAVE_CONFIG_H -D_GNU_SOURCE -DNMNES=1000 -D_FILE_OFFSET_BITS=64
                       -std=gnu99 -O2 -fPIC -Wno-everything
                       -include AndroidFixup.h
                       -I"$WORK/elf-$ABI"
                       -I"$ELF_SRC" -I"$ELF_SRC/include" -I"$ELF_SRC/lib"
                       -I"$ELF_SRC/libelf" -I"$ELF_SRC/bionic-fixup")
        local c b
        for c in "$ELF_SRC"/libelf/*.c "$ELF_SRC"/lib/*.c; do
            b=$(basename "${c%.c}")
            # lib/Android.bp excludes these from libeu: color.c and printversion.c
            # want argp, dynamicsizehash*.c are templates included by other files
            # rather than compiled, and crc32.c collides with libz.
            case "$b" in color|printversion|crc32|dynamicsizehash*) continue ;; esac
            "$ECC" "${ECFLAGS[@]}" -c "$c" -o "$WORK/elf-$ABI/$b.o" \
                || die "libelf: $c failed to compile"
        done
        local nobj
        nobj=$(ls "$WORK/elf-$ABI"/*.o 2>/dev/null | wc -l)
        [[ "$nobj" -gt 0 ]] || die "libelf: nothing compiled from $ELF_SRC"
        mkdir -p "$PFX/lib/pkgconfig" "$PFX/include"
        "$TOOLCHAIN/bin/llvm-ar" rcs "$PFX/lib/libelf.a" "$WORK/elf-$ABI"/*.o
        # gelf.h pulls in libelf.h and elf.h, and it must be elfutils' own elf.h:
        # the NDK sysroot one is missing the AMD relocation and note constants
        # ac_rtld.c reads. Same set Android.bp exports (export_include_dirs: libelf).
        cp "$ELF_SRC"/libelf/{libelf.h,gelf.h,elf.h,nlist.h} "$PFX/include/"
        cat > "$PFX/lib/pkgconfig/libelf.pc" <<PC
prefix=$PFX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libelf
Description: elfutils libelf, cross-built for Android
Version: 0.191
Libs: -L\${libdir} -lelf -lz
Cflags: -I\${includedir}
PC
        ok "libelf: $nobj objects, $(du -h "$PFX/lib/libelf.a" | cut -f1)"
    fi

    # Always configure from scratch rather than 'meson configure' on an existing
    # build dir. Reconfiguring re-runs dependency detection WITHOUT the pinned
    # PKG_CONFIG_LIBDIR below and starts finding host libraries: a working build
    # began failing on a missing zstd.h that way, having picked up the host's
    # zstd for an Android target.
    # -Dmesa-clc=system is what lets iris configure at all. meson.build's
    # with_driver_using_cl lists with_gallium_iris, so selecting iris turns
    # with_clc on, and with_clc enables LLVM unconditionally:
    #
    #     ERROR: Feature llvm cannot be disabled: CLC requires LLVM
    #
    # There is no option to switch that off -- it is computed from the driver
    # list. Mesa 26.1 made this true for iris, so doc/05-graphics.md 4, which
    # picks iris first precisely because it has no LLVM dependency, no longer
    # holds as written for the version in this tree.
    #
    # 'system' takes the other branch of that if, where with_clc collapses to
    # with_gallium_rusticl -- off here -- so nothing cross-builds LLVM for
    # Android. The cost is two native binaries, mesa_clc and vtn_bindgen2,
    # which have to be on PATH; build them once from this same tree with
    # -Dinstall-mesa-clc=true against the host's LLVM.
    #
    # precomp-compiler=system keeps with_drivers_clc false as well, and costs
    # nothing here: no Intel driver looks for a per-driver *_clc program, only
    # asahi and pco do.
    info "[$ABI] configuring mesa (drivers: $DRIVERS)"
    rm -rf "$WORK/build-$ABI"
    PKG_CONFIG_LIBDIR="$PFX/lib/pkgconfig" \
    meson setup "$WORK/build-$ABI" "$MESA_SRC" --cross-file "$CROSS" \
        --prefix "$PFX" --libdir lib -Dbuildtype=release \
        -Dplatforms=android -Dandroid-stub=true \
        -Dgallium-drivers="$DRIVERS" -Dvulkan-drivers= \
        -Dllvm=disabled -Damd-use-llvm=false \
        -Degl=enabled -Dgles1=disabled -Dgles2=enabled \
        -Dgbm=enabled -Dglx=disabled -Dandroid-libbacktrace=disabled \
        -Degl-lib-suffix=_mesa -Dgles-lib-suffix=_mesa \
        -Dmesa-clc=system -Dprecomp-compiler=system \
        -Dexpat:default_library=static \
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
