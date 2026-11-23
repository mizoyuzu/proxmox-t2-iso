#!/bin/bash
# build-kernel.sh — T2 パッチ済みカーネルを .deb 化する (GitHub Actions / ローカル共通)
#
# 方式A: mainline ソース + linux-t2-patches の固定コミット + defconfig
#         + t2 の extra_config + 当リポジトリの config-fragment をマージ。
#
# 使い方: KVER=6.18.56 PATCH_COMMIT=bf06511b536a75fcea3146aa341f183c2a2daebc \
#         KDEB_REVISION=2 ./scripts/build-kernel.sh
# PATCH_COMMIT は意図的なカーネル更新時だけ明示的に変更する。
# 成果物: ./out/*.deb (linux-image / linux-headers)
set -euo pipefail
export LC_ALL=C

KVER="${KVER:-6.18.56}"
KDEB_REVISION="${KDEB_REVISION:-1}"
PATCH_COMMIT="${PATCH_COMMIT:-bf06511b536a75fcea3146aa341f183c2a2daebc}"
LOCALVERSION="${LOCALVERSION:--t2-pve}"
REPO_ROOT="$(pwd)"
WORK="$REPO_ROOT/build"
OUT="$REPO_ROOT/out"
PATCH_REPO_URL="https://github.com/t2linux/linux-t2-patches.git"

