# Proxygen Auth Server

A small HTTP server built on [facebook/proxygen](https://github.com/facebook/proxygen)
with **user signup, login, logout, and session auth**. It ships a tiny web UI and
a JSON API, and stores accounts in **SQLite** with **PBKDF2-SHA256 hashed
passwords**. This guide targets a **native Linux build**.

## Requirements

- **Ubuntu/Debian** (20.04 / 22.04 / 24.04) **or the RHEL 9 family** — CentOS
  Stream 9, RHEL 9, Rocky 9, AlmaLinux 9. `build.sh` detects `apt` vs `dnf` and
  installs the right packages either way.
- `sudo` access (to install build packages)
- **≥ 4 GB RAM** and some patience: Proxygen is compiled from source

> There is no `apt install proxygen` — Proxygen and its dependencies
> (folly / wangle / fizz / mvfst) are built from source with Meta's official
> `getdeps.py`. The **first build takes ~30–60 minutes**; it is cached afterward.

## Quick start

```bash
cd proxygen              # this project directory
chmod +x build.sh run.sh
./build.sh               # installs deps, builds Proxygen, then the app
./run.sh                 # starts the server on http://localhost:8080
```

Open **http://localhost:8080**, sign up, log out, log back in. Accounts persist in
`data/users.db`; sessions ride an `HttpOnly` cookie.

> Targeting **CentOS Stream 9 / RHEL 9**? Read
> **[OFFLINE-CENTOS9.md](OFFLINE-CENTOS9.md)** — those distros use glibc 2.34,
> older than Ubuntu 22.04's 2.35, so bundles must be built on EL9 (a
> `Dockerfile.el9` does this from Windows/macOS too).

### What `build.sh` does

1. Installs the packages this app links against — `apt-get install …` on
   Ubuntu/Debian, or `dnf install …` (plus enabling **CRB** and **EPEL**) on the
   RHEL 9 family. The lists live in [offline/common.sh](offline/common.sh).
2. Clones `facebook/proxygen` into `.deps/proxygen-src` and builds it +
   dependencies into `.deps/install` via `getdeps.py`.
3. Configures and builds this server with CMake into `build/`.

Re-running `./build.sh` skips the slow Proxygen step if `.deps/install` already
exists, so it only recompiles your app.

### Useful build options

```bash
PROXYGEN_REF=v2025.01.06.00 ./build.sh   # pin a specific Proxygen release
SKIP_PKGS=1 ./build.sh                    # skip apt/dnf (packages already present)
JOBS=4 ./build.sh                         # limit parallelism (less RAM)
PROXYGEN_PREFIX=/opt/pg ./build.sh        # install Proxygen elsewhere
```

## Offline use & sending it to someone else

All network access is at **build** time (apt, `git clone`, and `getdeps.py`
downloading dependency sources). **Running needs no network at all.** So the way
to go offline is: do the networked build once on an online machine, then ship an
artifact. There are three artifacts depending on what the recipient will do.

> **Same-machine rule:** any prebuilt artifact only works on a machine with the
> **same CPU architecture** and a **glibc no older** than the build machine's.
> glibc is forward-compatible only, so this direction matters:
>
> | Build host | glibc | Runs on |
> | --- | --- | --- |
> | CentOS Stream 9 / RHEL 9 / Rocky 9 / Alma 9 | 2.34 | EL9 **and** Ubuntu 22.04+ |
> | Ubuntu 22.04 | 2.35 | Ubuntu 22.04+ only — **not** EL9 |
> | Ubuntu 24.04 | 2.39 | Ubuntu 24.04+ only |
>
> Build on the **oldest** system you need to support. For CentOS 9 targets, that
> means building on EL9 — see **[OFFLINE-CENTOS9.md](OFFLINE-CENTOS9.md)**.
> Bundle filenames carry the distro tag (`…-el9.tar.gz`, `…-ubuntu22.04.tar.gz`)
> and each bundle ships an `offline/BUNDLE-INFO.txt` recording where it was built.

### Mode 1 — "just run it" (best for sending to a friend)

Produces one self-contained tarball: the binary + every non-glibc shared library
it needs + the web UI + a launcher. The recipient needs **no build tools, no
internet, no installs**.

