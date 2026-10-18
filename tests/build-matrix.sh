#!/bin/bash
# Self-test for the runner each build gets (package_runner, and the "runner"
# field bin/build-matrix puts on every entry): aarch64 kernels on the large
# arm64 machine, everything else where it was.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
BUILD_ROOT="$ROOT"
source "$ROOT/helpers/paths.sh"
source "$ROOT/helpers/package-metadata.sh"
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

DROPLET='["self-hosted","omarchy-builder"]'
GITHUB_ARM='["ubuntu-24.04-arm"]'
KERNEL_ARM='["namespace-profile-arm64-linux-apple-12x32"]'

check() {
  local want="$1" name="$2" arch="$3" got
  got=$(package_runner "$name" "$arch")
  [[ $got == "$want" ]] || fail "$name on $arch builds on $got, expected $want"
}

for kernel in linux-omarchy-n1x linux-n1x linux-aurora linux-omarchy; do
  check "$KERNEL_ARM" "$kernel" aarch64
done
pass "an aarch64 kernel builds on the Apple-backed runner at Namespace"

for kernel in linux-omarchy linux-omarchy-bore linux-ptl; do
  check "$DROPLET" "$kernel" x86_64
done
pass "an x86_64 kernel stays on the droplet pool"

check "$GITHUB_ARM" linux-aarch64-pkgbase-shim aarch64
check "$GITHUB_ARM" linux-firmware-cirrus-dx13260 aarch64
pass "a linux-* package that is no kernel stays on GitHub's arm64 runner"

for package in omarchy-settings gliff hyprland nvidia-open-dkms alinux; do
  check "$GITHUB_ARM" "$package" aarch64
  check "$DROPLET" "$package" x86_64
done
pass "every other package builds where it did"

# Each value has to be what runs-on takes: a JSON list of labels.
for runner in "$DROPLET" "$GITHUB_ARM" "$KERNEL_ARM"; do
  jq -e 'type == "array" and length > 0 and all(type == "string")' <<<"$runner" >/dev/null || fail "not a list of labels: $runner"
done
pass "every runner is a JSON list of labels"

# The matrix carries the rule: every entry names its runner, and it is the
# one package_runner gives for that package and architecture.
matrix=$("$ROOT/bin/build-matrix" linux-aurora linux-aarch64-pkgbase-shim omarchy-settings)
[[ $(jq '.include | length' <<<"$matrix") -ge 4 ]] || fail "matrix: $matrix"
while read -r package arch runner; do
  [[ $runner == "$(package_runner "$package" "$arch")" ]] || fail "matrix entry $package $arch has runner $runner"
done < <(jq -r '.include[] | "\(.package | split(" ") | .[0]) \(.arch) \(.runner)"' <<<"$matrix")
[[ $(jq -r '.include[] | select(.package == "linux-aurora") | .runner' <<<"$matrix") == "$KERNEL_ARM" ]] || fail "linux-aurora in the matrix: $matrix"
pass "bin/build-matrix puts the runner on every entry"

# Build groups (build_with): a fixture tree, so these cases do not move with
# the real packages. bin/build-matrix reads pkgbuilds/ next to its own bin/.
F=$(mktemp -d); trap 'rm -rf "$F"' EXIT
mkdir -p "$F/bin"
cp -r "$ROOT/helpers" "$F/"
cp "$ROOT/bin/build-matrix" "$F/bin/"
fixture() { # fixture <name> <arch...> -- <package.json>
  local name=$1 arches=()
  shift
  while [[ $1 != -- ]]; do arches+=("'$1'"); shift; done
  mkdir -p "$F/pkgbuilds/$name/.omarchy"
  printf 'pkgname=%s\npkgver=1\npkgrel=1\narch=(%s)\n' "$name" "${arches[*]}" > "$F/pkgbuilds/$name/PKGBUILD"
  printf '%s\n' "$2" > "$F/pkgbuilds/$name/.omarchy/package.json"
}
fixture runtime x86_64 aarch64 -- '{"source":"local","build_with":["settings"]}'
fixture settings x86_64 aarch64 -- '{"source":"local","build_with":["runtime"]}'
fixture single x86_64 aarch64 -- '{"source":"local"}'
fixture anyone any -- '{"source":"local"}'
matrix_for() { printf '%s\n' "$@" | "$F/bin/build-matrix"; }

want='{"include":[{"package":"single","arch":"x86_64","channels":"edge","publish_arches":"x86_64","runner":"[\"self-hosted\",\"omarchy-builder\"]"},{"package":"single","arch":"aarch64","channels":"edge","publish_arches":"aarch64","runner":"[\"ubuntu-24.04-arm\"]"},{"package":"anyone","arch":"x86_64","channels":"edge","publish_arches":"x86_64 aarch64","runner":"[\"self-hosted\",\"omarchy-builder\"]"}]}'
[[ $(matrix_for single anyone) == "$want" ]] || fail "singletons changed: $(matrix_for single anyone)"
pass "a package in no group gets exactly the entries it always did"

for named in runtime settings "settings runtime" "runtime settings runtime"; do
  got=$(matrix_for $named)
  [[ $(jq -c '[.include[] | [.package, .arch, .id]]' <<<"$got") == '[["runtime settings","x86_64","runtime+settings"],["runtime settings","aarch64","runtime+settings"]]' ]] \
    || fail "naming '$named' planned: $got"
done
pass "naming any member plans the whole group once per architecture, sorted"

