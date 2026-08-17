#!/usr/bin/env bash
#
# Build the kernel and AOSP for the bare-metal x86_64 Android port.
# See doc/ for what this is building and why.
#
# Usage:
#   ./build.sh sync              fetch AOSP + kernel at the pinned revisions
#   ./build.sh mesa              cross-build Mesa (GL driver) for the guest
#   ./build.sh deps              check host prerequisites
#   ./build.sh kernel            configure + build bzImage
#   ./build.sh kernel-config     configure only (no compile)
#   ./build.sh android           build the AOSP target
#   ./build.sh all               kernel then android
#   ./build.sh image             assemble a bootable GPT disk image
#   ./build.sh run               boot that image in QEMU/KVM as a generic PC
#   ./build.sh test              boot it and report whether it came up cleanly
#   ./build.sh usb [/dev/sdX]    write the image to a USB stick for real hardware
#   ./build.sh logs [/dev/sdX]   pull kernel log + logcat back off that disk
#   ./build.sh clean             remove build artefacts
#
# Environment overrides:
#   JOBS=192                     parallelism (default: nproc)
#   ANDROID_TARGET=<lunch combo> default: pc_x86_64-trunk_staging-userdebug
#   USE_LLVM=0                   build the kernel with GCC instead of clang
#
set -euo pipefail

X86_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_SRC="$X86_ROOT/linux"
AOSP_ROOT="$X86_ROOT/android_17"
FRAGMENT="$X86_ROOT/config/pc_x86_64.fragment"
LOG_DIR="$X86_ROOT/logs"

# The Android 17 fragment (kernel/configs/d/android-6.18) is an EMPTY
# placeholder. b/android-6.12 is the newest populated one. See doc/03-kernel.md.
ANDROID_BASE_CONFIG="$AOSP_ROOT/kernel/configs/b/android-6.12/android-base.config"

# The bare-metal target. This defaulted to aosp_cf_x86_64_phone while
# device/pcx86/pc_x86_64 was still being written, and stayed wrong long after
# the device existed -- which is easy to miss, because a Cuttlefish build
# succeeds and writes to a different product directory, so nothing fails and
# nothing in out/target/product/pc_x86_64 changes. Check the TARGET_PRODUCT
# line the build prints if a fix does not seem to take effect.
ANDROID_TARGET="${ANDROID_TARGET:-pc_x86_64-trunk_staging-userdebug}"

JOBS="${JOBS:-$(nproc)}"
USE_LLVM="${USE_LLVM:-1}"

mkdir -p "$LOG_DIR"

# Both the kernel and AOSP build systems shell out to grep and parse its
# output. Some environments install a shell function or alias over it (an
# editor/agent wrapper, `grep --color=auto`, a ugrep shim); AOSP's
# product_config.mk then fails with a misleading "Cannot locate config
# makefile for product ...". Force the real binaries.
unset -f grep egrep fgrep 2>/dev/null || true
unalias grep egrep fgrep 2>/dev/null || true

# ---------------------------------------------------------------- output ----
if [[ -t 1 ]]; then
    R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else
    R=''; G=''; Y=''; B=''; N=''
