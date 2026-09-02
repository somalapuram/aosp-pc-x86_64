#!/usr/bin/env bash
#
# Fetch the two upstream trees this port builds against, into the layout
# build.sh expects, and apply the one patch that lives outside them.
#
#   ./build.sh sync              everything, pinned to the recorded revisions
#   ./build.sh sync aosp         AOSP only
#   ./build.sh sync kernel       kernel only
#   ./build.sh sync patches      re-apply out-of-tree patches only
#   ./build.sh sync verify       check every project was actually checked out
#
# Neither tree is committed to this repository -- together they are ~350 GB of
# unmodified upstream code. They are reproduced from pinned revisions instead,
# which is what makes a ~2 MB repository sufficient. See doc/README.md.
#
# Expect this to take a long time and a lot of disk on first run. It is safe to
# interrupt and re-run: every step checks for its own completion first.
#
# Environment overrides:
#   JOBS=32             sync parallelism
#   REFERENCE=<path>    root of an existing checkout (one containing android_17/
#                       and linux/) to read objects from instead of the network.
#                       Turns hours or days of transfer into minutes. See below.
#   PINNED=0            track android17-release as it moves, instead of
#                       reproducing the exact tree this port was built from
#   KERNEL_REMOTE=<url> where to clone the kernel from
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

# pclauncher: the desktop launcher that replaces Launcher3QuickStep. Its own
# repository, developed standalone in Android Studio against Gradle and built
# here by Soong from the same sources -- see vendor/x86/pclauncher/Android.bp.
#
# Tracked on the 'aosp' branch, not main. main is the Gradle form that opens in
# Android Studio; aosp carries the Soong build -- Android.bp, package attributes
# in the manifests, and the Hilt base class the Gradle plugin would otherwise
# generate. The two cannot be one branch: AGP 8 rejects the package attribute
# that Soong's manifest merger requires.
#
# It lands in vendor/ rather than packages/apps/ because vendor/ is where
# non-AOSP code belongs and, more practically, because repo does not own it:
# it is absent from the manifest, so `repo sync` will not touch it and
# `repo forall` will not walk it. The parent .gitignore already excludes it via
# /android_17/*, so it is never committed into this repository either.
PCLAUNCHER_SRC="$AOSP_ROOT/vendor/x86/pclauncher"
PCLAUNCHER_REMOTE="git@github.com:somalapuram/pclauncher.git"
PCLAUNCHER_BRANCH="aosp"
PCLAUNCHER_REV="186f8bbefb746a5ca3fffe842382a8116fd2c81a"

# The GitHub mirror over SSH. git.kernel.org is the canonical source and works
# equally well:
#     KERNEL_REMOTE=https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
#
# Do not assume either is the fast one. Measured on the machine this was
# developed on, both were throttled to well under 500 KB/s while the same link
# pulled 16 MB/s from elsewhere, and the GitHub clone dropped after 156 MB:
#     fetch-pack: unexpected disconnect while reading sideband packet
#     fatal: early EOF
# Measure before switching, and if both are slow, use REFERENCE.
KERNEL_REMOTE="${KERNEL_REMOTE:-git@github.com:torvalds/linux.git}"

# These jobs are network-bound, so this is not a core count. 32 is a reasonable
# ceiling; going as high as nproc on a many-core host oversubscribes the link
# and googlesource starts refusing connections.
JOBS="${JOBS:-32}"
PINNED="${PINNED:-1}"

# An existing checkout to borrow objects from. AOSP is ~200 GB and the kernel
# ~5.5 GB; on a slow or unreliable route those are days of transfer, and a
# dropped connection costs the whole clone. Pointing at a local copy reads from
# disk instead. Objects are copied, not linked, so the result stands alone and
# the reference can be deleted afterwards.
REFERENCE="${REFERENCE:-}"
if [[ -n "$REFERENCE" ]]; then
    REFERENCE="$(cd "$REFERENCE" 2>/dev/null && pwd)" \
        || { echo "REFERENCE path does not exist" >&2; exit 1; }
