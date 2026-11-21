#!/bin/bash
# build-kernel.sh — T2 パッチ済みカーネルを .deb 化する (GitHub Actions / ローカル共通)
#
# 方式A: mainline ソース + linux-t2-patches (バージョン対応ブランチ) + defconfig
#         + t2 の extra_config + 当リポジトリの config-fragment をマージ。
# 検証済み: linux-6.18.56 に対し 6.18 ブランチの全24パッチが無競合で適用できる
#           (patch-apply-verification-6.18.56.txt)。
#
# 使い方: KVER=6.18.56 PATCH_BRANCH=6.18 ./scripts/build-kernel.sh
# 成果物: ../out/*.deb (linux-image / linux-headers)
set -euo pipefail

KVER="${KVER:-6.18.56}"
PATCH_BRANCH="${PATCH_BRANCH:-6.18}"
LOCALVERSION="${LOCALVERSION:--t2-pve}"
WORK="$(pwd)/build"
OUT="$(pwd)/out"
MAJOR="$(echo "$KVER" | cut -d. -f1)"

mkdir -p "$WORK" "$OUT"
cd "$WORK"

# --- ソース取得 (sha256 は kernel.org の一覧と照合) ---
if [ ! -f "linux-${KVER}.tar.xz" ]; then
  curl -sLO "https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-${KVER}.tar.xz"
  curl -sL "https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/sha256sums.asc" \
    | grep "linux-${KVER}.tar.xz" | sha256sum -c -
fi
[ -d "linux-${KVER}" ] || tar -xf "linux-${KVER}.tar.xz"
[ -d linux-t2-patches ] || git clone --depth 1 --branch "$PATCH_BRANCH" \
  https://github.com/t2linux/linux-t2-patches.git

# --- パッチ適用 (番号順に全て。1つでも失敗したら止まる) ---
cd "linux-${KVER}"
git init -q . 2>/dev/null || true
git config user.email "ci@t2.local" ; git config user.name "t2-ci"
for p in ../linux-t2-patches/*.patch; do
  echo "apply: $(basename "$p")"
  git apply --whitespace=nowarn "$p"
done

# --- config: defconfig + t2 extra_config + 当リポジトリの fragment ---
make defconfig
./scripts/kconfig/merge_config.sh -m .config \
  ../linux-t2-patches/extra_config \
  ../../config-fragment.txt
make olddefconfig

# --- 必須 config の表明 (1つでも欠けたらビルド失敗にする) ---
missing=0
while read -r sym; do
  [ -z "$sym" ] && continue
  case "$sym" in \#*) continue;; esac
  if ! grep -Eq "^${sym}=(y|m)$" .config; then
    echo "MISSING CONFIG: $sym" >&2; missing=1
  fi
done < ../../config-required.txt
[ "$missing" -eq 0 ] || { echo "config assertion failed" >&2; exit 1; }

# --- ビルド & .deb 化 ---
make -j"$(nproc)" bindeb-pkg \
  LOCALVERSION="$LOCALVERSION" \
  KDEB_PKGVERSION="${KVER}-1" \
  DPKG_FLAGS="-d"

mv ../*.deb "$OUT/" 2>/dev/null || mv ./*.deb "$OUT/" 2>/dev/null || \
  find .. -maxdepth 2 -name '*.deb' -exec mv {} "$OUT/" \;
echo "=== artifacts ==="
ls -lh "$OUT"
