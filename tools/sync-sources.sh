#!/usr/bin/env bash
#
# Fetch the two upstream trees this port builds against, into the layout
# build.sh expects, and apply the one patch that lives outside them.
#
#   ./build.sh sync              everything, pinned to the recorded revisions
#   ./build.sh sync aosp         AOSP only
#   ./build.sh sync kernel       kernel only
#   ./build.sh sync patches      re-apply out-of-tree patches only
#
# Neither tree is committed to this repository -- together they are ~350 GB of
# unmodified upstream code. They are reproduced from pinned revisions instead,
# which is what makes a ~2 MB repository sufficient. See doc/README.md.
#
# Expect this to take a long time and a lot of disk on first run. It is safe to
# interrupt and re-run: every step checks for its own completion first.
#
# Environment overrides:
#   JOBS=8              sync parallelism. 8 is deliberate -- see below.
#   PINNED=0            track android17-release as it moves, instead of
#                       reproducing the exact tree this port was built from
#   KERNEL_REMOTE=<url> default is the GitHub mirror, which is markedly faster
#                       than git.kernel.org from most networks
#
set -euo pipefail

X86_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AOSP_ROOT="$X86_ROOT/android_17"
KERNEL_SRC="$X86_ROOT/linux"

AOSP_MANIFEST_URL="https://android.googlesource.com/platform/manifest"
AOSP_BRANCH="android17-release"
PINNED_MANIFEST="aosp-android17-pinned.xml"

# The kernel is pristine upstream at this revision -- there is no fork. Any
# kernel change in this project is a config symbol in config/pc_x86_64.fragment.
KERNEL_REV="0d8395707651"
KERNEL_REMOTE="${KERNEL_REMOTE:-git@github.com:torvalds/linux.git}"

# Sync parallelism defaults to 8 rather than nproc. These jobs are almost
# entirely network-bound, and on a many-core host nproc oversubscribes the link
# badly enough that the sync gets slower, not faster, and googlesource starts
# refusing connections.
JOBS="${JOBS:-8}"
PINNED="${PINNED:-1}"

if [[ -t 1 ]]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else R=''; G=''; Y=''; B=''; N=''; fi
info() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarn%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# ------------------------------------------------------------ prereqs ----
check_prereqs() {
    command -v git  >/dev/null || die "git is not installed"
    command -v repo >/dev/null || die "repo is not installed.
     sudo apt install repo   (or see source.android.com/setup/build/downloading)"

    local avail_gb
    avail_gb=$(df -BG --output=avail "$X86_ROOT" 2>/dev/null | tail -1 | tr -dc '0-9')
    if [[ -n "$avail_gb" && "$avail_gb" -lt 400 ]]; then
        warn "only ${avail_gb} GB free on this filesystem."
        warn "AOSP source is ~200 GB and a build needs ~200 GB more on top."
    fi
}

# --------------------------------------------------------------- aosp ----
sync_aosp() {
    info "AOSP -> $AOSP_ROOT"
    mkdir -p "$AOSP_ROOT"
    cd "$AOSP_ROOT"

    # android_17/device/pcx86/ is already present here: it is this project's
    # own code, committed to this repository, that happens to live at a path
    # inside the AOSP tree. repo leaves it alone because it is not one of the
    # manifest's projects, so initialising into a non-empty directory is fine.
    if [[ ! -d .repo/manifests ]]; then
        info "repo init ($AOSP_BRANCH) -- this fetches the manifest repo and is slow"
        repo init -u "$AOSP_MANIFEST_URL" -b "$AOSP_BRANCH"
    else
        ok "already initialised"
    fi

    if [[ "$PINNED" == "1" ]]; then
        [[ -f "$X86_ROOT/manifests/$PINNED_MANIFEST" ]] \
            || die "missing manifests/$PINNED_MANIFEST"
        # -m selects a manifest *within* the manifest repo, so ours has to be
        # copied in before it can be named. This leaves .repo/manifests with an
        # untracked file; that is expected and harmless.
        cp "$X86_ROOT/manifests/$PINNED_MANIFEST" .repo/manifests/
        info "pinning to $PINNED_MANIFEST"
        repo init -m "$PINNED_MANIFEST"
        ok "$(repo manifest 2>/dev/null | grep -c 'revision="[0-9a-f]\{40\}"') projects pinned to exact revisions"
    else
        warn "PINNED=0: following $AOSP_BRANCH as it moves."
        warn "This will NOT reproduce the tree this port was built against."
    fi

    info "repo sync -c -j$JOBS (hours on a first run)"
    repo sync -c -j"$JOBS"
    ok "AOSP synced"
}

# ------------------------------------------------------------- kernel ----
sync_kernel() {
    info "kernel -> $KERNEL_SRC"
    if [[ ! -d "$KERNEL_SRC/.git" ]]; then
        info "cloning $KERNEL_REMOTE"
        git clone "$KERNEL_REMOTE" "$KERNEL_SRC"
    else
        ok "already cloned"
    fi

    cd "$KERNEL_SRC"
    if [[ "$(git rev-parse HEAD)" == "$KERNEL_REV"* ]]; then
        ok "already at $KERNEL_REV"
    else
        git cat-file -e "$KERNEL_REV^{commit}" 2>/dev/null || {
            info "fetching $KERNEL_REV"
            git fetch --tags origin
        }
        info "checking out $KERNEL_REV"
        git checkout --detach "$KERNEL_REV"
    fi
    ok "kernel at $(git describe --tags 2>/dev/null || git rev-parse --short HEAD)"
}

# ------------------------------------------------------------ patches ----
# The only change this port needs inside an AOSP project. Kept as a patch
# rather than a fork so that 1083 untouched projects stay untouched -- a fork
# would mean rebasing three files on every uprev. See patches/ for the why.
apply_patches() {
    info "out-of-tree patches"
    local applied=0 skipped=0

    while IFS= read -r -d '' patch; do
        local rel="${patch#"$X86_ROOT"/patches/}"
        local project="$AOSP_ROOT/${rel%/*}"
        [[ -d "$project/.git" ]] || die "no such project for $rel: $project
     Run './build.sh sync aosp' first."

        # Reverse-applying cleanly means it is already in the tree. Checking
        # that, rather than just running git am, keeps this re-runnable.
        if git -C "$project" apply --check -R "$patch" 2>/dev/null; then
            skipped=$((skipped + 1)); continue
        fi
        git -C "$project" apply --check "$patch" 2>/dev/null \
            || die "$rel does not apply to $project.
     The project may be at a different revision than this patch expects."

        info "applying $rel"
        git -C "$project" am "$patch" >/dev/null \
            || die "git am failed for $rel"
        applied=$((applied + 1))
    done < <(find "$X86_ROOT/patches" -name '*.patch' -print0 2>/dev/null | sort -z)

    ok "$applied applied, $skipped already present"
}

# --------------------------------------------------------------- main ----
check_prereqs
case "${1:-all}" in
    all)     sync_aosp; sync_kernel; apply_patches ;;
    aosp)    sync_aosp ;;
    kernel)  sync_kernel ;;
    patches) apply_patches ;;
    *)       die "unknown target: $1  (all | aosp | kernel | patches)" ;;
esac

echo
ok "sources ready"
echo "    next:  ./build.sh all     (kernel + android)"