fi

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
    local ref_args=()
    if [[ -n "$REFERENCE" && -d "$REFERENCE/android_17/.repo" ]]; then
        info "borrowing objects from $REFERENCE/android_17"
        ref_args=(--reference "$REFERENCE/android_17" --dissociate)
    elif [[ -n "$REFERENCE" ]]; then
        warn "no .repo under $REFERENCE/android_17 -- fetching AOSP from the network"
    fi

    if [[ ! -e .repo/manifest.xml ]]; then
        info "repo init ($AOSP_BRANCH) -- fetches the manifest repo, ~59 MB"
        # Test manifest.xml, not the manifests/ directory: an interrupted init
        # leaves manifests.git behind without ever producing manifest.xml, and
        # a later sync then fails with "error parsing manifest ... No such file
        # or directory" that reads like a corrupt tree rather than a partial one.
        repo init -u "$AOSP_MANIFEST_URL" -b "$AOSP_BRANCH" "${ref_args[@]}"
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
    verify_checkouts
    ok "AOSP synced"
}

# repo sync fetches and then checks out, and an interruption between the two
# leaves projects with a populated .git and an empty working tree. Nothing
# reports this:
#
#   - `repo sync` prints "repo sync has finished successfully"
#   - `repo sync -l` also succeeds and changes nothing, because HEAD already
#     matches the manifest, so repo considers the project done
#   - the project directory exists, so any [ -d ] check passes
#
# The only symptom is `git status` listing every tracked file as deleted. It
# surfaces much later as a wall of Soong errors naming modules that live in
# whichever project was hit, e.g. with bionic missing:
#
#   error: ... "libz_defaults" depends on undefined module "bug_24465209_workaround"
#   error: ... "py3-interp-defaults" depends on undefined module "no_bti"
#
# which says nothing about a bad checkout. Detect and repair it here instead.
verify_checkouts() {
    cd "$AOSP_ROOT" || die "no AOSP tree at $AOSP_ROOT"
    info "verifying working trees"
    local total=0 repaired=0 blank=0 failed=0 p

    while read -r p; do
        [[ -e "$AOSP_ROOT/$p/.git" ]] || continue
        total=$((total + 1))
        # Anything other than .git means the checkout happened.
        [[ -n "$(ls -A "$AOSP_ROOT/$p" 2>/dev/null | grep -v '^\.git$' | head -1)" ]] && continue

        # Empty on disk. A project with no tracked files is legitimately empty
        # upstream -- AOSP carries a number of placeholder repos -- and must not
        # be reported as damaged.
        if [[ -z "$(git -C "$AOSP_ROOT/$p" ls-files 2>/dev/null | head -1)" ]]; then
            blank=$((blank + 1)); continue
        fi

        if git -C "$AOSP_ROOT/$p" reset --hard HEAD >/dev/null 2>&1; then
            repaired=$((repaired + 1))
        else
            warn "could not restore $p"; failed=$((failed + 1))
        fi
    done < <(repo list -p 2>/dev/null)

    if (( repaired )); then
        ok "restored $repaired project(s) that were fetched but never checked out"
    fi
    (( blank )) && info "$blank project(s) are empty upstream (no tracked files)"
    (( failed )) && die "$failed project(s) could not be restored; try 'repo sync -j$JOBS' again"
    ok "$total project(s) checked out"
}

