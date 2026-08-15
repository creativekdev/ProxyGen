#!/usr/bin/env bash
#
# Make a PORTABLE, RUNNABLE bundle to send to a friend.
#
# Run this on the machine where you built the server (after build.sh). It gathers
# the binary + every non-glibc shared library it needs + the web assets + a
# launcher into one tarball. Your friend extracts it and runs ./run.sh — no
# build tools, no internet, no dependency install.
#
# Portability: works on any same-ARCHITECTURE Linux whose glibc is the same or
# newer than this build machine's. (glibc — and libgcc_s, which is built against
# it — are intentionally NOT bundled: they are tied to the kernel/loader and
# must come from the target system.)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common.sh
. "$ROOT/offline/common.sh"

BIN="$ROOT/build/server"
[ -x "$BIN" ] || BIN="$ROOT/bin/server"
if [ ! -x "$BIN" ]; then
  echo "No server binary found — run ./build.sh first." >&2
  exit 1
fi

ARCH="$(uname -m)"
DISTRO="$(os_pretty)"
NAME="proxygen-portable-$(os_tag)-${ARCH}"
DIST="$ROOT/$NAME"

echo "==> Assembling portable bundle: $DIST"
rm -rf "$DIST"
mkdir -p "$DIST/lib" "$DIST/static" "$DIST/data"
cp -f "$BIN" "$DIST/server"
cp -rf "$ROOT/static/." "$DIST/static/"

echo "==> Collecting shared libraries (named by SONAME so the loader finds them)…"
# ldd resolves the FULL transitive closure. $1 is the SONAME the binary asks for,
# $3 is the real file on disk — copy the file but name it by its SONAME.
ldd "$DIST/server" | awk '/=> \//{print $1" "$3}' | while read -r soname path; do
  # glibc core (incl. libgcc_s): leave it to the target system — see
  # is_system_soname() in common.sh for why libgcc_s must not be bundled.
  if is_system_soname "$soname"; then continue; fi
  cp -Lf "$path" "$DIST/lib/$soname" 2>/dev/null || true
done

echo "==> Writing launcher + friend-facing README…"
cat > "$DIST/run.sh" <<'EOF'
#!/usr/bin/env bash
# Self-contained launcher: points the loader at the bundled libs and starts up.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="$HERE/lib:${LD_LIBRARY_PATH:-}"
mkdir -p "$HERE/data"
exec "$HERE/server" \
  --host=0.0.0.0 --port=8080 \
  --db="$HERE/data/users.db" \
  --static_dir="$HERE/static" "$@"
EOF
chmod +x "$DIST/run.sh"

cat > "$DIST/README.txt" <<EOF
Proxygen Auth Server — portable build
Built on: ${DISTRO} / ${ARCH} / glibc $(glibc_version)
Runs on:  any same-arch Linux whose glibc is $(glibc_version) or NEWER.
          (A build made on Ubuntu 22.04 = glibc 2.35 will NOT run on
           CentOS Stream 9 / RHEL 9 = glibc 2.34. Build on EL9 for those.)

RUN IT (no build, no internet, no installs):
    ./run.sh
Then open http://localhost:8080 in your browser.

Options:
    ./run.sh --port=9000        # use a different port
Accounts are stored in ./data/users.db (created on first run).

If you get "error while loading shared libraries" or "version \`GLIBC_2.xx' not
found", your system's glibc is older than the build machine's — ask for a build
made on your distro version.
EOF

TARBALL="$ROOT/${NAME}.tar.gz"
tar -czf "$TARBALL" -C "$ROOT" "$NAME"
rm -rf "$DIST"

echo
echo "==> Portable bundle ready:"
echo "    $TARBALL  ($(du -h "$TARBALL" | cut -f1))"
echo
echo "    Send that ONE file to your friend. They run:"
echo "        tar -xzf ${NAME}.tar.gz && cd ${NAME} && ./run.sh"
