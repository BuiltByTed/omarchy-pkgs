# How a package builds

`bin/build` is the one builder: PR builds, rebuilds at merge and local builds
all call it.

## Dependency resolution

Within one `bin/build` run, the build system handles dependencies between the
packages it was asked to build. CI builds each package in its own job, so a
PR's packages do not see each other's fresh builds; they resolve from `edge`.
Packages that must see each other's are declared as a build group (below) and
share one job.

1. Plans dependency order once, including `depends`, `makedepends`,
   `checkdepends`, and their architecture-specific arrays.
2. Builds each package in a fresh container. Installed packages and changes
   to the container's system files cannot carry over to the next build.
3. Shares successful artifacts through the temporary `[omarchy-build]` repo,
   installing newly built prerequisites in each consumer's container.
4. Blocks consumers of a failed prerequisite while continuing independent
   builds.

Example: `steam` on aarch64 depends on `gtk2`, so `gtk2` is built first.

Isolation also lets the release and dev Omarchy pairs build in the same run:
Flea can install `omarchy` without preventing `omarchy-dev` from installing
its conflicting settings package in a different container.

Pacman downloads are cached under `cache/pacman/<channel>/<arch>/` across
containers and runs. The installed package database is never shared. Each
container updates its base system before resolving build dependencies, so a
cached builder image cannot cause a partial system upgrade. The existing
`OMARCHY_KEEP_BUILD_WORKSPACE`, `OMARCHY_SKIP_BUILDER_IMAGE`, and
`OMARCHY_DEFER_RUNTIME_DEPS` flags retain their behavior.

`tests/build-isolation.sh` exercises conflicting package pairs, failed
prerequisites, resumed builds, cache replacement, and deferred dependencies
using real containers and pacman transactions. It uses the prepared builder
image, or an image named by `TEST_BUILDER_IMAGE`; CI builds the small fixture
image in `tests/build-isolation.Dockerfile`.

## Build groups

Some packages cannot build in a job of their own. `omarchy` depends on
`omarchy-settings=${pkgver}`, an exact pin: built alone, it resolves the pin
against `edge`, which still serves the previous `omarchy-settings`, and fails
with `target not found: omarchy-settings=<new version>`. That is how the
publish after the 4.0.5 ship failed on both architectures (run 39086461241):
the matrix built `omarchy` and `omarchy-settings` in separate jobs.

Such packages declare each other in `.omarchy/package.json`:

```json
{ "build_with": ["omarchy-settings"] }
```

and `omarchy-settings` declares `["omarchy"]` back. `omarchy-dev` and
`omarchy-settings-dev` are declared the same way. Every member names every
other member; `validate_package_metadata` and `bin/build-matrix` refuse a
declaration that is not reciprocal, names something that is not a package,
mixes `arch=any` with architecture-specific members, or whose members would
build for different architectures, on different runners or on different
release rings. A group is never split quietly.

What a group changes:

- `bin/build-matrix` expands every name it is given to its whole group first,
  so a PR or merge that touches one member builds all of them, and plans one
  entry per group per architecture. Its `package` is the members' names,
  sorted and space-separated, which is what `bin/build --package` takes; one
  `bin/build` run orders them by dependency and installs each fresh build for
  the next, as above. `members` keeps each member's own `channels` and
  `publish_arches`; `id` (`omarchy+omarchy-settings`) names the group.
  Entries for packages in no group are unchanged.
- The group's artifact holds every member it built, under a label over all
  members' trees: `<a>+<b>-<arch>-g1-<digest>` (`artifact_label` in
  `helpers/artifact-helpers.sh`, the one place labels are made). A change to
  any member is a new label, so a group is reused or rebuilt as a whole. A
  single package keeps its `<package>-<arch>-<tree>` label.
- `publish.yml` unpacks the group's artifact once and publishes each member
  to its own channels. Before the first channel is touched it checks that
  every member is in the artifact, unless the channel itself already holds
  that member at master's version (the build leaves such a member out).

## Daily builder images

`Refresh builder images` builds fresh `edge` environments daily at 04:23 UTC,
when their inputs change on `master`, and on manual dispatch. x86_64 and
aarch64 build on native GitHub-hosted runners, without occupying the DO
package-builder pool. Each candidate must pass `tests/build-isolation.sh`,
including real package builds, before publication to
`ghcr.io/omacom/omarchy-pkg-builder`. Only `master` in this repository can
publish; PR workflows cannot replace the shared images.
PRs that change image inputs also build and test both candidates on native
runners, with a read-only token and no registry publication.

The compatibility tag contains the architecture, mirror, and a hash of the
entire `build/` context, including executable bits and symlink targets but
excluding checkout timestamps and ownership. This deliberately invalidates
images when mounted build scripts change too. `v1` identifies the image build
contract; change it if the invocation or compatibility rules change. Each
successful refresh also gets a run-specific tag for diagnosis and rollback.
A failed build, isolation test, or push leaves the previous compatible image
selected. Scheduled builds use `--pull --no-cache` so unchanged Dockerfiles
still pick up fresh Arch packages.

To build and test a candidate locally:

```bash
bin/builder-image key --arch x86_64 --mirror edge
bin/builder-image build --arch x86_64 --mirror edge --tag builder-candidate:test --fresh
CONTAINER_ENGINE=docker TEST_BUILDER_IMAGE=builder-candidate:test tests/build-isolation.sh
```

The workflow uses its repository `GITHUB_TOKEN` with `packages: write`; no
registry PAT is needed. **One-time setup when the image package is first
created:** GHCR
creates the package private. In the `omacom/omarchy-pkg-builder` package
settings, change visibility to **Public**, then rerun the failed refresh job.
The workflow checks anonymous registry access before advancing the compatible
tag, so fork PRs will not be directed to an image they cannot pull. Subsequent
refreshes preserve that package visibility.

`publish.yml`, `promote.yml`, `release-rc.yml` and `unpublish.yml` pull the
compatible image to sign and update databases, and build it on the runner when
no image carries the key yet (a change to `build/` publishes before its image
refresh has finished). Package build jobs still build their own image on the runner.
