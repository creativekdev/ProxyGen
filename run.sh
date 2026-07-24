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

if [ ! -x "$HERE/build/server" ]; then
  echo "server binary not found — run ./build.sh first" >&2
  exit 1
fi

export LD_LIBRARY_PATH="$PROXYGEN_PREFIX/lib:$PROXYGEN_PREFIX/lib64:${LD_LIBRARY_PATH:-}"

exec "$HERE/build/server" \
  --host=0.0.0.0 \
  --port=8080 \
  --db="$HERE/data/users.db" \
  --static_dir="$HERE/static" \
  "$@"
