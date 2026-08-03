#!/bin/bash

set -euo pipefail

# Usage:
#   GATUS_VERSION= ./build-gatus-armv5.sh
#   ./build-gatus-armv5.sh v5.36.0
#   ./build-gatus-armv5.sh            (no arg -> latest upstream tag)
#
# Multi-stage Go bootstrap build for the ARMv5 toolchain:
#   1. Use the official Go 1.20.7 binary to bootstrap Go 1.22.6 (amd64)
#   2. Use Go 1.22.6 to bootstrap Go 1.24.6 (amd64)
#   3. Use Go 1.24.6 to bootstrap the required Go version for ARMv5
#      (version scraped from the upstream gatus go.mod, e.g. "1.26.3")
#   4. Package the resulting toolchain as a tarball for the Docker build
#
# Caching:
#   If a toolchain tarball for the SAME required Go version already exists
#   (restored from the CI cache into the working directory), the whole
#   bootstrap is skipped and only toolchain-meta.env is written.

# ---------------------------------------------------------------------------
# Step 0: Resolve the gatus version and the required Go version
# ---------------------------------------------------------------------------

GATUS_REPO_URL="https://github.com/TwiN/gatus.git"
GATUS_TMP_DIR="gatus-upstream-tmp"

# Allow override of the gatus version via argument or env (default: latest tag)
if [ $# -ge 1 ]; then
  GATUS_VERSION="$1"
elif [ -n "${GATUS_VERSION:-}" ]; then
  GATUS_VERSION="$GATUS_VERSION"
else
  # Discover latest release tag from upstream (tags look like "v5.36.0")
  GATUS_VERSION="$(git ls-remote --tags --refs "$GATUS_REPO_URL" | awk -F/ '{print $NF}' | sort -V | tail -n1)"
  echo "No version specified. Using latest tag: $GATUS_VERSION"
fi

echo "Building for gatus version: $GATUS_VERSION"

# Step 1: Prepare/clone the gatus repo at the desired tag
rm -rf "$GATUS_TMP_DIR"
git clone --no-checkout --depth 1 "$GATUS_REPO_URL" "$GATUS_TMP_DIR"

cd "$GATUS_TMP_DIR"
git fetch --depth 1 origin "refs/tags/$GATUS_VERSION:refs/tags/$GATUS_VERSION"
commit_sha=$(git rev-parse --verify --quiet "refs/tags/$GATUS_VERSION^{commit}")
git checkout "$commit_sha"
cd ..

# --- DIAGNOSTICS: Print upstream repo state ---
echo "=== DIAGNOSTICS: upstream repo state ==="
echo "pwd: $(pwd)"
git -C "$GATUS_TMP_DIR" show --no-patch --format='%H %an %ad %D' HEAD
git -C "$GATUS_TMP_DIR" show-ref --tags
ls -la "$GATUS_TMP_DIR" | head -20
echo "--- go.mod (head) ---"
head -n 20 "$GATUS_TMP_DIR/go.mod"
echo "=== END DIAGNOSTICS ==="

# --- Version scraping logic: parse Go version from go.mod ---
GO_MOD_VERSION_LINE=$(grep '^go ' "$GATUS_TMP_DIR/go.mod" | awk '{print $2}')

if [[ "$GO_MOD_VERSION_LINE" =~ ^([0-9]+\.[0-9]+)$ ]]; then
  # Version like "1.26" -> convert to "1.26.0"
  GO_FULL_VERSION="${BASH_REMATCH[1]}.0"
elif [[ "$GO_MOD_VERSION_LINE" =~ ^([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  # Version like "1.26.3" -> use as-is
  GO_FULL_VERSION="${BASH_REMATCH[1]}"
else
  echo "ERROR: Could not parse Go version from gatus upstream go.mod"
  echo "  go.mod line was: $GO_MOD_VERSION_LINE"
  exit 1
fi

echo "Detected Go version from go.mod: $GO_FULL_VERSION"

GO_VERSION="go${GO_FULL_VERSION}"
GO_SRC_TAG="go${GO_FULL_VERSION}"
GO_TARBALL="go${GO_FULL_VERSION}-armv5.tar.gz"

echo "Using required Go version: $GO_VERSION"

# ---------------------------------------------------------------------------
# CACHE SHORT-CIRCUIT: reuse an existing toolchain tarball if present
# ---------------------------------------------------------------------------
if [ -f "$GO_TARBALL" ]; then
  echo "==================================================================="
  echo "CACHE HIT: Found existing toolchain tarball: $GO_TARBALL"
  echo "Skipping the entire Go bootstrap build."
  echo "==================================================================="
  echo "GO_FULL_VERSION=$GO_FULL_VERSION" > toolchain-meta.env
  echo "GO_TARBALL=$GO_TARBALL" >> toolchain-meta.env
  echo "Wrote Go version and tarball name to toolchain-meta.env (cached)"
  exit 0
fi

echo "CACHE MISS: No existing tarball for $GO_TARBALL. Building toolchain..."

# ---------------------------------------------------------------------------
# Stage 0: Download Go 1.20.7 binary as the initial bootstrap compiler
# ---------------------------------------------------------------------------
BOOTSTRAP0_GO_VERSION="go1.20.7"
BOOTSTRAP0_GO_TARBALL="${BOOTSTRAP0_GO_VERSION}.linux-amd64.tar.gz"
BOOTSTRAP0_GO_URL="https://go.dev/dl/${BOOTSTRAP0_GO_TARBALL}"

echo "Step 1: Download Go $BOOTSTRAP0_GO_VERSION bootstrap binary"
rm -rf go-bootstrap0

if [ ! -d "go-bootstrap0" ]; then
  curl -fsSL "$BOOTSTRAP0_GO_URL" -o "$BOOTSTRAP0_GO_TARBALL"
  tar -xzf "$BOOTSTRAP0_GO_TARBALL"
  mv go go-bootstrap0
  rm "$BOOTSTRAP0_GO_TARBALL"
fi

# ---------------------------------------------------------------------------
# Stage 1: Build Go 1.22.6 from source using Go 1.20.7
# ---------------------------------------------------------------------------
STAGE1_GO_VERSION="go1.22.6"
STAGE1_GO_SRC_DIR="go-src-stage1"

rm -rf "$STAGE1_GO_SRC_DIR"
git clone --depth 1 --branch "$STAGE1_GO_VERSION" https://go.googlesource.com/go "$STAGE1_GO_SRC_DIR"

echo "Step 2: Build Go $STAGE1_GO_VERSION for amd64 using bootstrap0"
export GOROOT_BOOTSTRAP="$(pwd)/go-bootstrap0"
export PATH="$GOROOT_BOOTSTRAP/bin:$PATH"

cd "$STAGE1_GO_SRC_DIR/src"
GOOS=linux GOARCH=amd64 ./make.bash
cd ../..

# ---------------------------------------------------------------------------
# Stage 1.5: Build Go 1.24.6 from source using Go 1.22.6 (stage1)
# ---------------------------------------------------------------------------
STAGE1_5_GO_VERSION="go1.24.6"
STAGE1_5_GO_SRC_DIR="go-src-stage1-5"

rm -rf "$STAGE1_5_GO_SRC_DIR"
git clone --depth 1 --branch "$STAGE1_5_GO_VERSION" https://go.googlesource.com/go "$STAGE1_5_GO_SRC_DIR"

echo "Step 2.5: Build Go $STAGE1_5_GO_VERSION for amd64 using stage1 (Go 1.22.6)"
export GOROOT_BOOTSTRAP="$(pwd)/$STAGE1_GO_SRC_DIR"
export PATH="$GOROOT_BOOTSTRAP/bin:$PATH"

cd "$STAGE1_5_GO_SRC_DIR/src"
GOOS=linux GOARCH=amd64 ./make.bash
cd ../..

# ---------------------------------------------------------------------------
# Stage 2: Build Go $GO_VERSION for ARMv5 using Go 1.24.6 (stage1.5)
# ---------------------------------------------------------------------------
GO_SRC_DIR="go-src"

rm -rf "$GO_SRC_DIR"
git clone https://go.googlesource.com/go "$GO_SRC_DIR"

cd "$GO_SRC_DIR"
git fetch --all --tags

if git rev-parse "$GO_SRC_TAG" >/dev/null 2>&1; then
  git checkout "$GO_SRC_TAG"
else
  GO_SRC_TAG_MINOR=$(echo "$GO_FULL_VERSION" | awk -F. '{print "go"$1"."$2}')
  if git rev-parse "$GO_SRC_TAG_MINOR" >/dev/null 2>&1; then
    git checkout "$GO_SRC_TAG_MINOR"
  else
    echo "Warning: Tag $GO_SRC_TAG or $GO_SRC_TAG_MINOR not found, falling back to $GO_VERSION"
    git checkout "$GO_VERSION"
  fi
fi

echo "Step 3: Build Go $GO_VERSION for linux/arm (ARMv5) using stage1.5 Go (Go 1.24.6)"
export GOROOT_BOOTSTRAP="$(pwd)/../$STAGE1_5_GO_SRC_DIR"
export PATH="$GOROOT_BOOTSTRAP/bin:$PATH"

cd src
GOOS=linux GOARCH=arm GOARM=5 ./make.bash
cd ..

cd ..

echo "Step 4: Package built Go toolchain"
rm -f "$GO_TARBALL"
tar czf "$GO_TARBALL" -C go-src .

echo "Go toolchain build complete: $GO_TARBALL"
echo "Toolchain tarball ready: $(realpath "$GO_TARBALL")"
echo "You can now use this tarball in your Docker build."

# ---- Output Go version and tarball name for CI/CD ----
echo "GO_FULL_VERSION=$GO_FULL_VERSION" > toolchain-meta.env
echo "GO_TARBALL=$GO_TARBALL" >> toolchain-meta.env
echo "Wrote Go version and tarball name to toolchain-meta.env"