fi
info()  { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn()  { printf '%swarn%s %s\n' "$Y" "$N" "$*" >&2; }
die()   { printf '%s fail%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# ------------------------------------------------------------ toolchain ----
# Android requires CC_IS_CLANG / AS_IS_LLVM / LD_IS_LLD, so the kernel must be
# built with LLVM, not GCC. Use AOSP's prebuilt for ABI consistency.
setup_llvm() {
    [[ "$USE_LLVM" == "1" ]] || { warn "USE_LLVM=0 -- building with GCC, will not satisfy Android config requirements"; return; }
    local dir
    dir=$(ls -d "$AOSP_ROOT"/prebuilts/clang/host/linux-x86/clang-r* 2>/dev/null | sort -V | tail -1)
    [[ -n "$dir" && -x "$dir/bin/clang" ]] || die "no AOSP clang prebuilt under $AOSP_ROOT/prebuilts/clang"
    export PATH="$dir/bin:$PATH"
    LLVM_ARGS=(LLVM=1)
    ok "clang: $("$dir/bin/clang" --version | head -1 | sed 's/ (http.*//')"
}

# ----------------------------------------------------------------- deps ----
cmd_deps() {
    local missing=() b
    info "checking host prerequisites"

    for b in bison flex bc make python3 openssl rsync; do
        if command -v "$b" >/dev/null 2>&1; then
            ok "$b"
        else
            printf '%s  --%s %s\n' "$R" "$N" "$b"
            missing+=("$b")
        fi
    done

    # libelf headers: needed for objtool, no binary to probe for
    if echo '#include <libelf.h>' | gcc -E - >/dev/null 2>&1; then
        ok "libelf-dev"
    else
        printf '%s  --%s %s\n' "$R" "$N" "libelf-dev"
        missing+=("libelf-dev")
    fi

    [[ -d "$KERNEL_SRC" ]]  || die "kernel tree missing: $KERNEL_SRC"
    [[ -d "$AOSP_ROOT" ]]   || die "AOSP tree missing: $AOSP_ROOT"
    [[ -s "$ANDROID_BASE_CONFIG" ]] \
        || die "Android base config missing or empty: $ANDROID_BASE_CONFIG"
    ok "kernel tree     $(cd "$KERNEL_SRC" && make kernelversion 2>/dev/null || echo '?')"
    ok "aosp tree       $AOSP_ROOT"
    ok "base config     $(wc -l < "$ANDROID_BASE_CONFIG") lines"
    ok "jobs            $JOBS"

    if (( ${#missing[@]} )); then
        # Map binary names to Debian package names
        local pkgs=() m
        for m in "${missing[@]}"; do
            case "$m" in
                bison)      pkgs+=(bison) ;;
                flex)       pkgs+=(flex) ;;
                libelf-dev) pkgs+=(libelf-dev) ;;
                *)          pkgs+=("$m") ;;
            esac
        done
        echo
        warn "missing packages -- install them with:"
        printf '\n    sudo apt-get install -y %s\n\n' "${pkgs[*]}"
        return 1
    fi
    echo; ok "all prerequisites present"
}

# --------------------------------------------------------------- kernel ----
kernel_configure() {
    cd "$KERNEL_SRC"
    setup_llvm

    [[ -f "$FRAGMENT" ]] || die "config fragment missing: $FRAGMENT"

    # No AOSP kernel prebuilt carries an embedded config (extract-ikconfig
    # finds nothing in any of them), so start from the in-tree defconfig.
    info "base config: x86_64_defconfig"
    make "${LLVM_ARGS[@]:-}" x86_64_defconfig >/dev/null

    # CONFIG_EXTRA_FIRMWARE_DIR has to be an absolute path -- the kernel build
    # resolves it itself and there is no variable expansion in Kconfig -- but
    # hardcoding one in a checked-in fragment breaks for everyone whose clone
    # does not live where the author's did. Expand @X86_ROOT@ into a scratch
    # copy instead, and feed merge_config that.
    local fragment="$FRAGMENT"
    if grep -q '@X86_ROOT@' "$FRAGMENT"; then
        fragment="$LOG_DIR/pc_x86_64.fragment.expanded"
        sed "s|@X86_ROOT@|$X86_ROOT|g" "$FRAGMENT" >"$fragment"
    fi

    info "merging android-base.config (b/android-6.12) + pc_x86_64.fragment"
    ./scripts/kconfig/merge_config.sh -m -O . \
        .config "$ANDROID_BASE_CONFIG" "$fragment" >"$LOG_DIR/merge_config.log" 2>&1 \
        || { cat "$LOG_DIR/merge_config.log"; die "merge_config failed"; }

    make "${LLVM_ARGS[@]:-}" olddefconfig >/dev/null
    ok "config resolved"

    kernel_audit
}

# Verify nothing was silently dropped. olddefconfig discards unknown symbols
# without warning -- this is how a 6.12 fragment on a 7.2 tree quietly loses
# requirements. See doc/03-kernel.md section 7.
kernel_audit() {
    cd "$KERNEL_SRC"
    local dropped=0 wrong=0 sym

    info "auditing config against requirements"
    while IFS= read -r line; do
        case "$line" in
            CONFIG_*=*)
                sym=${line%%=*}
                if ! grep -q "^$sym=" .config; then
                    echo "  DROPPED: $line"; dropped=$((dropped+1))
                fi ;;
            "# CONFIG_"*)
                sym=$(awk '{print $2}' <<<"$line")
                if grep -q "^$sym=" .config; then
                    echo "  SHOULD BE OFF: $sym"; wrong=$((wrong+1))
                fi ;;
        esac
    done < "$ANDROID_BASE_CONFIG"

    # Expected on mainline: the ACK-only symbols. See doc/03-kernel.md 3.1.
    cat <<'EOF'

  Expected DROPPED on mainline 7.2 (7 symbols):
    ACK-only, none block boot:
      ASHMEM, CPU_FREQ_TIMES, DM_DEFAULT_KEY, UID_SYS_STATS,
      NETFILTER_XT_MATCH_QUOTA2, NETFILTER_XT_MATCH_QUOTA2_LOG
    Removed upstream since 6.12:
      SCHED_DEBUG, NF_CT_PROTO_DCCP, NF_CT_PROTO_UDPLITE
  Anything else above is a real regression -- either a symbol renamed
  between 6.12 and 7.2, or a parent gate left unset so olddefconfig
  dropped it on unmet dependencies (see NETFILTER_ADVANCED in the
  fragment for a worked example).