```bash
# On your machine, after ./build.sh:
./offline/package-portable.sh
# → proxygen-portable-<distro>-<arch>.tar.gz   e.g. proxygen-portable-el9-x86_64.tar.gz
```

Send that single file. Your friend runs:

```bash
tar -xzf proxygen-portable-el9-x86_64.tar.gz
cd proxygen-portable-el9-x86_64
./run.sh                      # → http://localhost:8080
```

### Mode 2 — recompile the app offline (recipient may edit `src/`)

Ships Proxygen **prebuilt** plus the source and an offline compiler, so the
target can rebuild *this app* (not Proxygen) with no network.

```bash
# Online machine (must match the target's distro — see the same-machine rule):
./offline/prefetch.sh          # → proxygen-offline-bundle-<distro>.tar.gz
```

```bash
# Air-gapped machine:
mkdir proxygen && tar -xzf proxygen-offline-bundle-el9.tar.gz -C proxygen && cd proxygen
chmod +x run.sh offline/*.sh
./run.sh                        # run the prebuilt binary immediately, OR
./offline/offline-build.sh      # recompile the app, then ./run.sh
```

The bundle carries `.deb`s or `.rpm`s depending on where it was built, and
`offline-build.sh` installs whichever it finds. If the target already has
`cmake`/`ninja`/`g++` + sqlite3/openssl dev headers:
`SKIP_PKGS=1 ./offline/offline-build.sh`.

### Mode 3 — rebuild Proxygen from source offline (fully from-scratch)

Add `WITH_SOURCES=1` so the bundle also carries Proxygen's source and every
dependency source `getdeps` downloaded. The target can then rebuild the whole
stack with no network (slow, and best-effort — see caveat below).

```bash
# Online machine:
WITH_SOURCES=1 ./offline/prefetch.sh
```

```bash
# Air-gapped machine (inside the extracted bundle):
REBUILD_PROXYGEN=1 ./offline/offline-build.sh && ./run.sh
```

### What each bundle contains

| Path | Mode 1 | Mode 2 | Mode 3 |
| --- | :--: | :--: | :--: |
| `server` + bundled `lib/` (portable) | ✅ | — | — |
| `.deps/install/` (Proxygen prebuilt) | — | ✅ | ✅ |
| `bin/server` (app prebuilt) | — | ✅ | ✅ |
| `offline/debs/` or `offline/rpms/` (offline compiler) | — | ✅ | ✅ |
| `.deps/proxygen-src` + `.deps/scratch` (sources) | — | — | ✅ |
| `src/`, `static/`, `CMakeLists.txt`, `run.sh` | — | ✅ | ✅ |

## Manual build (if you prefer not to use the script)

```bash
# 1. host packages
sudo apt-get update
sudo apt-get install -y git cmake ninja-build build-essential python3 \
     python3-pip pkg-config libsqlite3-dev libssl-dev

# 2. build Proxygen into a local prefix
git clone --depth 1 https://github.com/facebook/proxygen.git .deps/proxygen-src
python3 .deps/proxygen-src/build/fbcode_builder/getdeps.py \
  --allow-system-packages install-system-deps --recursive proxygen
python3 .deps/proxygen-src/build/fbcode_builder/getdeps.py \
  --allow-system-packages build --install-prefix "$PWD/.deps/install" \
  --no-tests proxygen

# 3. build this app
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH="$PWD/.deps/install"
cmake --build build -j"$(nproc)"

# 4. run
./build/server --db=data/users.db --static_dir=static
```

## HTTP API

All request/response bodies are JSON. Session is carried in the `session` cookie.

| Method | Path          | Body                                     | Purpose |
| ------ | ------------- | ---------------------------------------- | ------- |
| POST   | `/api/signup` | `{"username":"...","password":"..."}`    | Create account, start session |
| POST   | `/api/login`  | `{"username":"...","password":"..."}`    | Verify credentials, start session |
| POST   | `/api/logout` | — (uses session cookie)                  | End the current session |
| GET    | `/api/me`     | — (uses session cookie)                  | Returns `{authenticated, username}` |
| GET    | `/`, `/*.css`, `/*.js` | —                               | Static web UI |

