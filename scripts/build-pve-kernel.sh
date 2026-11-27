#!/usr/bin/env bash
# Build pinned Proxmox pve-kernel + t2linux patches as Debian packages in Docker.
# Outputs all packages from this run to ./out/*.deb. This script does not run in
# the regular ISO build; invoke it only through the manually dispatched workflow.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PVE_COMMIT="${PVE_COMMIT:-1cc9d3c72dff80f433cf090707c52c477d920540}"
T2_COMMIT="${T2_COMMIT:-7214248ed18659d576cc3a7feda20329d1eefc6f}"
REVISION="${REVISION:-1}"
PVE_REPO_URL="https://git.proxmox.com/git/pve-kernel.git"
T2_REPO_URL="https://github.com/t2linux/linux-t2-patches.git"
BUILD_ROOT="${BUILD_ROOT:-$REPO_ROOT/build/pve-kernel}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$PVE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "PVE_COMMIT must be a full lowercase 40-character SHA"
[[ "$T2_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "T2_COMMIT must be a full lowercase 40-character SHA"
[[ "$REVISION" =~ ^[1-9][0-9]*$ ]] || fail "REVISION must be a positive integer"
command -v git >/dev/null || fail "git is required"
command -v docker >/dev/null || fail "Docker is required"

mkdir -p -- "$BUILD_ROOT"
BUILD_TMP="$(mktemp -d "$BUILD_ROOT/run.XXXXXX")"
cleanup() {
  rm -rf -- "$BUILD_TMP"
}
trap cleanup EXIT

PVE_DIR="$BUILD_TMP/pve-kernel"
T2_DIR="$BUILD_TMP/linux-t2-patches"
ARTIFACT_STAGE="$BUILD_TMP/artifacts"
mkdir -p -- "$ARTIFACT_STAGE"

echo "Fetching pve-kernel commit $PVE_COMMIT"
git init -q "$PVE_DIR"
git -C "$PVE_DIR" remote add origin "$PVE_REPO_URL"
if git -C "$PVE_DIR" fetch --depth=1 origin "$PVE_COMMIT"; then
  git -C "$PVE_DIR" checkout --quiet --detach FETCH_HEAD
else
  echo "Pinned SHA fetch was rejected; falling back to a full clone and checkout" >&2
  rm -rf -- "$PVE_DIR"
  git clone "$PVE_REPO_URL" "$PVE_DIR"
  git -C "$PVE_DIR" checkout --quiet --detach "$PVE_COMMIT"
fi
actual_pve_commit="$(git -C "$PVE_DIR" rev-parse HEAD)"
[[ "$actual_pve_commit" == "$PVE_COMMIT" ]] || \
  fail "pve-kernel HEAD is $actual_pve_commit, expected $PVE_COMMIT"

echo "Fetching linux-t2-patches commit $T2_COMMIT"
git init -q "$T2_DIR"
git -C "$T2_DIR" remote add origin "$T2_REPO_URL"
git -C "$T2_DIR" fetch --depth=1 origin "$T2_COMMIT"
git -C "$T2_DIR" checkout --quiet --detach FETCH_HEAD
actual_t2_commit="$(git -C "$T2_DIR" rev-parse HEAD)"
[[ "$actual_t2_commit" == "$T2_COMMIT" ]] || \
  fail "linux-t2-patches HEAD is $actual_t2_commit, expected $T2_COMMIT"

# These two patches are already present in the pinned Ubuntu kernel source.
rm -f -- \
  "$T2_DIR/2008-i915-4-lane-quirk-for-mbp15-1.patch" \
  "$T2_DIR/7002-drm-amdgpu-reset-VI-ASIC-on-MacBookPro15-1.patch"
shopt -s nullglob
t2_patches=("$T2_DIR"/*.patch)
shopt -u nullglob
(( ${#t2_patches[@]} > 0 )) || fail "No t2linux patches remain after excluding duplicate patches"
mkdir -p -- "$PVE_DIR/patches/kernel"
cp -- "${t2_patches[@]}" "$PVE_DIR/patches/kernel/"

git -C "$PVE_DIR" config user.email "ci@t2.local"
git -C "$PVE_DIR" config user.name "T2 kernel builder"
git -C "$PVE_DIR" am "$REPO_ROOT/T2.patch"

echo "Building packages in debian:trixie (revision $REVISION)"
docker run --privileged --rm -i \
  --mount "type=bind,source=$PVE_DIR,target=/repo" \
  --workdir /repo \
  --env "HOST_UID=$(id -u)" \
  --env "HOST_GID=$(id -g)" \
  debian:trixie /bin/bash -euo pipefail -s <<'CONTAINER'
set -euo pipefail
container_cleanup() {
  status=$?
  chown -R "$HOST_UID:$HOST_GID" /repo 2>/dev/null || true
  exit "$status"
}
trap container_cleanup EXIT

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates wget

cat > /etc/apt/sources.list.d/pve-install-repo.sources <<'SOURCES'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
SOURCES
wget --quiet https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
  --output-document=/usr/share/keyrings/proxmox-archive-keyring.gpg
apt-get update
apt-get install -y --no-install-recommends \
  asciidoc-base automake bc bison bindgen build-essential cpio debhelper dh-python file flex \
  gcc git gawk kmod libdw-dev libelf-dev libiberty-dev libnuma-dev libpve-common-perl \
  libslang2-dev libssl-dev libtool lintian lz4 dwarves perl-modules python3-dev \
  rsync rustc rust-src rustfmt rust-clippy sed sphinx-common tar xmlto zlib1g-dev zstd

git config --global --add safe.directory '*'
git submodule update --depth 1 --init submodules/ubuntu-kernel
git submodule update --init --recursive submodules/zfsonlinux
make deb
CONTAINER

shopt -s nullglob
packages=("$PVE_DIR"/*.deb)
image_packages=("$PVE_DIR"/proxmox-kernel-*-pve-t2_*.deb)
shopt -u nullglob
(( ${#packages[@]} > 0 )) || fail "make deb did not produce any .deb packages"
(( ${#image_packages[@]} == 1 )) || \
  fail "expected exactly one proxmox-kernel-*-pve-t2 image package, found ${#image_packages[@]}"

cp -- "${packages[@]}" "$ARTIFACT_STAGE/"
"$SCRIPT_DIR/verify-pve-kernel.sh" "$ARTIFACT_STAGE/$(basename -- "${image_packages[0]}")"

mkdir -p -- "$OUT_DIR"
cp -f -- "$ARTIFACT_STAGE"/*.deb "$OUT_DIR/"
echo "=== PVE T2 kernel packages ==="
ls -lh -- "$OUT_DIR"/*.deb