if ! [[ "$KVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "KVER must be a numeric major.minor.patch version" >&2
  exit 1
fi
if ! [[ "$PATCH_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "PATCH_COMMIT must be a full 40-character lowercase git commit SHA" >&2
  exit 1
fi

MAJOR="${KVER%%.*}"
mkdir -p "$WORK" "$OUT"

CHECKSUM_TMP=""
ARCHIVE_TMP=""
BUILD_TMP=""
cleanup() {
  [ -z "$CHECKSUM_TMP" ] || rm -f -- "$CHECKSUM_TMP"
  [ -z "$ARCHIVE_TMP" ] || rm -f -- "$ARCHIVE_TMP"
  [ -z "$BUILD_TMP" ] || rm -rf -- "$BUILD_TMP"
}
trap cleanup EXIT

download() {
  curl --fail --location --retry 3 --retry-all-errors --silent --show-error \
    --output "$2" "$1"
}

kernel_tar="linux-${KVER}.tar.xz"
kernel_url="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/${kernel_tar}"
checksums_url="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/sha256sums.asc"
CHECKSUM_TMP="$(mktemp "$WORK/.sha256sums.XXXXXX")"
download "$checksums_url" "$CHECKSUM_TMP"

# Extract exactly one SHA256 entry for this archive from kernel.org's signed list.
expected_sha256="$(awk -v filename="$kernel_tar" \
  '$2 == filename || $2 == "*" filename { print $1; count++ }
   END { if (count != 1) exit 1 }' "$CHECKSUM_TMP")" || {
  echo "Could not find exactly one checksum for ${kernel_tar} in kernel.org sha256sums.asc" >&2
  exit 1
}
if ! [[ "$expected_sha256" =~ ^[[:xdigit:]]{64}$ ]]; then
  echo "Invalid SHA256 entry for ${kernel_tar} in kernel.org sha256sums.asc" >&2
  exit 1
fi

kernel_archive="$WORK/$kernel_tar"
archive_is_valid=0
if [ -f "$kernel_archive" ] && \
  printf '%s  %s\n' "$expected_sha256" "$kernel_archive" | sha256sum --check --status; then
  archive_is_valid=1
fi

if [ "$archive_is_valid" -eq 1 ]; then
  echo "Using SHA256-verified cached ${kernel_tar}"
else
  if [ -e "$kernel_archive" ]; then
    echo "Cached ${kernel_tar} failed SHA256 verification; downloading a fresh copy" >&2
  else
    echo "Downloading ${kernel_tar}"
  fi
  ARCHIVE_TMP="$(mktemp "$WORK/.${kernel_tar}.XXXXXX")"
  download "$kernel_url" "$ARCHIVE_TMP"
  if ! printf '%s  %s\n' "$expected_sha256" "$ARCHIVE_TMP" | sha256sum --check; then
    echo "Downloaded ${kernel_tar} failed SHA256 verification" >&2
    exit 1
  fi
  mv -f -- "$ARCHIVE_TMP" "$kernel_archive"
  ARCHIVE_TMP=""
fi

# Keep this build's patch checkout, kernel source, and generated packages in one
# private tree. Only the SHA-verified source archive is cached between attempts.
BUILD_TMP="$(mktemp -d "$WORK/kernel-build-${KVER}.XXXXXX")"
patch_checkout="$BUILD_TMP/linux-t2-patches"
mkdir -p "$patch_checkout"
git -C "$patch_checkout" init -q
git -C "$patch_checkout" fetch --quiet --depth=1 "$PATCH_REPO_URL" "$PATCH_COMMIT"
git -C "$patch_checkout" checkout --quiet --detach FETCH_HEAD
if [ "$(git -C "$patch_checkout" rev-parse HEAD)" != "$PATCH_COMMIT" ]; then
  echo "Fetched linux-t2-patches commit does not match PATCH_COMMIT=${PATCH_COMMIT}" >&2
  exit 1
fi
echo "Using linux-t2-patches commit ${PATCH_COMMIT}"

version_file="$patch_checkout/version"
expected_version="KVER=${KVER}"
if [ ! -f "$version_file" ] || ! printf '%s\n' "$expected_version" | cmp -s - "$version_file"; then
  actual_version="(missing)"
  [ ! -f "$version_file" ] || actual_version="$(cat "$version_file")"
  echo "linux-t2-patches ${PATCH_COMMIT} version must be exactly '${expected_version}', got '${actual_version}'" >&2
  exit 1
fi

shopt -s nullglob
patches=("$patch_checkout"/*.patch)
shopt -u nullglob
if [ "${#patches[@]}" -eq 0 ]; then
  echo "No kernel patches found in linux-t2-patches ${PATCH_COMMIT}" >&2
  exit 1
fi
if [ ! -f "$patch_checkout/extra_config" ]; then
  echo "linux-t2-patches ${PATCH_COMMIT} is missing extra_config" >&2
  exit 1
fi

tar -xf "$kernel_archive" -C "$BUILD_TMP"
kernel_source="$BUILD_TMP/linux-${KVER}"
if [ ! -d "$kernel_source" ]; then
  echo "Kernel archive did not contain linux-${KVER}/" >&2
  exit 1
fi

# --- パッチ適用 (ファイル名順に全て。1つでも失敗したら止まる) ---
cd "$kernel_source"
git init -q .
git config user.email "ci@t2.local"
git config user.name "t2-ci"
for p in "${patches[@]}"; do
  echo "apply: $(basename "$p")"
  git apply --whitespace=nowarn "$p"
done

# --- config: defconfig + t2 extra_config + 当リポジトリの fragment ---
make defconfig
./scripts/kconfig/merge_config.sh -m .config \
  "$patch_checkout/extra_config" \
  "$REPO_ROOT/config-fragment.txt"
make olddefconfig

# --- 必須 config の表明 (1つでも欠けたらビルド失敗にする) ---
missing=0
while read -r sym; do
  [ -z "$sym" ] && continue
  case "$sym" in \#*) continue;; esac
  if ! grep -Eq "^${sym}=(y|m)$" .config; then
    echo "MISSING CONFIG: $sym" >&2; missing=1
  fi
done < "$REPO_ROOT/config-required.txt"
[ "$missing" -eq 0 ] || { echo "config assertion failed" >&2; exit 1; }

# --- ビルド & .deb 化 ---
KDEB_PKGVERSION="${KVER}-${KDEB_REVISION}"
echo "Building kernel packages with package version ${KDEB_PKGVERSION}"
make -j"$(nproc)" bindeb-pkg \
  LOCALVERSION="$LOCALVERSION" \
  KDEB_PKGVERSION="$KDEB_PKGVERSION" \
  DPKG_FLAGS="-d"

# bindeb-pkg places packages in kernel_source's parent. Collect only packages
# emitted by this isolated run, so stale .debs in build/ cannot be published.
shopt -s nullglob
packages=("$BUILD_TMP"/*.deb)
image_packages=("$BUILD_TMP"/linux-image-*.deb)
shopt -u nullglob
if [ "${#image_packages[@]}" -eq 0 ]; then
  echo "ERROR: no linux-image-*.deb package was produced" >&2
  exit 1
fi
for package in "${packages[@]}"; do
  mv -f -- "$package" "$OUT/"
done
echo "=== artifacts ==="
ls -lh "$OUT"
