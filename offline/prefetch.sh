#!/usr/bin/env bash
#
# STAGE 1 — run this on an ONLINE machine that MATCHES the air-gapped target
#           (same distro major version + same CPU architecture).
#
#           For a CentOS Stream 9 / RHEL 9 / Rocky 9 target, run this ON EL9 —
#           its glibc is 2.34, older than Ubuntu 22.04's 2.35, and a bundle
#           built on Ubuntu will not load there. See OFFLINE-CENTOS9.md, which
#           also covers doing this in Docker from Windows.
#
# It produces a single self-contained bundle you copy to the offline machine:
#   * .deps/install         — Proxygen + folly/wangle/fizz/mvfst, PREBUILT
#   * bin/server            — this app, prebuilt (run immediately, no compile)
#   * offline/debs/*.deb    — Ubuntu/Debian packages for an offline recompile
#     offline/rpms/*.rpm    — …or the EL9 equivalents, depending on the distro
#   * source + scripts
#
# On the air-gapped machine you then run offline/offline-build.sh (to recompile)
# or just ./run.sh (to run the prebuilt binary). Neither needs the network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common.sh
. "$ROOT/offline/common.sh"

FAMILY="$(pkg_family)"
DEB_DIR="$ROOT/offline/debs"
RPM_DIR="$ROOT/offline/rpms"
# Bundles are distro-specific, so the name carries the distro tag (el9,
# ubuntu22.04, …). Override with OUT=… if you want a different path.
OUT="${OUT:-$ROOT/proxygen-offline-bundle-$(os_tag).tar.gz}"

echo "############################################################"
echo "# STAGE 1: online prefetch"
echo "# Distro: $(os_pretty)  [$FAMILY]"
echo "# glibc:  $(glibc_version)"
echo "# Arch:   $(uname -m)"
echo "# The air-gapped machine MUST match the lines above (its glibc"
echo "# may be newer, never older)."
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
# 2. Download the package closure needed to recompile the app on the offline
#    box. (Only needed if the target lacks cmake/ninja/g++/dev headers.)
#    The package list lives in offline/common.sh, one per distro family.
# ---------------------------------------------------------------------------
PKGS="$(build_pkgs)"
if [ "$FAMILY" = "rpm" ]; then
  echo "==> [2/4] Downloading .rpm packages for an offline recompile…"
  mkdir -p "$RPM_DIR"
  $SUDO dnf -y install dnf-plugins-core || true
  # --resolve pulls in dependencies; --alldeps includes the ones already
  # installed HERE (the offline box won't have them, so we must ship them).
  # No --arch: dnf picks this machine's arch plus noarch, which is what we want.
  # shellcheck disable=SC2086
  dnf download --resolve --alldeps --destdir "$RPM_DIR" $PKGS \
    || {
      echo "   (bulk download failed — retrying package by package)"
      for p in $PKGS; do
        dnf download --resolve --alldeps --destdir "$RPM_DIR" "$p" >/dev/null 2>&1 \
          || echo "   skip: $p (unavailable)"
      done
    }
  echo "    $(ls -1 "$RPM_DIR"/*.rpm 2>/dev/null | wc -l) rpm(s) cached in offline/rpms/"
elif [ "$FAMILY" = "deb" ]; then
  echo "==> [2/4] Downloading .deb packages for an offline recompile…"
  mkdir -p "$DEB_DIR"
  $SUDO apt-get update
  # Resolve the recursive dependency closure and fetch each as a .deb.
  # shellcheck disable=SC2086
  DEB_LIST="$(apt-cache depends --recurse --no-recommends --no-suggests \
    --no-conflicts --no-breaks --no-replaces --no-enhances $PKGS \
    | grep '^[[:alnum:]]' | sort -u)"
  # shellcheck disable=SC2086
  ( cd "$DEB_DIR" && apt-get download $DEB_LIST ) || \
    echo "   (some virtual/base packages couldn't be fetched — usually fine)"
else
  echo "==> [2/4] Unknown package manager — skipping offline package download."
fi

# ---------------------------------------------------------------------------
# 3. Also cache the runtime shared libraries the prebuilt binary needs, so the
#    prebuilt bin/server runs even if the target is missing some runtime libs.
# ---------------------------------------------------------------------------
echo "==> [3/4] Collecting runtime shared libraries for the prebuilt binary…"
rm -rf "$ROOT/offline/runtime-libs"
mkdir -p "$ROOT/offline/runtime-libs"
# Libraries reported by ldd, minus the ones that must come from the target's
# own glibc stack (see SYSTEM_LIB_RE in common.sh — libgcc_s is one of them:
# bundling it is what breaks a bundle on an older-glibc host).
ldd "$ROOT/bin/server" 2>/dev/null \
  | awk '/=> \// {print $3}' \
  | grep -Ev "$SYSTEM_LIB_RE" \
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
  if [ -d "$ROOT/.deps/proxygen-src" ]; then EXTRA+=(./.deps/proxygen-src); fi
  if [ -d "$ROOT/.deps/scratch" ];      then EXTRA+=(./.deps/scratch);      fi
fi
# Ship whichever package cache this distro produced.
if [ -d "$DEB_DIR" ]; then EXTRA+=(./offline/debs); fi
if [ -d "$RPM_DIR" ]; then EXTRA+=(./offline/rpms); fi
# Record what this bundle was built on so the target can sanity-check itself.
cat > "$ROOT/offline/BUNDLE-INFO.txt" <<EOF
distro:  $(os_pretty)
tag:     $(os_tag)
family:  $FAMILY
glibc:   $(glibc_version)
arch:    $(uname -m)

This bundle runs on the distro above, or any same-arch Linux whose glibc is the
SAME OR NEWER. It will NOT load on a host with an older glibc.
EOF

tar -czf "$OUT" -C "$ROOT" \
  --exclude='./.git' \
  --exclude='./data' \
  --exclude='./build' \
  ./src ./cmake ./static ./CMakeLists.txt ./run.sh ./README.md ./DEV-OFFLINE.md \
  ./OFFLINE-CENTOS9.md \
  ./offline/offline-build.sh ./offline/package-portable.sh ./offline/common.sh \
  ./offline/BUNDLE-INFO.txt ./offline/runtime-libs \
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
