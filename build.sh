#!/usr/bin/env bash
#
# Native build for Ubuntu (also works on Debian/most Linux, and macOS).
#
# What it does:
#   1. Installs the host packages this app links against (sqlite3, openssl, cmake…)
#   2. Clones + builds facebook/proxygen and its whole dependency closure
#      (folly / wangle / fizz / mvfst) into a local prefix, using Meta's getdeps.
#   3. Configures + builds THIS server against that prefix.
#
# The Proxygen build is compiled from source: the FIRST run takes ~30-60 min and
# wants >=4 GB RAM. It is skipped on subsequent runs (see PROXYGEN_PREFIX check).
#
# Usage:
#   ./build.sh                 # full build
#   PROXYGEN_REF=v2025.01.06.00 ./build.sh   # pin a Proxygen release
#   SKIP_APT=1 ./build.sh      # don't run apt (deps already installed)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROXYGEN_REF="${PROXYGEN_REF:-main}"
PROXYGEN_SRC="${PROXYGEN_SRC:-$HERE/.deps/proxygen-src}"
PROXYGEN_PREFIX="${PROXYGEN_PREFIX:-$HERE/.deps/install}"
JOBS="${JOBS:-$(nproc)}"

echo "==> Proxygen ref:     $PROXYGEN_REF"
echo "==> Install prefix:   $PROXYGEN_PREFIX"
echo "==> Parallel jobs:    $JOBS"

# ---------------------------------------------------------------------------
# 1. Host packages this app needs directly (Proxygen pulls its own via getdeps).
# ---------------------------------------------------------------------------
if [ "${SKIP_APT:-0}" != "1" ]; then
  echo "==> Installing host build packages (sudo apt-get)…"
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    git cmake ninja-build build-essential python3 python3-pip pkg-config \
    ca-certificates libsqlite3-dev libssl-dev
fi

# ---------------------------------------------------------------------------
# 2. Build Proxygen once, into $PROXYGEN_PREFIX. Skip if already installed.
# ---------------------------------------------------------------------------
if [ -f "$PROXYGEN_PREFIX/include/proxygen/httpserver/HTTPServer.h" ]; then
  echo "==> Proxygen already installed at $PROXYGEN_PREFIX — skipping build."
else
  echo "==> Fetching facebook/proxygen ($PROXYGEN_REF)…"
  if [ ! -d "$PROXYGEN_SRC/.git" ]; then
    mkdir -p "$(dirname "$PROXYGEN_SRC")"
    git clone --depth 1 --branch "$PROXYGEN_REF" \
      https://github.com/facebook/proxygen.git "$PROXYGEN_SRC"
  fi

  GETDEPS="$PROXYGEN_SRC/build/fbcode_builder/getdeps.py"

  # Optional: pin getdeps' scratch path. Set SCRATCH to keep all downloaded
  # dependency sources in a known folder so they can be shipped for a fully
  # offline from-source rebuild elsewhere (see offline/prefetch.sh WITH_SOURCES).
  SCRATCH_ARG=()
  if [ -n "${SCRATCH:-}" ]; then
    mkdir -p "$SCRATCH"
    SCRATCH_ARG=(--scratch-path "$SCRATCH")
  fi

  echo "==> Installing Proxygen's system dependencies…"
  python3 "$GETDEPS" "${SCRATCH_ARG[@]}" --allow-system-packages \
    install-system-deps --recursive proxygen

  echo "==> Building Proxygen + dependencies (this is the slow part)…"
  python3 "$GETDEPS" "${SCRATCH_ARG[@]}" --allow-system-packages build \
    --install-prefix "$PROXYGEN_PREFIX" \
    --num-jobs "$JOBS" \
    --no-tests \
    proxygen
fi

# ---------------------------------------------------------------------------
# 3. Build this application against the Proxygen prefix.
# ---------------------------------------------------------------------------
echo "==> Configuring + building the auth server…"
cmake -S "$HERE" -B "$HERE/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$PROXYGEN_PREFIX"
cmake --build "$HERE/build" -j "$JOBS"

echo
echo "==> Done. Binary: $HERE/build/server"
echo "==> Run it with:  ./run.sh   (or ./build/server)"
