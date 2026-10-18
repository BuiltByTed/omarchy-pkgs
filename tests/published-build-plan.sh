#!/bin/bash
# build/build.sh's dry-run plan, which publish.yml reads to decide what to
# build: it builds new versions and releases, and skips a version the channel
# already indexes or still holds as an older archive.
set -euo pipefail
BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/pkgbuilds"
cp -r "$BUILD_ROOT/helpers" "$BUILD_ROOT/build" "$TEST_ROOT/"
unset OMARCHY_RC_PINS OMARCHY_DEFER_RUNTIME_DEPS

fixture() {
  local name=$1 version=$2 release=$3
  mkdir -p "$TEST_ROOT/pkgbuilds/$name/.omarchy"
  printf '{"source":"local","channels":["edge"]}\n' > "$TEST_ROOT/pkgbuilds/$name/.omarchy/package.json"
  cat > "$TEST_ROOT/pkgbuilds/$name/PKGBUILD" <<EOF
pkgname=$name
pkgver=$version
pkgrel=$release
arch=('x86_64' 'aarch64')
EOF
}
fixture omarchy 4.0.3 1
fixture omarchy-settings 4.0.3 1
fixture current 1 1
fixture update 2 1
fixture rebuild 1 2
fixture unindexed 1 1
fixture signature-only 1 1
fixture other-arch 1 1
fixture new-package 1 1

db_entry() {
  local name=$1 version=$2
  mkdir -p "$TEST_ROOT/db/$name-$version"
  printf '%%NAME%%\n%s\n\n%%BASE%%\n%s\n\n%%VERSION%%\n%s\n' "$name" "$name" "$version" > "$TEST_ROOT/db/$name-$version/desc"
}
db_entry omarchy 4.0.4rc1-1
db_entry omarchy-settings 4.0.4rc1-1
for package in current update rebuild; do db_entry "$package" 1-1; done
printf '%s\n' new-package other-arch rebuild signature-only update | sort > "$TEST_ROOT/expected"

for arch in x86_64 aarch64; do
  repo="$TEST_ROOT/pkgs.omarchy.org/edge/$arch"
  mkdir -p "$repo"
  tar --zstd -cf "$repo/omarchy.db.tar.zst" -C "$TEST_ROOT/db" .
  touch "$repo/omarchy-4.0.3-1-$arch.pkg.tar.zst"
  touch "$repo/omarchy-settings-4.0.3-1-any.pkg.tar.xz"
  touch "$repo/unindexed-1-1-$arch.pkg.tar.zst"
  touch "$repo/rebuild-1-1-$arch.pkg.tar.zst"
  touch "$repo/signature-only-1-1-$arch.pkg.tar.zst.sig"
  other=x86_64
  [[ "$arch" == x86_64 ]] && other=aarch64
  touch "$repo/other-arch-1-1-$other.pkg.tar.zst"


  for selection in '' 'omarchy omarchy-settings current update rebuild unindexed signature-only other-arch new-package'; do
    ARCH="$arch" MIRROR=edge DRY_RUN=true PACKAGES="$selection" \
      PKGBUILDS_DIR="$TEST_ROOT/pkgbuilds" HELPERS_DIR="$TEST_ROOT/helpers" \
      FINAL_OUTPUT_DIR="$repo" BUILD_PLAN_DIR="$TEST_ROOT/plan" \
      "$TEST_ROOT/build/build.sh" > "$TEST_ROOT/plan.log" 2>&1
    sort "$TEST_ROOT/plan/packages" > "$TEST_ROOT/planned"
    diff -u "$TEST_ROOT/expected" "$TEST_ROOT/planned"
    grep -q 'omarchy 4.0.3-1 - archive already published' "$TEST_ROOT/plan.log"
  done
  printf 'PASS: %s explicit and unscoped plans skip retained archives, allow new versions and releases\n' "$arch"
done