Validation: username 3–64 chars (`[A-Za-z0-9._-]`), password 8–256 chars.

### Try it with curl

```bash
# sign up (save cookies to a jar)
curl -c cookies.txt -X POST http://localhost:8080/api/signup \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"hunter2pass"}'

# who am I?
curl -b cookies.txt http://localhost:8080/api/me

# log out
curl -b cookies.txt -X POST http://localhost:8080/api/logout
```

## Configuration

The server binary accepts these flags (`run.sh` sets the first four):

| Flag           | Default            | Meaning |
| -------------- | ------------------ | ------- |
| `--host`       | `0.0.0.0`          | Bind address |
| `--port`       | `8080`             | Listen port |
| `--threads`    | `0` (= CPU cores)  | Worker threads |
| `--db`         | `data/users.db`    | SQLite file path |
| `--static_dir` | `static`           | Directory of static assets |

Example: `./run.sh --port=9000` or `./build/server --port=9000`.

## Running as a systemd service (optional)

Create `/etc/systemd/system/proxygen-auth.service`:

```ini
[Unit]
Description=Proxygen Auth Server
After=network.target

[Service]
WorkingDirectory=/path/to/proxygen
Environment=LD_LIBRARY_PATH=/path/to/proxygen/.deps/install/lib:/path/to/proxygen/.deps/install/lib64
ExecStart=/path/to/proxygen/build/server --db=/path/to/proxygen/data/users.db --static_dir=/path/to/proxygen/static
Restart=on-failure
User=www-data

[Install]
WantedBy=multi-user.target
```

Then: `sudo systemctl daemon-reload && sudo systemctl enable --now proxygen-auth`.

## Project layout

```
build.sh              # native build, apt or dnf (Proxygen + this app)
run.sh                # start the server
offline/
  common.sh           # distro detection + package lists shared by the scripts
  prefetch.sh         # STAGE 1 (online): build + cache packages → bundle
  offline-build.sh    # STAGE 2 (air-gapped): install packages + rebuild the app
  package-portable.sh # run-only tarball (binary + libs + web UI)
OFFLINE-CENTOS9.md    # CentOS Stream 9 / RHEL 9 (glibc 2.34) instructions
Dockerfile.el9        # EL9 builder: makes CentOS 9 bundles from any OS
CMakeLists.txt        # CMake build (links proxygen + sqlite3 + openssl)
src/
  main.cpp            # Server setup: options, threads, signal handling
  Handlers.{h,cpp}    # Routing factory + signup/login/logout/me/static handlers
  UserDb.{h,cpp}      # Thread-safe SQLite store for users & sessions
  Auth.{h,cpp}        # PBKDF2 password hashing + secure tokens (OpenSSL)
static/               # index.html, style.css, app.js  (the web UI)
data/                 # SQLite database (created at runtime; git-ignored)
.deps/                # Proxygen source + install prefix (git-ignored)
Dockerfile, docker-compose.yml   # optional Ubuntu container build
```

## Security notes

- Passwords hashed with **PBKDF2-HMAC-SHA256**, 210k iterations, per-user random
  16-byte salt; verification is constant-time.
- Session tokens are 32 bytes of CSPRNG output; cookies are `HttpOnly` +
  `SameSite=Lax`.
- For public deployment put this behind a TLS-terminating reverse proxy (nginx)
  and add the `Secure` cookie attribute — the server speaks plain HTTP by design.

## Troubleshooting

- **`getdeps.py` fails on an upstream change** → pin a release:
  `PROXYGEN_REF=v2025.01.06.00 ./build.sh`.
- **Out of memory during the folly build** → lower parallelism: `JOBS=2 ./build.sh`.
- **`error while loading shared libraries: libfolly…`** → run via `./run.sh`
  (it sets `LD_LIBRARY_PATH`), or ensure the CMake RPATH points at
  `.deps/install/lib`.
- **`find_package(proxygen)` not found** → confirm `.deps/install/include/proxygen`
  exists and pass the same path via `-DCMAKE_PREFIX_PATH`.
