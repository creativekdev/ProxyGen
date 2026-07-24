# Proxygen Auth Server

A small HTTP server built on [facebook/proxygen](https://github.com/facebook/proxygen)
with **user signup, login, logout, and session auth**. It ships a tiny web UI and
a JSON API, and stores accounts in **SQLite** with **PBKDF2-SHA256 hashed
passwords**. This guide targets a **native build on Ubuntu**.

## Requirements

- Ubuntu 20.04 / 22.04 / 24.04 (or similar Linux; macOS also works)
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

### What `build.sh` does

1. `sudo apt-get install …` — the packages this app links against
   (`git cmake ninja-build build-essential python3 libsqlite3-dev libssl-dev`).
2. Clones `facebook/proxygen` into `.deps/proxygen-src` and builds it +
   dependencies into `.deps/install` via `getdeps.py`.
3. Configures and builds this server with CMake into `build/`.

Re-running `./build.sh` skips the slow Proxygen step if `.deps/install` already
exists, so it only recompiles your app.

### Useful build options

```bash
PROXYGEN_REF=v2025.01.06.00 ./build.sh   # pin a specific Proxygen release
SKIP_APT=1 ./build.sh                     # skip apt (packages already present)
JOBS=4 ./build.sh                         # limit parallelism (less RAM)
PROXYGEN_PREFIX=/opt/pg ./build.sh        # install Proxygen elsewhere
```

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
build.sh              # native Ubuntu build (Proxygen + this app)
run.sh                # start the server
CMakeLists.txt        # CMake build (links proxygen + sqlite3 + openssl)
src/
  main.cpp            # Server setup: options, threads, signal handling
  Handlers.{h,cpp}    # Routing factory + signup/login/logout/me/static handlers
  UserDb.{h,cpp}      # Thread-safe SQLite store for users & sessions
  Auth.{h,cpp}        # PBKDF2 password hashing + secure tokens (OpenSSL)
static/               # index.html, style.css, app.js  (the web UI)
data/                 # SQLite database (created at runtime; git-ignored)
.deps/                # Proxygen source + install prefix (git-ignored)
Dockerfile, docker-compose.yml   # optional container build (not needed on Ubuntu)
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