# ------------------------------------------------------------- kernel ----
sync_kernel() {
    info "kernel -> $KERNEL_SRC"
    if [[ ! -d "$KERNEL_SRC/.git" ]]; then
        local ref_args=()
        if [[ -n "$REFERENCE" && -d "$REFERENCE/linux/.git" ]]; then
            info "borrowing objects from $REFERENCE/linux"
            ref_args=(--reference "$REFERENCE/linux" --dissociate)
        fi
        info "cloning $KERNEL_REMOTE"
        # A failed clone deletes its own partial output, so an interrupted
        # transfer costs everything downloaded so far -- which is why a slow or
        # flaky route makes REFERENCE worth using rather than retrying.
        git clone "${ref_args[@]}" "$KERNEL_REMOTE" "$KERNEL_SRC"
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

# -------------------------------------------------------- pclauncher ----
# Unlike the kernel and AOSP, this one IS a fork we own, so it is checked out on
# a branch rather than detached: the expectation is that it gets committed to
# and pushed from here. PCLAUNCHER_REV records the revision this tree was known
# good at, and is only forced onto the checkout when the working tree is clean
# and unmodified -- clobbering someone's in-progress launcher work to satisfy a
# pin would be a poor trade.
sync_pclauncher() {
    info "pclauncher"

    if [[ ! -d "$PCLAUNCHER_SRC/.git" ]]; then
        info "cloning $PCLAUNCHER_REMOTE"
        mkdir -p "$(dirname "$PCLAUNCHER_SRC")"
        git clone -b "$PCLAUNCHER_BRANCH" "$PCLAUNCHER_REMOTE" "$PCLAUNCHER_SRC" \
            || die "clone failed. This is an SSH remote -- check your GitHub key."
    else
        ok "already cloned"
    fi

    cd "$PCLAUNCHER_SRC"

    if [[ -n "$(git status --porcelain)" ]]; then
        warn "working tree has local changes -- leaving it alone"
        ok "pclauncher at $(git rev-parse --short HEAD) (modified)"
        return
    fi

    if [[ "$(git rev-parse HEAD)" == "$PCLAUNCHER_REV" ]]; then
        ok "already at the pinned revision"
    else
        git cat-file -e "$PCLAUNCHER_REV^{commit}" 2>/dev/null || {
            info "fetching"
            git fetch origin
        }
        # A detached HEAD here would be actively unhelpful: this is a tree that
        # gets developed in. Move the branch instead, but only because the check
        # above established there is nothing to lose.
        info "checking out $PCLAUNCHER_REV"
        git checkout --detach "$PCLAUNCHER_REV" 2>/dev/null \
            || warn "could not reach $PCLAUNCHER_REV -- staying at $(git rev-parse --short HEAD)"
    fi
    ok "pclauncher at $(git rev-parse --short HEAD)"
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
        local project
        # The directory a patch sits in IS its destination, so nothing here has
        # to guess or maintain a lookup table:
        #
        #   patches/linux/*.patch                  -> the kernel clone
        #   patches/android/<project>/*.patch      -> android_17/<project>
        #
        # <project> is the repo manifest project path verbatim, e.g.
        # patches/android/external/minigbm/ applies to external/minigbm. The
        # kernel is separate because it is a plain clone rather than a manifest
        # project, so it does not live under android_17/.
        if [[ "$rel" == linux/* ]]; then
            project="$KERNEL_SRC"
        elif [[ "$rel" == android/*/* ]]; then
            local sub="${rel#android/}"
            project="$AOSP_ROOT/${sub%/*}"
        else
            die "patch in an unexpected place: patches/$rel
     Expected patches/linux/<patch> or patches/android/<project path>/<patch>,
     where <project path> is the repo manifest path (e.g. external/minigbm)."
        fi
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
    all)        sync_aosp; sync_kernel; sync_pclauncher; apply_patches ;;
    aosp)       sync_aosp ;;
    kernel)     sync_kernel ;;
    pclauncher) sync_pclauncher ;;
    patches)    apply_patches ;;
    verify)     verify_checkouts ;;
    *)          die "unknown target: $1  (all | aosp | kernel | pclauncher | patches | verify)" ;;
esac

echo
ok "sources ready"
echo "    next:  ./build.sh all     (kernel + android)"