got=$(matrix_for single runtime anyone settings)
[[ $(jq -c '[.include[] | .id // .package]' <<<"$got") == '["single","single","runtime+settings","runtime+settings","anyone"]' ]] \
  || fail "mixed selection: $got"
[[ "$(jq -c '.include[0]' <<<"$got")" == "$(jq -c '.include[0]' <<<"$want")" ]] || fail "singleton next to a group changed: $got"
pass "a group next to unrelated packages leaves their entries alone"

# Routing: members keep their own channels; the entry carries the union.
fixture fast-a x86_64 aarch64 -- '{"source":"local","release_ring":"fast","channels":["edge","rc"],"build_with":["fast-b"]}'
fixture fast-b x86_64 aarch64 -- '{"source":"local","release_ring":"fast","build_with":["fast-a"]}'
got=$("$F/bin/build-matrix" --arch aarch64 fast-a)
[[ $(jq -c '.include' <<<"$got") == '[{"package":"fast-a fast-b","arch":"aarch64","channels":"edge rc stable","publish_arches":"aarch64","runner":"[\"ubuntu-24.04-arm\"]","id":"fast-a+fast-b","members":[{"package":"fast-a","channels":"edge rc","publish_arches":"aarch64"},{"package":"fast-b","channels":"edge rc stable","publish_arches":"aarch64"}]}]' ]] \
  || fail "group routing: $got"
pass "each member keeps its own channels and publish_arches"

# An arch=any group builds once and is published to every architecture.
fixture any-a any -- '{"source":"local","build_with":["any-b"]}'
fixture any-b any -- '{"source":"local","build_with":["any-a"]}'
got=$(matrix_for any-b)
[[ $(jq -c '[.include[] | [.package, .arch, .publish_arches, (.members | map(.publish_arches))]]' <<<"$got") == '[["any-a any-b","x86_64","x86_64 aarch64",["x86_64 aarch64","x86_64 aarch64"]]]' ]] \
  || fail "arch=any group: $got"
pass "an arch=any group builds once and publishes to every architecture"

refused() { # refused <message part> <name>...
  local want=$1 out; shift
  if out=$(matrix_for "$@" 2>&1); then fail "planned an invalid group ($*): $out"; fi
  [[ $out == *"$want"* ]] || fail "unexpected refusal for $*: $out"
}
fixture lonely x86_64 aarch64 -- '{"source":"local","build_with":["single"]}'
refused "does not name lonely back" lonely
fixture ghost x86_64 aarch64 -- '{"source":"local","build_with":["nowhere"]}'
refused "nowhere is not a package" ghost
fixture mixed-a any -- '{"source":"local","build_with":["mixed-b"]}'
fixture mixed-b x86_64 aarch64 -- '{"source":"local","build_with":["mixed-a"]}'
refused "mix arch=any" mixed-b
fixture arch-a x86_64 -- '{"source":"local","build_with":["arch-b"]}'
fixture arch-b x86_64 aarch64 -- '{"source":"local","build_with":["arch-a"]}'
refused "do not build for the same architectures" arch-a
fixture linux-grouped x86_64 aarch64 -- '{"source":"local","build_with":["grouped-tool"]}'
fixture grouped-tool x86_64 aarch64 -- '{"source":"local","build_with":["linux-grouped"]}'
refused "different runners for aarch64" grouped-tool
"$F/bin/build-matrix" --arch x86_64 grouped-tool >/dev/null || fail "the same runner on x86_64 was refused"
fixture ring-a x86_64 aarch64 -- '{"source":"local","release_ring":"fast","build_with":["ring-b"]}'
fixture ring-b x86_64 aarch64 -- '{"source":"local","build_with":["ring-a"]}'
refused "different release rings" ring-b
fixture tri-a x86_64 aarch64 -- '{"source":"local","build_with":["tri-b","tri-c"]}'
fixture tri-b x86_64 aarch64 -- '{"source":"local","build_with":["tri-a"]}'
fixture tri-c x86_64 aarch64 -- '{"source":"local","build_with":["tri-a"]}'
refused "every member must name every other member" tri-a
fixture edge-less x86_64 aarch64 -- '{"source":"local","channels":["stable"],"build_with":["edge-full"]}'
fixture edge-full x86_64 aarch64 -- '{"source":"local","build_with":["edge-less"]}'
refused "edge-less is published to no channel" edge-full
pass "a group that cannot build as one job is refused, never split"

channels_of() { # the channels a package's own entry lists, as before groups
  local mirror out=""
  for mirror in $VALID_MIRRORS; do
    package_builds_for_mirror "$ROOT/pkgbuilds/$1" "$mirror" && out="$out $mirror"
  done
  echo "${out# }"
}
# The real declarations: each Omarchy pair is one entry per architecture,
# whichever half a change touched, with each half published as it was.
for pair in "omarchy omarchy-settings" "omarchy-dev omarchy-settings-dev"; do
  for half in $pair; do
    got=$("$ROOT/bin/build-matrix" "$half")
    [[ $(jq -c '[.include[] | [.package, .arch]]' <<<"$got") == "[[\"$pair\",\"x86_64\"],[\"$pair\",\"aarch64\"]]" ]] \
      || fail "$half plans: $got"
    for member in $pair; do
      [[ $(jq -r --arg m "$member" '[.include[].members[] | select(.package == $m) | .channels] | unique | join(";")' <<<"$got") == "$(channels_of "$member")" ]] \
        || fail "$member routing in $got"
    done
  done
done
pass "the omarchy and omarchy-dev pairs build together and keep their routing"
