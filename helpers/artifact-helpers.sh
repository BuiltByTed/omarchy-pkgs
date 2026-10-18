#!/bin/bash
# Package files cross from a PR build to publish.yml as one GitHub Actions
# artifact. actions/upload-artifact rejects any path containing ':', and a
# package with an epoch is named `name-1:ver-rel-arch.pkg.tar.zst` by
# makepkg. So the files ride inside a tar with a plain name and keep their
# own names untouched: pacman clients and bin/publish-artifact both rely on
# the filename matching PKGINFO.
#
# Both functions run under the workflow's `bash -e`: nothing in them may
# return non-zero except the final failure.

# package_files <dir>: the *.pkg.tar.zst directly in <dir>, one per line.
# Signatures and the scratch database next to them are not packages.
package_files() {
  local f
  for f in "$1"/*.pkg.tar.zst; do
    [[ -e "$f" ]] && printf '%s\n' "$f"
  done
  return 0
}

# pack_packages <dir> <tar>: every package in <dir> into <tar>.
pack_packages() {
  local dir=$1 out=$2 files=()
  mapfile -t files < <(package_files "$dir")
  (( ${#files[@]} )) || { echo "pack_packages: no *.pkg.tar.zst in $dir" >&2; return 1; }
  tar -cf "$out" -C "$dir" -- "${files[@]##*/}"
}

# unpack_packages <artifact dir> <dest>: the packages an unzipped artifact
# carried, into <dest>. Packed artifacts hold packages.tar; artifacts from
# builds before packing hold the bare files. The bare form can go once
# those artifacts have expired (7-day retention).
unpack_packages() {
  local src=$1 dest=$2 files=()
  mkdir -p "$dest"
  if [[ -f "$src/packages.tar" ]]; then
    tar -xf "$src/packages.tar" -C "$dest"
    return 0
  fi
  mapfile -t files < <(package_files "$src")
  (( ${#files[@]} )) || { echo "unpack_packages: nothing to unpack in $src" >&2; return 1; }
  cp -- "${files[@]}" "$dest/"
}

# artifact_label <rev> <arch> <package>...: the name a build's artifact is
# uploaded and looked up under, for the package directories as they are at
# <rev>. build-pr.yml uploads it, its planner and publish.yml find a build of
# exactly the trees that merged by it, so all of them compute it here.
#   one package:  <package>-<arch>-<tree hash of pkgbuilds/<package>>
#   a build group (package_build_group): <a>+<b>-<arch>-g1-<digest>, where the
#   digest is a sha256 over a format version, the architecture and every
#   member's name and tree hash, sorted. A change to any member's tree is a
#   new label, so a group artifact is reused only when every member matches,
#   and it can never be mistaken for one member's build.
# Look a label up with artifact_label_query: it may carry a "+".
artifact_label() {
  local rev=$1 arch=$2 member tree lines="" members=()
  shift 2
  mapfile -t members < <(printf '%s\n' "$@" | sed '/^$/d' | LC_ALL=C sort -u)
  (( ${#members[@]} )) || { echo "artifact_label: no package given" >&2; return 1; }
  if (( ${#members[@]} == 1 )); then
    tree=$(git rev-parse --verify --quiet "$rev:pkgbuilds/${members[0]}") \
      || { echo "artifact_label: no pkgbuilds/${members[0]} at $rev" >&2; return 1; }
    printf '%s-%s-%s\n' "${members[0]}" "$arch" "$tree"
    return 0
  fi
  for member in "${members[@]}"; do
    tree=$(git rev-parse --verify --quiet "$rev:pkgbuilds/$member") \
      || { echo "artifact_label: no pkgbuilds/$member at $rev" >&2; return 1; }
    lines+="$member $tree"$'\n'
  done
  tree=$(printf 'omarchy-build-group v1\narch %s\n%s' "$arch" "$lines" | sha256sum | cut -c1-40)
  printf '%s-%s-g1-%s\n' "$(IFS=+; echo "${members[*]}")" "$arch" "$tree"
}

# artifact_label_query <label>: the label, escaped for the artifacts API's
# ?name= query, where a bare "+" would read as a space.
artifact_label_query() {
  jq -rn --arg label "$1" '$label | @uri'
}
