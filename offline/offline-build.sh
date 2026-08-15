#!/usr/bin/env bash
#
# STAGE 2 — run this on the AIR-GAPPED machine after extracting the bundle
#           produced by offline/prefetch.sh. It uses NO network.
#
# It (optionally) installs the bundled build tools — .deb on Ubuntu/Debian,
# .rpm on CentOS Stream 9 / RHEL 9 / Rocky 9 / Alma 9, whichever the bundle
# carries — then compiles this app against the PREBUILT Proxygen prefix shipped
# in .deps/install. Proxygen itself is never rebuilt here.
#
# If your offline machine already has cmake/ninja/g++ and the sqlite3/openssl dev
# headers, skip the package step:  SKIP_PKGS=1 ./offline/offline-build.sh
# (SKIP_DEBS=1 still works as an alias.)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common.sh
. "$ROOT/offline/common.sh"

DEB_DIR="$ROOT/offline/debs"
RPM_DIR="$ROOT/offline/rpms"
PREFIX="${PROXYGEN_PREFIX:-$ROOT/.deps/install}"

echo "==> This machine: $(os_pretty) [$(pkg_family)]  glibc $(glibc_version)  $(uname -m)"
if [ -f "$ROOT/offline/BUNDLE-INFO.txt" ]; then
  echo "==> Bundle was built on:"
  sed 's/^/    /' "$ROOT/offline/BUNDLE-INFO.txt" | head -5
fi

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
if [ "${SKIP_PKGS:-${SKIP_DEBS:-0}}" = "1" ]; then
  echo "==> Skipping package install (SKIP_PKGS=1)."
elif ls "$RPM_DIR"/*.rpm >/dev/null 2>&1; then
  echo "==> Installing bundled build tools from $RPM_DIR (offline)…"
  # --disablerepo='*' keeps dnf from touching the network; it still resolves
  # dependencies within the local set. rpm is the fallback when the set is
  # incomplete because some packages were already present on the build machine.
  $SUDO dnf -y --disablerepo='*' install "$RPM_DIR"/*.rpm \
    || $SUDO rpm -Uvh --replacepkgs --replacefiles "$RPM_DIR"/*.rpm \
    || $SUDO rpm -Uvh --replacepkgs --replacefiles --nodeps "$RPM_DIR"/*.rpm \
    || echo "   (some packages failed to install — continuing; the build may still work)"
elif ls "$DEB_DIR"/*.deb >/dev/null 2>&1; then
  echo "==> Installing bundled build tools from $DEB_DIR (offline)…"
  # dpkg -i on the whole set; a second pass resolves intra-set ordering.
  $SUDO dpkg -i "$DEB_DIR"/*.deb 2>/dev/null || $SUDO dpkg -i "$DEB_DIR"/*.deb || true
else
  echo "==> No bundled packages found — assuming build tools are already installed."
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
