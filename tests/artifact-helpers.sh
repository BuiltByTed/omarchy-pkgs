#!/bin/bash
# Self-test for helpers/artifact-helpers.sh: package files survive the
# artifact hop between build-pr.yml and publish.yml with makepkg's names
# intact, including the colon an epoch puts in them.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
source "$ROOT/helpers/artifact-helpers.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

EPOCH='cursor-cli-1:2026.09.18.1.9a7762b-1-x86_64.pkg.tar.zst'
PLAIN='beta-1.0-1-x86_64.pkg.tar.zst'
mkdir -p "$T/built" "$T/artifact" "$T/out"
echo epoch > "$T/built/$EPOCH"
echo plain > "$T/built/$PLAIN"
echo sig > "$T/built/$PLAIN.sig"
echo db > "$T/built/omarchy.db.tar.zst"

pack_packages "$T/built" "$T/artifact/packages.tar" || fail "pack"
[[ "$(tar -tf "$T/artifact/packages.tar" | sort | tr '\n' ' ')" == "$PLAIN $EPOCH " ]] \
  && pass "packages.tar holds the packages only, no signature or database" || fail "tar contents: $(tar -tf "$T/artifact/packages.tar" | tr '\n' ' ')"
[[ "$(ls "$T/artifact")" == "packages.tar" ]] && pass "the artifact path carries no colon" || fail "artifact listing"

unpack_packages "$T/artifact" "$T/out" || fail "unpack"
[[ "$(ls "$T/out" | sort | tr '\n' ' ')" == "$PLAIN $EPOCH " && "$(cat "$T/out/$EPOCH")" == epoch ]] \
  && pass "epoch filename and bytes survive the round trip" || fail "round trip: $(ls "$T/out" | tr '\n' ' ')"

# An artifact uploaded before packing existed: bare package files.
mkdir -p "$T/old" "$T/out2"; cp "$T/built"/*.pkg.tar.zst "$T/old/"
unpack_packages "$T/old" "$T/out2" && [[ "$(ls "$T/out2" | sort | tr '\n' ' ')" == "$PLAIN $EPOCH " ]] \
  && pass "a bare pre-packing artifact still unpacks" || fail "bare artifact"

# The workflows call these bare under `bash -e`, so any non-zero status
# inside them ends the step. (The first version used `shopt -p nullglob`,
# which exits 1 when the option is off; the tests above never saw it because
# `||` suppresses errexit.)
mkdir -p "$T/out4" "$T/out5"
bash -e -c "source '$ROOT/helpers/artifact-helpers.sh'; pack_packages '$T/built' '$T/out4/packages.tar'; tar -tf '$T/out4/packages.tar' >/dev/null; unpack_packages '$T/out4' '$T/out5'" \
  && [[ "$(ls "$T/out5" | sort | tr '\n' ' ')" == "$PLAIN $EPOCH " ]] \
  && pass "pack and unpack succeed under bash -e, as the workflows call them" || fail "bash -e"

mkdir -p "$T/empty"
if pack_packages "$T/empty" "$T/x.tar" 2>/dev/null; then fail "packing an empty build dir should fail"; else pass "empty build dir refused"; fi
if unpack_packages "$T/empty" "$T/out3" 2>/dev/null; then fail "an empty artifact should fail"; else pass "empty artifact refused"; fi

# artifact_label: one package keeps the label it always had; a build group
# gets one label over every member's tree, the same whichever order the
# members come in, and a new one when any member's tree changes.
G="$T/repo"
git init -q "$G"
git -C "$G" config user.email test@example.invalid
git -C "$G" config user.name test
mkdir -p "$G/pkgbuilds/runtime" "$G/pkgbuilds/settings"
echo 1 > "$G/pkgbuilds/runtime/PKGBUILD"
echo 1 > "$G/pkgbuilds/settings/PKGBUILD"
git -C "$G" add -A && git -C "$G" commit -qm one
label() { (cd "$G" && artifact_label "$@"); }
tree() { git -C "$G" rev-parse "$1:pkgbuilds/$2"; }
[[ $(label HEAD x86_64 runtime) == "runtime-x86_64-$(tree HEAD runtime)" ]] \
  && pass "a single package keeps its <package>-<arch>-<tree> label" || fail "single label: $(label HEAD x86_64 runtime)"
group=$(label HEAD x86_64 runtime settings)
[[ $group =~ ^runtime\+settings-x86_64-g1-[0-9a-f]{40}$ ]] && pass "a group label names its members and a versioned digest" || fail "group label: $group"
[[ $(label HEAD x86_64 settings runtime) == "$group" ]] && pass "the group label does not depend on member order" || fail "member order changed the label"
[[ $group != "$(label HEAD x86_64 runtime)" && $group != "$(label HEAD x86_64 settings)" ]] \
  && pass "a group label is never a member's own label" || fail "group label collides with a member's"
[[ $(label HEAD aarch64 runtime settings) != "$group" ]] && pass "the group label depends on the architecture" || fail "arch ignored"
first=$(git -C "$G" rev-parse HEAD)
echo 2 > "$G/pkgbuilds/settings/PKGBUILD"
git -C "$G" commit -qam two
[[ $(label HEAD x86_64 runtime settings) != "$group" && $(label "$first" x86_64 runtime settings) == "$group" ]] \
  && pass "changing one member's tree changes the group label" || fail "group label ignored a member's tree"
[[ $(label HEAD x86_64 runtime) == "runtime-x86_64-$(tree "$first" runtime)" ]] \
  && pass "an unchanged member's own label is unchanged" || fail "single label moved"
if label HEAD x86_64 runtime missing >/dev/null 2>&1; then fail "a label for a missing member"; else pass "a missing member has no label"; fi
[[ $(artifact_label_query "$group") == "runtime%2Bsettings-x86_64-g1-${group##*-}" ]] \
  && pass "the lookup query escapes the +" || fail "query: $(artifact_label_query "$group")"
[[ $(artifact_label_query "runtime-x86_64-$(tree HEAD runtime)") == "runtime-x86_64-$(tree HEAD runtime)" ]] \
  && pass "a single package's lookup query is the label itself" || fail "single query escaped"

# One artifact carries a whole build group: every member's files, epoch
# names included, and they all come back out of the one packages.tar.
mkdir -p "$T/group-built" "$T/group-artifact" "$T/group-out"
for f in runtime-4.0.5-1-x86_64.pkg.tar.zst settings-4.0.5-1-x86_64.pkg.tar.zst settings-debug-4.0.5-1-x86_64.pkg.tar.zst "$EPOCH"; do
  echo "$f" > "$T/group-built/$f"
done
bash -e -c "source '$ROOT/helpers/artifact-helpers.sh'; pack_packages '$T/group-built' '$T/group-artifact/packages.tar'; unpack_packages '$T/group-artifact' '$T/group-out'" || fail "group pack"
[[ "$(ls "$T/group-out" | sort | tr '\n' ' ')" == "$(ls "$T/group-built" | sort | tr '\n' ' ')" ]] \
  && pass "a build group's artifact carries every member's files" || fail "group artifact: $(ls "$T/group-out" | tr '\n' ' ')"
