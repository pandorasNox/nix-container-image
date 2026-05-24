# Local Nix Container Image Builder

Build the official `nixos/nix` container image locally from source and verify it
against the published reference.

## Why This Exists

The official [`nixos/nix`](https://hub.docker.com/r/nixos/nix) image on Docker Hub comes from the
[NixOS/nix](https://github.com/NixOS/nix) repository, but there is no direct
link from Docker Hub back to source. The image is built on
[Hydra](https://github.com/NixOS/nix/blob/master/packaging/hydra.nix#L315-L316),
Nix's own CI infrastructure — separate from GitHub Actions. So even with Nix's
**reproducibility** guarantees, you cannot fully trust the published image
without rebuilding & verify it yourself.

This project builds the image locally so you can:

- **Trust your own build** — you control the entire toolchain
- **Verify against the reference** — compare your result bit-for-bit with the
  official image from Docker Hub, confirming Nix's reproducibility claim (in the scope of the host architecture, as the upstream image is multi-arch while locally build is liekly single arch)

## How to Build

```bash
bash build.sh [version-tag]
```

Requires only Docker (no Nix installation needed on the host). Defaults to
`2.34.7` if no tag is given.

Produces:

| Artifact | Path | Description |
|---|---|---|
| Docker image tarball | `dist/image.tar.gz` | The built `nixos/nix` image |
| Comparison report | `dist/compare/result.compare.log` | Structured diff against the official image |

### Container Image Tag

The resulting container image (`image.tar.gz`) is tagged with the version from the `.version` file at the root of the [NixOS/nix](https://github.com/NixOS/nix) repository, **not** from the current git tag.

- **Source of truth:** [`packaging/components.nix:30`](https://github.com/NixOS/nix/blob/master/packaging/components.nix#L30) reads `/.version` — a plain-text file tracked in the repo and bumped by maintainers with each release.
- **Release vs development builds:** [`flake.nix:35`](https://github.com/NixOS/nix/blob/2.34.7/flake.nix#L35) sets `officialRelease = true` at release tags (e.g., `2.34.7`) and `officialRelease = false` on the development branch. When `true`, the version string matches `.version` exactly with no suffix.
- **How it reaches the container:** [`flake.nix:466`](https://github.com/NixOS/nix/blob/2.34.7/flake.nix#L466) passes `tag = pkgs.nix.version` to `docker.nix`, which becomes the tag written into the image metadata inside `image.tar.gz`.

Because this Docker build checks out a release tag (`NIX_GIT_TAG=2.34.7`), the flake's `officialRelease = true` produces a clean tag (`nix:2.34.7`). A development-branch build would produce a `pre`-suffixed tag like `nix:2.35.0pre<date>_<hash>`.

## Architecture

A multi-stage Containerfile (`Containerfile`):

| Stage | Base | What it does |
|---|---|---|
| `nix-builder` | `ubuntu:26.04` | Installs Nix via the official installer (`--no-daemon`, no systemd), clones `NixOS/nix` from GitHub, runs `nix build '.#dockerImage'` using the repo's `docker.nix` |
| `artifact` | `scratch` | Extracts the resulting `image.tar.gz` |
| `validate` | `golang:1.23-alpine` | Downloads the reference `nixos/nix` from Docker Hub, converts both images to OCI layout with `skopeo`, runs `scripts/compare.go` to diff layers, config, and environment — producing a structured comparison report |

## Design Decisions

- **`--no-daemon` install** — Docker containers should not run systemd (container
  anti-pattern). The official `nixos/nix` image uses the same approach.
- **`sandbox = false`** — Docker containers often lack user-namespace
  capabilities that the Nix sandbox requires; disabling avoids build failures.
- **Ubuntu pinned by SHA256 digest** — ensures reproducible base images.
- **No Nix on the host** — the entire build runs inside Docker containers,
  keeping the host clean.

## Verification

The validate stage answers: *does my locally-built image match the official one?*

The locally-built image is single-arch (your host architecture, e.g.
`linux/amd64` or `linux/arm64`), while the upstream image is multi-arch.
The comparison resolves the multi-arch index and compares only the matching
architecture.

- Same `diff_ids` → **bit-for-bit identical filesystem**
- Same config (entrypoint, cmd, env, labels) → **functionally equivalent**
- A passing comparison confirms Nix's reproducibility claim for the host
  architecture

## References

- Upstream repo: [NixOS/nix](https://github.com/NixOS/nix)
- Docker image builder: [`docker.nix`](https://github.com/NixOS/nix/blob/master/docker.nix)
- Hydra CI job: [`packaging/hydra.nix` (line 315)](https://github.com/NixOS/nix/blob/master/packaging/hydra.nix#L315-L316)
- Docker image upload: [`upload-release.yml`](https://github.com/NixOS/nix/blob/master/.github/workflows/upload-release.yml)

## Future TODO: Building Nix from Source

The current Containerfile installs Nix via the official installer script
(`curl https://nixos.org/nix/install | sh`). An alternative path would be to
compile Nix from source directly on Ubuntu, replacing that opaque download
with a fully transparent source build.

For reference, the [skiffos/docker-nixos](https://github.com/skiffos/docker-nixos)
project does exactly this — a multi-stage Dockerfile that compiles Nix and all
its dependencies from source on Ubuntu. Its
[`Dockerfile`](https://github.com/skiffos/docker-nixos/blob/main/Dockerfile)
lists all apt dependencies and its
[`nix-setup.sh`](https://github.com/skiffos/docker-nixos/blob/main/nix-setup.sh)
shows the `meson setup` / `meson compile` / `meson install` workflow directly.

**Build system**: [Meson](https://mesonbuild.com) ≥ 1.8

**Build tools**: `ninja`, `pkg-config`, `bison`, `flex`, `cmake`, `bash`

**C++ compiler**: C++23 capable (GCC ≥ 13 or Clang ≥ 16)

**Required libraries** — see
[`packaging/dependencies.nix`](https://github.com/NixOS/nix/blob/master/packaging/dependencies.nix)
for overrides and
[`packaging/components.nix`](https://github.com/NixOS/nix/blob/master/packaging/components.nix)
for the full dependency chain:

| Library | Minimum version |
|---|---|
| boost (context, coroutine, iostreams, url) | 1.87.0 |
| nlohmann_json | 3.9 |
| libarchive | 3.1.2 |
| openssl | 1.1.1 |
| libsodium | — |
| brotli | — |
| zstd | 1.4.0 |
| libblake3 | 1.8.2 |
| libcpuid (x86_64 only, optional) | 0.7.0 |
| curl | 8.17.0 |
| sqlite | 3.6.19 |
| libseccomp (Linux, optional) | 2.5.5 |
| aws-crt-cpp / aws-c-common (optional) | — |
| boehm-gc | — |
| toml11 | 3.7.0 |
| libgit2 | 1.9.3 |
| editline | 1.14 |
| lowdown (optional) | 0.9.0 |
| mimalloc (optional) | 3.3.2 |
| rapidcheck (tests) | — |
| gtest (tests) | — |
