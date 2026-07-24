#!/usr/bin/env bash
#
# STAGE 2 — run this on the AIR-GAPPED machine after extracting the bundle
#           produced by offline/prefetch.sh. It uses NO network.
#
# It (optionally) installs the bundled .deb build tools, then compiles this app
# against the PREBUILT Proxygen prefix shipped in .deps/install. Proxygen itself
# is never rebuilt here.
#
# If your offline machine already has cmake/ninja/g++ and the sqlite3/openssl dev
# headers, skip the .deb step:  SKIP_DEBS=1 ./offline/offline-build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEB_DIR="$ROOT/offline/debs"
PREFIX="${PROXYGEN_PREFIX:-$ROOT/.deps/install}"

# ---------------------------------------------------------------------------
# 0. (Advanced) Rebuild Proxygen itself from source, fully offline. Only works
#    if the bundle was made with WITH_SOURCES=1 (ships .deps/proxygen-src +
#    .deps/scratch). Best-effort: getdeps must find every source already cached.
# ---------------------------------------------------------------------------
if [ "${REBUILD_PROXYGEN:-0}" = "1" ]; then
  GETDEPS="$ROOT/.deps/proxygen-src/build/fbcode_builder/getdeps.py"
  if [ ! -f "$GETDEPS" ] || [ ! -d "$ROOT/.deps/scratch" ]; then
    echo "ERROR: source rebuild needs a WITH_SOURCES=1 bundle" >&2
    exit 1
  fi
  echo "==> Rebuilding Proxygen from source, offline (this is slow)…"
  rm -rf "$PREFIX"
  python3 "$GETDEPS" --scratch-path "$ROOT/.deps/scratch" \
    --allow-system-packages build \
    --install-prefix "$PREFIX" --no-tests proxygen
fi

echo "==> Verifying the Proxygen prefix…"
if [ ! -f "$PREFIX/include/proxygen/httpserver/HTTPServer.h" ]; then
  echo "ERROR: Proxygen prefix not found at $PREFIX" >&2
  echo "       Did you extract the FULL bundle (including .deps/install)?" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Install bundled build tools offline (only if present and not skipped).
# ---------------------------------------------------------------------------
if [ "${SKIP_DEBS:-0}" != "1" ] && ls "$DEB_DIR"/*.deb >/dev/null 2>&1; then
  echo "==> Installing bundled build tools from $DEB_DIR (offline)…"
  # dpkg -i on the whole set; a second pass resolves intra-set ordering.
  sudo dpkg -i "$DEB_DIR"/*.deb 2>/dev/null || sudo dpkg -i "$DEB_DIR"/*.deb || true
else
  echo "==> Skipping .deb install (SKIP_DEBS=1 or no .debs bundled)."
fi

# ---------------------------------------------------------------------------
# 2. Compile the app against the prebuilt prefix. Fresh build dir avoids stale
#    CMake cache paths carried over from the online machine.
# ---------------------------------------------------------------------------
echo "==> Building the app against $PREFIX …"
rm -rf "$ROOT/build"
GEN=""
command -v ninja >/dev/null 2>&1 && GEN="-G Ninja"
cmake -S "$ROOT" -B "$ROOT/build" $GEN \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$PREFIX"
cmake --build "$ROOT/build" -j "$(nproc)"

echo
echo "==> Done. Start the server with:  ./run.sh"
