# gatus-armv5

Docker image of [Gatus](https://github.com/TwiN/gatus) (automated service health dashboard)
built for **linux/arm/v5** (ARMv5 / ARM926EJ-S and similar SoCs).

This repository is a packaging repo: it contains only the build pipeline.
The actual Gatus source is cloned from upstream at build time. The approach is
modeled on [`cloudflared-armv5`](../cloudflared-armv5).

## Why ARMv5 needs a custom build

The Go project does not publish official binaries for ARMv5 (`GOARM=5`) — only
ARMv6 and above. To compile Gatus for ARMv5 we therefore have to **bootstrap a
Go toolchain from source** and cross-compile it for `linux/arm GOARM=5`.

Gatus is a great fit for this because it is:
- **fully static** (`CGO_ENABLED=0`, no C dependencies),
- uses **`modernc.org/sqlite`** (a pure-Go SQLite port), so no cross C toolchain is needed,
- ships its **web frontend pre-built and embedded** via `//go:embed`, so **no Node.js** is needed in the build.

## How it works

1. **Detect version** — a scheduled GitHub Action polls the
   [Gatus releases API](https://github.com/TwiN/gatus/releases) daily and compares
   the latest tag (e.g. `v5.36.0`) with `latest_version.txt`.
2. **Detect Go version** — the required Go version is scraped from the upstream
   `go.mod` (e.g. `go 1.26.3`). This is also used as the cache key for the toolchain.
3. **Bootstrap Go for ARMv5** (only on cache miss) —
   `build-gatus-armv5.sh` compiles Go from source in stages:
   `Go 1.20.7 (binary) → Go 1.22.6 → Go 1.24.6 → Go <required> for linux/arm GOARM=5`,
   then packages it as `go<version>-armv5.tar.gz`. The toolchain tarball is cached
   between runs keyed by the Go version.
4. **Build the image** — a multi-stage `Dockerfile` extracts the toolchain, clones
   Gatus at the requested tag, and builds a static ARMv5 binary. The runtime stage
   is `scratch` (binary + CA certs + tzdata only), running as non-root.
5. **Publish** — images are pushed to **Docker Hub** and **GHCR** with the version
   tag and `latest`, a git tag + GitHub Release (with source archive) is created,
   and `latest_version.txt` is bumped.

## Usage

```bash
docker run -d \
  --name gatus \
  -p 8080:8080 \
  --mount type=bind,source="$(pwd)"/config.yaml,target=/config/config.yaml \
  ghcr.io/<owner>/gatus-armv5:latest
```

Or from Docker Hub:

```bash
docker run -d \
  --name gatus \
  -p 8080:8080 \
  --mount type=bind,source="$(pwd)"/config.yaml,target=/config/config.yaml \
  <dockerhub-user>/gatus-armv5:latest
```

If you don't mount a config, the default `config/config.yaml` from the upstream
repo is used. See the [Gatus documentation](https://github.com/TwiN/gatus) for the
full configuration reference.

### Persistent data (SQLite)

If you enable SQLite storage, mount the `/data` directory:

```bash
docker run -d \
  -p 8080:8080 \
  -v gatus-data:/data \
  --mount type=bind,source="$(pwd)"/config.yaml,target=/config/config.yaml \
  ghcr.io/<owner>/gatus-armv5:latest
```

## Tags

| Tag        | Description                              |
|------------|------------------------------------------|
| `latest`   | Most recent upstream Gatus release       |
| `vX.Y.Z`   | Specific Gatus version (e.g. `v5.36.0`)  |

## CI / CD

- **Trigger:** daily cron (`0 0 * * *`) or manual `workflow_dispatch`
  (optionally with a specific `version` input).
- **Secrets required:**
  - `DOCKERHUB_USERNAME`
  - `DOCKERHUB_TOKEN`
  - `GITHUB_TOKEN` is provided automatically (used for GHCR + releases).

## Files

| File                      | Purpose                                             |
|---------------------------|-----------------------------------------------------|
| `Dockerfile`              | Multi-stage build (Go ARMv5 builder → `scratch`)    |
| `build-gatus-armv5.sh`    | Bootstraps the Go ARMv5 toolchain (with cache reuse)|
| `.github/workflows/build.yml` | Detect → build → push → release pipeline        |
| `latest_version.txt`      | Tracks the last built upstream version              |

## Credits

- [Gatus](https://github.com/TwiN/gatus) by Twin — the upstream project.
- [`cloudflared-armv5`](https://github.com/zvyzu/cloudflared-armv5) — the build
  approach this repo is modeled on.

## License

MIT (see `LICENSE`). Gatus itself is licensed under Apache-2.0 by its author.
