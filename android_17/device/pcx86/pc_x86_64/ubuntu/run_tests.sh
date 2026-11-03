#!/usr/bin/env bash
#
# Build and run the ubuntu_lib host tests with the host compiler. No AOSP build
# needed; the same sources also build as the Soong host test
# pc_ubuntu_launch_test.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cc -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
   -o "$out/ubuntu_lib_test" "$here/ubuntu_lib.c" "$here/ubuntu_lib_test.c"
TMPDIR="$out" "$out/ubuntu_lib_test"
