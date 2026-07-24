#!/usr/bin/env bash
#
# STAGE 1 — run this on an ONLINE machine that MATCHES the air-gapped target
#           (same Ubuntu major version + same CPU architecture).
#
# It produces a single self-contained bundle you copy to the offline machine:
#   * .deps/install         — Proxygen + folly/wangle/fizz/mvfst, PREBUILT
#   * bin/server            — this app, prebuilt (run immediately, no compile)
#   * offline/debs/*.deb    — packages needed to (optionally) recompile offline
#   * source + scripts
#
# On the air-gapped machine you then run offline/offline-build.sh (to recompile)
# or just ./run.sh (to run the prebuilt binary). Neither needs the network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEB_DIR="$ROOT/offline/debs"
OUT="${OUT:-$ROOT/proxygen-offline-bundle.tar.gz}"

echo "############################################################"
echo "# STAGE 1: online prefetch"
echo "# Ubuntu: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
echo "# Arch:   $(dpkg --print-architecture 2>/dev/null || uname -m)"
echo "# The air-gapped machine MUST match the two lines above."
echo "############################################################"

# ---------------------------------------------------------------------------
# 1. Build Proxygen + this app online. Populates .deps/install and build/server.
#    WITH_SOURCES=1 also pins the getdeps scratch path so the downloaded
#    dependency sources can be shipped for a fully offline from-source rebuild.
# ---------------------------------------------------------------------------
echo "==> [1/4] Building Proxygen + app (slow, compiles from source)…"
if [ "${WITH_SOURCES:-0}" = "1" ]; then
  echo "    (WITH_SOURCES=1 — capturing dependency sources for offline rebuild)"
  SCRATCH="$ROOT/.deps/scratch" "$ROOT/build.sh"
else
  "$ROOT/build.sh"
fi

# Stash a standalone copy of the prebuilt binary so it survives a later rebuild.
mkdir -p "$ROOT/bin"
cp -f "$ROOT/build/server" "$ROOT/bin/server"

# ---------------------------------------------------------------------------
# 2. Download the .deb closure needed to recompile the app on the offline box.
#    (Only needed if the target lacks cmake/ninja/g++/dev headers. Optional.)
# ---------------------------------------------------------------------------
echo "==> [2/4] Downloading .deb packages for an offline recompile…"
mkdir -p "$DEB_DIR"
sudo apt-get update
# Build tools + every system -dev library the app's final link needs. The list
# below matches the system libraries seen in the actual link command (folly/
# proxygen pull these in transitively); without them an offline rebuild fails
# with "cannot find -lXXX".
PKGS="cmake ninja-build build-essential g++ pkg-config \
  libsqlite3-dev libssl-dev libgflags-dev libc-ares-dev libevent-dev \
  zlib1g-dev libbz2-dev liblz4-dev libzstd-dev libsnappy-dev \
  libdwarf-dev libaio-dev libsodium-dev libdouble-conversion-dev"
# Resolve the recursive dependency closure and fetch each as a .deb.
DEB_LIST="$(apt-cache depends --recurse --no-recommends --no-suggests \
  --no-conflicts --no-breaks --no-replaces --no-enhances $PKGS \
  | grep '^[[:alnum:]]' | sort -u)"
( cd "$DEB_DIR" && apt-get download $DEB_LIST ) || \
  echo "   (some virtual/base packages couldn't be fetched — usually fine)"

# ---------------------------------------------------------------------------
# 3. Also cache the runtime shared libraries the prebuilt binary needs, so the
#    prebuilt bin/server runs even if the target is missing some runtime libs.
# ---------------------------------------------------------------------------
echo "==> [3/4] Collecting runtime shared libraries for the prebuilt binary…"
mkdir -p "$ROOT/offline/runtime-libs"
# Non-glibc libraries reported by ldd (we deliberately DO NOT bundle libc/ld).
ldd "$ROOT/bin/server" 2>/dev/null \
  | awk '/=> \// {print $3}' \
  | grep -Ev '/(libc|libm|libpthread|libdl|librt|ld-linux|libresolv)\.so' \
  | sort -u \
  | while read -r lib; do cp -Lf "$lib" "$ROOT/offline/runtime-libs/" 2>/dev/null || true; done

# ---------------------------------------------------------------------------
# 4. Package everything into one tarball.
# ---------------------------------------------------------------------------
echo "==> [4/4] Creating bundle: $OUT"
EXTRA=()
if [ "${WITH_SOURCES:-0}" = "1" ]; then
  # Ship Proxygen source + the getdeps scratch (downloaded dep sources) so the
  # target can rebuild Proxygen itself from source with no network.
  [ -d "$ROOT/.deps/proxygen-src" ] && EXTRA+=(./.deps/proxygen-src)
  [ -d "$ROOT/.deps/scratch" ]      && EXTRA+=(./.deps/scratch)
fi
tar -czf "$OUT" -C "$ROOT" \
  --exclude='./.git' \
  --exclude='./data' \
  --exclude='./build' \
  ./src ./cmake ./static ./CMakeLists.txt ./run.sh ./README.md ./DEV-OFFLINE.md \
  ./offline/offline-build.sh ./offline/package-portable.sh \
  ./offline/debs ./offline/runtime-libs \
  ./bin ./.deps/install "${EXTRA[@]}"

echo
echo "==> Done."
echo "    Bundle: $OUT ($(du -h "$OUT" | cut -f1))"
echo
echo "    This is the EDIT-AND-BUILD bundle — send it to a friend who wants to"
echo "    customize the code offline. After they extract it, they should read"
echo "    DEV-OFFLINE.md, then:"
echo "        ./run.sh                        # run the prebuilt binary directly, OR"
echo "        ./offline/offline-build.sh      # rebuild after editing src/, then ./run.sh"
