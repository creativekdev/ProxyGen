#!/usr/bin/env bash
#
# Shared helpers for build.sh and the offline/*.sh scripts.
#
# Two packaging families are supported:
#   deb — Debian / Ubuntu                              (apt-get, dpkg, .deb)
#   rpm — RHEL 9 / CentOS Stream 9 / Rocky 9 / Alma 9  (dnf, rpm, .rpm)
#
# Everything here is sourced, never executed directly.

# Privileged commands: use sudo only when we aren't already root. Containers
# (and minimal CentOS images) frequently have no sudo installed at all.
if [ "$(id -u)" = "0" ]; then SUDO=""; else SUDO="sudo"; fi

# --- Which distro family are we on? -----------------------------------------
pkg_family() {
  if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    echo rpm
  elif command -v apt-get >/dev/null 2>&1; then
    echo deb
  else
    echo unknown
  fi
}

os_pretty() { ( . /etc/os-release 2>/dev/null || true; echo "${PRETTY_NAME:-unknown}" ); }

# Short tag used to name bundles, e.g. "el9", "ubuntu22.04". A bundle is only
# valid on a machine matching this tag (see the glibc rule in README.md).
os_tag() {
  ( . /etc/os-release 2>/dev/null || true
    case "${ID:-unknown}" in
      centos|rhel|rocky|almalinux|fedora) v="${VERSION_ID:-0}"; echo "el${v%%.*}" ;;
      *) echo "${ID:-unknown}${VERSION_ID:-}" ;;
    esac )
}

glibc_version() { ldd --version 2>/dev/null | head -1 | grep -o '[0-9]\+\.[0-9]\+$' || echo unknown; }

# --- Package lists ----------------------------------------------------------
# Build tools plus every system -dev library the final link needs. folly and
# proxygen pull most of these in transitively; without them a rebuild fails
# with "cannot find -lXXX".
DEB_BUILD_PKGS="git cmake ninja-build build-essential g++ python3 python3-pip
  pkg-config ca-certificates libsqlite3-dev libssl-dev libc-ares-dev
  libevent-dev zlib1g-dev libbz2-dev liblz4-dev libzstd-dev libsnappy-dev
  libdwarf-dev libaio-dev libsodium-dev libdouble-conversion-dev
  libgflags-dev libgoogle-glog-dev"

# EL9 equivalents. Several of these live outside BaseOS/AppStream:
#   crb  → libzstd-devel, lz4-devel, snappy-devel, libdwarf-devel, libunwind-devel
#   epel → ninja-build, gflags-devel, glog-devel, libsodium-devel,
#          double-conversion-devel
# enable_rpm_repos() turns both on before installing.
RPM_BUILD_PKGS="git cmake ninja-build gcc gcc-c++ make python3 python3-pip
  pkgconf-pkg-config ca-certificates which patch xz zip unzip perl-core
  sqlite-devel openssl-devel c-ares-devel libevent-devel zlib-devel
  bzip2-devel lz4-devel libzstd-devel snappy-devel libdwarf-devel
  libunwind-devel libaio-devel libsodium-devel double-conversion-devel
  gflags-devel glog-devel"

# The list for the family we're actually on.
build_pkgs() {
  case "$(pkg_family)" in
    rpm) echo "$RPM_BUILD_PKGS" ;;
    deb) echo "$DEB_BUILD_PKGS" ;;
    *)   echo "" ;;
  esac
}

# --- Repo setup (rpm only) --------------------------------------------------
# CRB (CodeReady Builder) and EPEL carry the -devel packages RHEL 9 keeps out of
# the default repos. Both steps are best-effort: if a repo can't be enabled we
# fall back to building that dependency from source via getdeps.
enable_rpm_repos() {
  [ "$(pkg_family)" = "rpm" ] || return 0
  echo "==> Enabling CRB + EPEL (needed for several -devel packages)…"
  $SUDO dnf -y install dnf-plugins-core || true
  # RHEL/CentOS 9 call it "crb"; 8 called it "powertools".
  $SUDO dnf config-manager --set-enabled crb 2>/dev/null \
    || $SUDO dnf config-manager --set-enabled powertools 2>/dev/null \
    || echo "   (CRB repo not enabled — some -devel packages may be missing)"
  $SUDO dnf -y install epel-release 2>/dev/null \
    || $SUDO dnf -y install \
         https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm 2>/dev/null \
    || echo "   (EPEL not enabled — some -devel packages may be missing)"
}

# --- Installing ------------------------------------------------------------
# Best effort: try the whole list at once, and if that fails (usually one
# package name missing on this release) retry one by one so a single absent
# package doesn't abort the build. getdeps compiles from source whatever it
# can't find installed, so a skipped package costs build time, not correctness.
pkg_install() {
  local family; family="$(pkg_family)"
  local p
  case "$family" in
    deb) $SUDO apt-get install -y --no-install-recommends "$@" && return 0 ;;
    rpm) $SUDO dnf install -y "$@" && return 0 ;;
    *)   echo "WARNING: no apt-get or dnf found — install these yourself: $*" >&2
         return 0 ;;
  esac
  echo "   (bulk install failed — retrying package by package)"
  for p in "$@"; do
    case "$family" in
      deb) $SUDO apt-get install -y --no-install-recommends "$p" || echo "   skip: $p (unavailable)" ;;
      rpm) $SUDO dnf install -y "$p" || echo "   skip: $p (unavailable)" ;;
    esac
  done
}

# --- Runtime library filter -------------------------------------------------
# Libraries that must ALWAYS come from the target system, never from the build
# machine. libc/ld are obvious. libgcc_s belongs on this list too: it is built
# alongside glibc and links against the build machine's glibc symbol versions,
# so shipping Ubuntu 22.04's copy (which needs GLIBC_2.35) makes the whole
# bundle fail to load on any glibc 2.34 host such as CentOS Stream 9 — even
# when every other shipped library is compatible.
SYSTEM_LIB_RE='/(libc|libm|libpthread|libdl|librt|libresolv|libgcc_s)\.so|ld-linux|linux-vdso'

# Same list, matched against SONAMEs rather than paths.
is_system_soname() {
  case "$1" in
    libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libresolv.so.*|libgcc_s.so.*|ld-linux*|linux-vdso*)
      return 0 ;;
  esac
  return 1
}
