#!/usr/bin/env bash
set -Eeuo pipefail

ARMBIAN_DIR="${1:?Usage: seed-kernel-4.4-direct.sh /path/to/armbian-build}"
KERNEL_REPOSITORY="${RK322X_KERNEL_REPOSITORY:-https://github.com/armbian/linux.git}"
KERNEL_BRANCH="${RK322X_KERNEL_BRANCH:-stable-4.4-rk3288-linux-v2.x}"
CACHE_DIR="$ARMBIAN_DIR/cache/git-bare/shallow-kernel-4.4"
MARKER="$CACHE_DIR/.git/armbian-bare-tree-done"
TMP_DIR="${CACHE_DIR}.direct-clone.tmp"

[[ -d "$ARMBIAN_DIR/.git" ]] || {
    echo "Not an Armbian build checkout: $ARMBIAN_DIR" >&2
    exit 1
}

if [[ -f "$MARKER" ]] && git -C "$CACHE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "==> Reusing direct Linux 4.4 cache: $CACHE_DIR"
    exit 0
fi

# Remove only an incomplete cache for this obsolete kernel line. Never touch a
# valid full Armbian kernel cache shared by other builds.
rm -rf "$TMP_DIR"
if [[ -e "$CACHE_DIR" ]]; then
    echo "==> Removing incomplete Linux 4.4 shallow cache"
    rm -rf "$CACHE_DIR"
fi
mkdir -p "$(dirname "$CACHE_DIR")"

cat <<EOF2
==> Seeding Linux 4.4 directly from Git
    repository: $KERNEL_REPOSITORY
    branch:     $KERNEL_BRANCH
    cache:      $CACHE_DIR
EOF2

# Armbian hard-codes "master" as the initial branch when it creates the kernel
# worktree. Seed that branch at the fetched vendor commit, but leave the cache
# working tree itself empty.
git init --initial-branch=master "$TMP_DIR"
git -C "$TMP_DIR" remote add origin "$KERNEL_REPOSITORY"
git -C "$TMP_DIR" \
    -c http.version=HTTP/1.1 \
    -c protocol.version=2 \
    fetch --depth=1 --no-tags origin \
    "refs/heads/$KERNEL_BRANCH:refs/remotes/origin/$KERNEL_BRANCH"

FETCHED_COMMIT="$(git -C "$TMP_DIR" rev-parse "refs/remotes/origin/$KERNEL_BRANCH")"
git -C "$TMP_DIR" update-ref refs/heads/master "$FETCHED_COMMIT"

git -C "$TMP_DIR" config gc.auto 0
git -C "$TMP_DIR" config fetch.writeCommitGraph false
touch "$TMP_DIR/.git/armbian-bare-tree-done"
mv "$TMP_DIR" "$CACHE_DIR"

echo "==> Direct Linux 4.4 cache is ready"
