#!/usr/bin/env bash
#
# Starts the server after a native build (see build.sh).
# The binary has an RPATH to the Proxygen prefix, but we also export
# LD_LIBRARY_PATH as a belt-and-suspenders fallback for finding shared libs.
#
# Any extra arguments are passed straight through to the server, e.g.:
#   ./run.sh --port=9000
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXYGEN_PREFIX="${PROXYGEN_PREFIX:-$HERE/.deps/install}"

# Prefer a freshly-built binary; fall back to the prebuilt one from an
# offline bundle (bin/server).
BIN="$HERE/build/server"
[ -x "$BIN" ] || BIN="$HERE/bin/server"
if [ ! -x "$BIN" ]; then
  echo "server binary not found — run ./build.sh (online) or" >&2
  echo "./offline/offline-build.sh (offline) first" >&2
  exit 1
fi

# Search paths for shared libs: the Proxygen prefix, plus the runtime-libs
# folder that an offline bundle may ship for the prebuilt binary.
export LD_LIBRARY_PATH="$PROXYGEN_PREFIX/lib:$PROXYGEN_PREFIX/lib64:$HERE/offline/runtime-libs:${LD_LIBRARY_PATH:-}"

exec "$BIN" \
  --host=0.0.0.0 \
  --port=8080 \
  --db="$HERE/data/users.db" \
  --static_dir="$HERE/static" \
  "$@"
