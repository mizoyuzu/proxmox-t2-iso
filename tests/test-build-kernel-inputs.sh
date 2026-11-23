#!/usr/bin/env bash
# Offline regression fixture for immutable patch selection, archive verification,
# fresh source extraction, and the patch repo's exact KVER declaration.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

project="$fixture/project"
bin="$fixture/bin"
archive_root="$fixture/archive-root"
patch_repo="$fixture/patch-repo"
mkdir -p "$project/scripts" "$bin" "$archive_root/linux-1.2.3" "$patch_repo"
cp "$repo_root/scripts/build-kernel.sh" "$project/scripts/build-kernel.sh"
cp "$repo_root/config-fragment.txt" "$project/config-fragment.txt"
cp "$repo_root/config-required.txt" "$project/config-required.txt"

printf 'base\n' > "$archive_root/linux-1.2.3/README"
mkdir -p "$archive_root/linux-1.2.3/scripts/kconfig"
cat > "$archive_root/linux-1.2.3/scripts/kconfig/merge_config.sh" <<'MERGE'
#!/usr/bin/env bash
exit 0
MERGE
chmod +x "$archive_root/linux-1.2.3/scripts/kconfig/merge_config.sh"
tar -C "$archive_root" -cJf "$fixture/linux-1.2.3.tar.xz" linux-1.2.3
archive_sha="$(sha256sum "$fixture/linux-1.2.3.tar.xz" | awk '{print $1}')"
printf '%s  linux-1.2.3.tar.xz\n' "$archive_sha" > "$fixture/sha256sums.asc"

real_git="$(command -v git)"
"$real_git" -C "$patch_repo" init -q
"$real_git" -C "$patch_repo" config user.email fixture@example.invalid
"$real_git" -C "$patch_repo" config user.name fixture
printf 'KVER=1.2.3\n' > "$patch_repo/version"
: > "$patch_repo/extra_config"
cat > "$patch_repo/1000-fixture.patch" <<'PATCH'
diff --git a/README b/README
--- a/README
+++ b/README
@@ -1 +1 @@
-base
+PINNED
PATCH
"$real_git" -C "$patch_repo" add version extra_config 1000-fixture.patch
"$real_git" -C "$patch_repo" commit -qm 'fixture pinned patch set'
pinned_commit="$("$real_git" -C "$patch_repo" rev-parse HEAD)"
sed -i 's/PINNED/MOVING/' "$patch_repo/1000-fixture.patch"
"$real_git" -C "$patch_repo" add 1000-fixture.patch
"$real_git" -C "$patch_repo" commit -qm 'fixture moving branch update'

cat > "$bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
output=""
url="${@: -1}"
while (($#)); do
  case "$1" in
    --output|-o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$url" in
  */sha256sums.asc) cp "$FIXTURE_CHECKSUMS" "$output" ;;
  */linux-1.2.3.tar.xz)
    if [[ "${FAIL_KERNEL_DOWNLOAD:-0}" == 1 && ! -e "$FAIL_MARKER" ]]; then
      printf 'partial fetch\n' > "$output"
      : > "$FAIL_MARKER"
      exit 22
    fi
    cp "$FIXTURE_ARCHIVE" "$output"
    ;;
  *) echo "unexpected fixture URL: $url" >&2; exit 1 ;;
esac
CURL

cat > "$bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
for i in "${!args[@]}"; do
  if [[ "${args[$i]}" == https://github.com/t2linux/linux-t2-patches.git ]]; then
    args[$i]="$FIXTURE_PATCH_REPO"
  fi
done
exec "$REAL_GIT" "${args[@]}"
GIT

cat > "$bin/make" <<'MAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MAKE_LOG"
printf '%s\n' "$(cat README)" > "$PATCH_RESULT_FILE"
case "$*" in
  defconfig)
    awk '!/^#/ && NF { print $1 "=m" }' "$CONFIG_REQUIRED" > .config
    ;;
  *bindeb-pkg*)
    printf 'fixture image package\n' > ../linux-image-fixture.deb
    printf 'fixture headers package\n' > ../linux-headers-fixture.deb
    ;;
esac
MAKE
chmod +x "$bin/curl" "$bin/git" "$bin/make" "$project/scripts/build-kernel.sh"

