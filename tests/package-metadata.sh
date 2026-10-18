#!/bin/bash
# Every package's .omarchy/package.json passes validate_package_metadata,
# and a fast-ring package that declares rebuild_on is refused: the fast ring
# ships one edge build to every channel, so nothing rebuilds it when a
# dependency moves.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
source "$ROOT/helpers/package-metadata.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

invalid=()
for pkgdir in "$ROOT"/pkgbuilds/*/; do
  out=$(validate_package_metadata "${pkgdir%/}" 2>&1) || invalid+=("$out")
done
(( ${#invalid[@]} == 0 )) && pass "every package's metadata is valid" || fail "$(printf '%s; ' "${invalid[@]}")"

mkdir -p "$T/fast-rebuild/.omarchy"
echo '{"source": "local", "release_ring": "fast", "rebuild_on": ["qt6-base"]}' > "$T/fast-rebuild/.omarchy/package.json"
out=$(validate_package_metadata "$T/fast-rebuild" 2>&1) && fail "fast ring with rebuild_on accepted"
[[ $out == *"cannot be on the fast ring"* ]] && pass "fast ring with rebuild_on is refused" || fail "unexpected message: $out"

mkdir -p "$T/slow-rebuild/.omarchy"
echo '{"source": "local", "rebuild_on": ["qt6-base"]}' > "$T/slow-rebuild/.omarchy/package.json"
validate_package_metadata "$T/slow-rebuild" >/dev/null && pass "rebuild_on off the fast ring is fine" || fail "rebuild_on alone refused"

# build_with: a reciprocal declaration of packages that build in one job
# (package_build_group). Members are siblings, so the fixtures share $T.
member() { # member <name> <package.json>
  mkdir -p "$T/$1/.omarchy"
  printf "pkgname=%s\npkgver=1\npkgrel=1\narch=('x86_64' 'aarch64')\n" "$1" > "$T/$1/PKGBUILD"
  printf '%s\n' "$2" > "$T/$1/.omarchy/package.json"
}
refused() { # refused <message part> <name>
  local out
  out=$(validate_package_metadata "$T/$2" 2>&1) && fail "$2: accepted"
  [[ $out == *"$1"* ]] || fail "$2: unexpected message: $out"
}
member pair-a '{"source": "local", "build_with": ["pair-b"]}'
member pair-b '{"source": "local", "build_with": ["pair-a"]}'
validate_package_metadata "$T/pair-a" >/dev/null && validate_package_metadata "$T/pair-b" >/dev/null \
  && pass "a reciprocal pair is valid" || fail "reciprocal pair refused: $(validate_package_metadata "$T/pair-a")"
[[ $(package_build_group "$T/pair-b" | paste -sd' ') == "pair-a pair-b" ]] && pass "package_build_group lists the members, sorted" || fail "group: $(package_build_group "$T/pair-b")"
[[ $(package_build_group "$T/slow-rebuild") == slow-rebuild ]] && pass "a package in no group is a group of one" || fail "singleton group"

member one-way '{"source": "local", "build_with": ["pair-a"]}'
refused "does not name one-way back" one-way
member unknown '{"source": "local", "build_with": ["no-such-package"]}'
refused "no-such-package is not a package" unknown
member self '{"source": "local", "build_with": ["self"]}'
refused "invalid build_with for self" self
member twice '{"source": "local", "build_with": ["pair-a", "pair-a"]}'
refused "invalid build_with for twice" twice
member empty '{"source": "local", "build_with": []}'
refused "invalid build_with for empty" empty
member text '{"source": "local", "build_with": "pair-a"}'
refused "invalid build_with for text" text
member any-half '{"source": "local", "build_with": ["arch-half"]}'
sed -i "s/^arch=.*/arch=('any')/" "$T/any-half/PKGBUILD"
member arch-half '{"source": "local", "build_with": ["any-half"]}'
refused "mix arch=any" arch-half
pass "an invalid build_with declaration is refused"