EOF
    echo
    ok "audit complete: $dropped dropped, $wrong wrongly enabled"

    # Sanity-check the options this port actually depends on
    local critical=(
        CONFIG_ANDROID_BINDER_IPC CONFIG_ANDROID_BINDERFS CONFIG_EROFS_FS
        CONFIG_EFI_PARTITION CONFIG_DRM_I915 CONFIG_DRM_XE CONFIG_DRM_AMDGPU
        CONFIG_DRM_AMD_DC CONFIG_I2C_HID_ACPI CONFIG_SND_HDA_INTEL
        CONFIG_DMABUF_HEAPS_SYSTEM CONFIG_PSI
    )
    info "verifying port-critical options"
    local bad=0
    for sym in "${critical[@]}"; do
        if grep -q "^$sym=y" .config; then
            ok "$sym"
        else
            printf '%s  --%s %s  (not =y)\n' "$R" "$N" "$sym"; bad=$((bad+1))
        fi
    done
    (( bad == 0 )) || warn "$bad port-critical options are not enabled"
}

cmd_kernel_config() { kernel_configure; }

cmd_kernel() {
    kernel_configure
    cd "$KERNEL_SRC"
    info "building bzImage with $JOBS jobs"
    make "${LLVM_ARGS[@]:-}" -j"$JOBS" bzImage 2>&1 | tee "$LOG_DIR/kernel-build.log"
    local img="$KERNEL_SRC/arch/x86/boot/bzImage"
    [[ -f "$img" ]] || die "bzImage not produced"
    ok "bzImage: $img ($(du -h "$img" | cut -f1))"
}

# -------------------------------------------------------------- android ----
cmd_android() {
    [[ -f "$AOSP_ROOT/build/envsetup.sh" ]] || die "AOSP envsetup.sh not found"
    info "building $ANDROID_TARGET with $JOBS jobs"
    info "this takes ~30-45 min on this host; logging to $LOG_DIR/android-build.log"

    # envsetup.sh is not set -u clean, so relax while it is sourced
    cd "$AOSP_ROOT"
    set +u
    # shellcheck disable=SC1091
    source build/envsetup.sh
    lunch "$ANDROID_TARGET"
    set -u

    m -j"$JOBS" 2>&1 | tee "$LOG_DIR/android-build.log"
    ok "android build complete: $AOSP_ROOT/out/target/product/"
}

# ---------------------------------------------------------------- clean ----
cmd_clean() {
    info "cleaning kernel"
    [[ -d "$KERNEL_SRC" ]] && make -C "$KERNEL_SRC" mrproper >/dev/null 2>&1 || true
    warn "AOSP out/ not removed (153 GB tree, ~1h to rebuild)"
    warn "remove manually if you mean it:  rm -rf $AOSP_ROOT/out"
    ok "clean"
}

cmd_all() { cmd_kernel; cmd_android; }

# ------------------------------------------------------------ disk / run ----
cmd_image() { exec "$X86_ROOT/tools/mkdisk.sh" ; }
cmd_test()  { exec "$X86_ROOT/tools/test-vm.sh" "${@:2}" ; }
cmd_usb()   { exec "$X86_ROOT/tools/write-usb.sh" "${@:2}" ; }
cmd_logs()  { exec "$X86_ROOT/tools/collect-logs.sh" "${@:2}" ; }
cmd_run()   { exec "$X86_ROOT/tools/run-qemu.sh" "${@:2}" ; }
cmd_sync()  { exec "$X86_ROOT/tools/sync-sources.sh" "${@:2}" ; }
cmd_mesa()  { exec "$X86_ROOT/tools/build-mesa.sh" "${@:2}" ; }

# ----------------------------------------------------------------- main ----
case "${1:-}" in
    sync)          cmd_sync "$@" ;;
    mesa)          cmd_mesa "$@" ;;
    deps)          cmd_deps ;;
    kernel)        cmd_kernel ;;
    kernel-config) cmd_kernel_config ;;
    android)       cmd_android ;;
    all)           cmd_all ;;
    image)         cmd_image ;;
    test)          cmd_test "$@" ;;
    usb)           cmd_usb "$@" ;;
    logs)          cmd_logs "$@" ;;
    run)           cmd_run "$@" ;;
    clean)         cmd_clean ;;
    *)
        # Print the header comment as the usage text, stopping at the first
        # line that is not a comment. This used to be a hardcoded line range,
        # which silently truncated the help every time a subcommand was added.
        awk 'NR>2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
        exit 1 ;;
esac