export PATH="$bin:$PATH"
export REAL_GIT="$real_git"
export FIXTURE_PATCH_REPO="$patch_repo"
export FIXTURE_CHECKSUMS="$fixture/sha256sums.asc"
export FIXTURE_ARCHIVE="$fixture/linux-1.2.3.tar.xz"
export FAIL_MARKER="$fixture/fail-first-download"
export MAKE_LOG="$fixture/make.log"
export PATCH_RESULT_FILE="$fixture/applied-patch-result"
export CONFIG_REQUIRED="$project/config-required.txt"
export KVER=1.2.3
export PATCH_COMMIT="$pinned_commit"

run_builder() {
  if ! (cd "$project" && ./scripts/build-kernel.sh > "$fixture/latest.log" 2>&1); then
    cat "$fixture/latest.log" >&2
    echo "fixture build failed unexpectedly" >&2
    exit 1
  fi
}

# A failed download leaves no reusable partial cache; the next run can retry.
status=0
(cd "$project" && FAIL_KERNEL_DOWNLOAD=1 ./scripts/build-kernel.sh > "$fixture/latest.log" 2>&1) || status=$?
if [ "$status" -eq 0 ] || [ -e "$project/build/linux-1.2.3.tar.xz" ]; then
  echo "failed archive fetch was incorrectly accepted or cached" >&2
  exit 1
fi
if compgen -G "$project/build/.linux-1.2.3.tar.xz.*" >/dev/null; then
  echo "partial archive temporary file was not cleaned up" >&2
  exit 1
fi

# The moving fixture branch points at MOVING, but the requested commit is PINNED.
# A stale legacy source tree and package in build/ must not affect this run.
mkdir -p "$project/build/linux-1.2.3"
printf 'STALE\n' > "$project/build/linux-1.2.3/README"
printf 'stale package\n' > "$project/build/linux-image-stale.deb"
run_builder
if [ "$(cat "$PATCH_RESULT_FILE")" != PINNED ]; then
  echo "builder did not use the requested immutable patch commit" >&2
  exit 1
fi
grep -q "Using linux-t2-patches commit ${pinned_commit}" "$fixture/latest.log"
test -f "$project/out/linux-image-fixture.deb"
test -f "$project/out/linux-headers-fixture.deb"
if [ -e "$project/out/linux-image-stale.deb" ]; then
  echo "builder collected a stale package from the shared build cache" >&2
  exit 1
fi

# A valid cached archive is checksum-verified and reused on every run.
printf 'STALE ON VERIFIED CACHE RUN\n' > "$project/build/linux-1.2.3/README"
run_builder
grep -q "Using SHA256-verified cached linux-1.2.3.tar.xz" "$fixture/latest.log"
if [ "$(cat "$PATCH_RESULT_FILE")" != PINNED ]; then
  echo "builder reused a stale source tree with a valid archive cache" >&2
  exit 1
fi

# A corrupted archive cache and stale source tree are replaced safely.
printf 'STALE AGAIN\n' > "$project/build/linux-1.2.3/README"
printf 'corrupt archive cache\n' > "$project/build/linux-1.2.3.tar.xz"
run_builder
if [ "$(cat "$PATCH_RESULT_FILE")" != PINNED ]; then
  echo "builder reused a stale patched source tree" >&2
  exit 1
fi
grep -q 'failed SHA256 verification; downloading a fresh copy' "$fixture/latest.log"
grep -q "Using linux-t2-patches commit ${pinned_commit}" "$fixture/latest.log"

# Version metadata is data, not shell code, and must match the requested KVER.
printf 'KVER=9.9.9\n' > "$patch_repo/version"
"$real_git" -C "$patch_repo" add version
"$real_git" -C "$patch_repo" commit -qm 'fixture mismatched version declaration'
export PATCH_COMMIT="$("$real_git" -C "$patch_repo" rev-parse HEAD)"
status=0
(cd "$project" && ./scripts/build-kernel.sh > "$fixture/latest.log" 2>&1) || status=$?
if [ "$status" -eq 0 ] || ! grep -q "must be exactly 'KVER=1.2.3'" "$fixture/latest.log"; then
  cat "$fixture/latest.log" >&2
  echo "builder did not reject a patch commit with a mismatched version file" >&2
  exit 1
fi
if grep -q '^apply:' "$fixture/latest.log"; then
  echo "builder applied patches before checking the version declaration" >&2
  exit 1
fi

echo 'PASS: pinned patch selection, exact version check, verified archive retry, and fresh source extraction.'