# A build group (build_with) is planned in one run: bin/build-matrix gives
# bin/build all its members, and publish.yml reads this plan to tell a member
# the channel already holds from one its build must have produced. The
# runtime pins the settings to its exact version, so with both new the
# settings come first.
pair() { # pair <name> <depends>
  mkdir -p "$TEST_ROOT/pkgbuilds/$1/.omarchy"
  printf '{"source":"local","channels":["edge"],"build_with":["%s"]}\n' "$3" > "$TEST_ROOT/pkgbuilds/$1/.omarchy/package.json"
  cat > "$TEST_ROOT/pkgbuilds/$1/PKGBUILD" <<EOF_PKGBUILD
pkgname=$1
pkgver=4.0.5
pkgrel=1
arch=('x86_64' 'aarch64')
depends=($2)
EOF_PKGBUILD
}
pair pair-runtime "'bash' \"pair-settings=\${pkgver}\"" pair-settings
pair pair-settings "'bash'" pair-runtime
# The pin must expand the way omarchy's does: settings at this exact version.
# shellcheck disable=SC1091
(source "$TEST_ROOT/pkgbuilds/pair-runtime/PKGBUILD" && [[ " ${depends[*]} " == *" pair-settings=4.0.5 "* ]]) ||
  { echo "FAIL: the pair fixture pins pair-settings=4.0.5"; exit 1; }
plan_pair() { # plan_pair <arch> <repo>: the packages the plan builds, in order
  rm -rf "$TEST_ROOT/plan"
  ARCH="$1" MIRROR=edge DRY_RUN=true PACKAGES="pair-runtime pair-settings" \
    PKGBUILDS_DIR="$TEST_ROOT/pkgbuilds" HELPERS_DIR="$TEST_ROOT/helpers" \
    FINAL_OUTPUT_DIR="$2" BUILD_PLAN_DIR="$TEST_ROOT/plan" \
    "$TEST_ROOT/build/build.sh" > "$TEST_ROOT/plan.log" 2>&1
  paste -sd' ' "$TEST_ROOT/plan/packages"
}
for arch in x86_64 aarch64; do
  repo="$TEST_ROOT/pair/$arch"
  rm -rf "$TEST_ROOT/pair-db" "$repo"; mkdir -p "$TEST_ROOT/pair-db" "$repo"
  db_pair() { # db_pair <name> <version>...: the channel indexes these
    rm -rf "$TEST_ROOT/pair-db"/*
    while (( $# )); do
      mkdir -p "$TEST_ROOT/pair-db/$1-$2"
      printf '%%NAME%%\n%s\n\n%%BASE%%\n%s\n\n%%VERSION%%\n%s\n' "$1" "$1" "$2" > "$TEST_ROOT/pair-db/$1-$2/desc"
      shift 2
    done
    tar --zstd -cf "$repo/omarchy.db.tar.zst" -C "$TEST_ROOT/pair-db" .
  }
  db_pair pair-runtime 4.0.4-2 pair-settings 4.0.4-1
  [[ $(plan_pair "$arch" "$repo") == "pair-settings pair-runtime" ]] || { cat "$TEST_ROOT/plan.log"; echo "FAIL: $arch both new: $(plan_pair "$arch" "$repo")"; exit 1; }
  db_pair pair-runtime 4.0.4-2 pair-settings 4.0.5-1
  [[ $(plan_pair "$arch" "$repo") == "pair-runtime" ]] || { echo "FAIL: $arch settings published: $(plan_pair "$arch" "$repo")"; exit 1; }
  db_pair pair-runtime 4.0.4-2 pair-settings 4.0.4-1
  touch "$repo/pair-settings-4.0.5-1-$arch.pkg.tar.zst"
  [[ $(plan_pair "$arch" "$repo") == "pair-runtime" ]] || { echo "FAIL: $arch settings archived: $(plan_pair "$arch" "$repo")"; exit 1; }
  db_pair pair-runtime 4.0.5-1 pair-settings 4.0.5-1
  [[ -z $(plan_pair "$arch" "$repo") ]] || { echo "FAIL: $arch both published: $(plan_pair "$arch" "$repo")"; exit 1; }
  grep -q 'Plan complete. Packages that would build: $' "$TEST_ROOT/plan.log" || { echo "FAIL: $arch both published: no empty plan line"; exit 1; }
  printf 'PASS: %s build group plan: both new in dependency order, one published, both published\n' "$arch"
done
