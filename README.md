# Proxygen Auth Server

A small HTTP server built on [facebook/proxygen](https://github.com/facebook/proxygen)
with **user signup, login, logout, and session auth**. It ships a tiny web UI and
a JSON API, and stores accounts in **SQLite** with **PBKDF2-SHA256 hashed
passwords**. It runs identically on **Windows and Ubuntu** via Docker.

## Why Docker?

Proxygen is a Meta C++ library (folly, wangle, fizz, mvfst) that is **only
supported on Linux/macOS — there is no native Windows build**. Running inside a
Linux container is what makes "works on Windows and Ubuntu both" actually true:
Docker Desktop on Windows and Docker Engine on Ubuntu build and run the *same*
image.

## Prerequisites

| Platform | Requirement |
| --- | --- |
| **Windows** | [Docker Desktop](https://www.docker.com/products/docker-desktop/) (WSL2 backend), 4 GB+ RAM allocated to Docker |
| **Ubuntu**  | `docker` + `docker compose` (`sudo apt install docker.io docker-compose-v2`) |

> The first build compiles Proxygen and all its dependencies from source. Expect
> **30–60 minutes** and give Docker **at least 4 GB RAM**. It is cached afterward.

## Quick start

From this directory (`e:\zhang\proxygen` on Windows):

```bash
docker compose up --build
```

Then open **http://localhost:8080** in a browser. Sign up, log out, log back in —
your session persists via an `HttpOnly` cookie, and accounts survive restarts
because the database lives on a named Docker volume.

On **Windows PowerShell** the command is identical:

```powershell
docker compose up --build
```

To run it in the background: `docker compose up --build -d`
To stop it: `docker compose down` (add `-v` to also wipe the accounts volume).

### Without compose (plain docker)

```bash
docker build -t proxygen-auth .
docker run --rm -p 8080:8080 -v proxygen_auth_data:/app/data proxygen-auth
```

## HTTP API

All request/response bodies are JSON. Session is carried in the `session` cookie.

| Method | Path          | Body                                  | Purpose |
| ------ | ------------- | ------------------------------------- | ------- |
| POST   | `/api/signup` | `{"username": "...", "password": "..."}` | Create account, start session |
| POST   | `/api/login`  | `{"username": "...", "password": "..."}` | Verify credentials, start session |
| POST   | `/api/logout` | — (uses session cookie)               | End the current session |
| GET    | `/api/me`     | — (uses session cookie)               | Returns `{authenticated, username}` |
| GET    | `/`, `/*.css`, `/*.js` | —                            | Static web UI |

Validation rules: username 3–64 chars (`[A-Za-z0-9._-]`), password 8–256 chars.

### Try it with curl

```bash
# sign up (save cookies to a jar)
curl -c cookies.txt -X POST http://localhost:8080/api/signup \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"hunter2pass"}'

# who am I? (send the cookie jar)
curl -b cookies.txt http://localhost:8080/api/me

# log out
curl -b cookies.txt -X POST http://localhost:8080/api/logout
```

## Configuration

The server binary accepts these flags (already wired into the Docker `CMD`):

| Flag           | Default            | Meaning |
| -------------- | ------------------ | ------- |
| `--host`       | `0.0.0.0`          | Bind address |
| `--port`       | `8080`             | Listen port |
| `--threads`    | `0` (= CPU cores)  | Worker threads |
| `--db`         | `data/users.db`    | SQLite file path |
| `--static_dir` | `static`           | Directory of static assets |

Override at runtime, e.g.: `docker run ... proxygen-auth --port=9000`.

Pin a specific Proxygen release instead of `main`:

```bash
docker build --build-arg PROXYGEN_REF=v2025.01.06.00 -t proxygen-auth .
```

## Project layout

```
CMakeLists.txt        # CMake build (links proxygen + sqlite3 + openssl)
Dockerfile            # Builds Proxygen from source, then this app
docker-compose.yml    # One-command build/run with a persistent volume
src/
  main.cpp            # Server setup: options, threads, signal handling
  Handlers.{h,cpp}    # Routing factory + signup/login/logout/me/static handlers
  UserDb.{h,cpp}      # Thread-safe SQLite store for users & sessions
  Auth.{h,cpp}        # PBKDF2 password hashing + secure token generation (OpenSSL)
static/               # index.html, style.css, app.js  (the web UI)
data/                 # SQLite database (created at runtime; git-ignored)
```

## Security notes

- Passwords are hashed with **PBKDF2-HMAC-SHA256**, 210k iterations, per-user
  random 16-byte salt; verification is constant-time.
- Session tokens are 32 bytes of CSPRNG output; cookies are `HttpOnly` +
  `SameSite=Lax`.
- For public deployment put this behind a TLS terminator (reverse proxy) and add
  the `Secure` cookie attribute — the current setup serves plain HTTP inside the
  container, intended to sit behind a proxy or be used locally.

## Building natively (advanced, Ubuntu/macOS only)

If you'd rather build outside Docker on a Linux/macOS host:

```bash
git clone https://github.com/facebook/proxygen.git
cd proxygen
python3 ./build/fbcode_builder/getdeps.py --allow-system-packages \
  build --install-prefix /opt/pg proxygen
cd /path/to/this/project
cmake -S . -B build -DCMAKE_PREFIX_PATH=/opt/pg -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
./build/server
```

This path is **not available on native Windows** — use Docker there.
