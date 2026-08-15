# Editing & building this server — fully offline

You received the **offline dev bundle** of a Proxygen HTTP auth server. This guide
explains how to run it, change the code, and rebuild it **without any internet**.

Proxygen (the C++ HTTP library this is built on) is shipped here **prebuilt** in
`.deps/install/`, so you never recompile that slow part. You only recompile the
small application in `src/`.

---

## 0. Requirements

- **Linux, x86-64**, with a **glibc no older** than the machine this was built
  on. `offline/BUNDLE-INFO.txt` records that machine's distro and glibc version;
  compare with `ldd --version` here. (If it runs, you're fine.)
- Build tools: either already installed (`cmake`, `ninja`/`make`, `g++`, plus
  the sqlite3 and openssl development headers), **or** installed offline from
  the packages bundled in `offline/debs` (Ubuntu/Debian) or `offline/rpms`
  (CentOS Stream 9 / RHEL 9 / Rocky / Alma) by the build script below. No
  internet needed either way.

Extract the bundle first:

```bash
mkdir proxygen && tar -xzf proxygen-offline-bundle-*.tar.gz -C proxygen
cd proxygen
chmod +x run.sh offline/*.sh
```

> Tip: extract to a stable location you won't move (e.g. your home dir). If
> `cmake` later can't find Proxygen, see Troubleshooting at the bottom.

---

## 1. Run it as-is (no build)

```bash
./run.sh
```

Open **http://localhost:8080**. Sign up, log in, log out. Accounts are stored in
`data/users.db`.

---

## 2. Edit → rebuild → run (the loop)

1. Edit any file under `src/` (see the map below).
2. Rebuild **offline**:

   ```bash
   ./offline/offline-build.sh
   ```

   - If your machine already has the build tools, skip the bundled packages:
     `SKIP_PKGS=1 ./offline/offline-build.sh`
3. Run your new build:

   ```bash
   ./run.sh
   ```

That's the whole cycle. Rebuilds are fast — only the app compiles, not Proxygen.

---

## 3. Where the code is

```
src/
  main.cpp          Server startup: port/host/threads, command-line flags
  Handlers.{h,cpp}  URL routing + the /api/signup /login /logout /me handlers
  UserDb.{h,cpp}    SQLite storage; account rules (username/password validation)
  Auth.{h,cpp}      Password hashing (PBKDF2) + random session tokens
static/
  index.html        The web page (login/signup form)
  style.css         Colors and layout
  app.js            Frontend logic that calls the /api endpoints
CMakeLists.txt      Build definition (rarely needs editing)
```

---

## 4. Common customizations

Each of these is a small edit; rebuild with `./offline/offline-build.sh` after.

### Change the port or bind address
Edit `run.sh` (the `--port=` / `--host=` values), or pass flags at runtime:
```bash
./run.sh --port=9000
```

### Change password / username rules
In `src/UserDb.cpp`:
- `validUsername()` — allowed characters and length.
- `createUser()` — the `password.size() < 8` check sets the minimum length.

### Change how long a login lasts
In `src/Handlers.cpp`, near the top:
```cpp
constexpr int64_t kSessionTtlSeconds = 7 * 24 * 60 * 60; // 7 days
```

### Restyle the UI
Edit `static/style.css` (colors are the `--accent`, `--bg`, etc. variables at the
top) and `static/index.html`. **No rebuild needed for static files** — just edit
and refresh the browser (they're read from disk at request time).

### Add a new API endpoint
In `src/Handlers.cpp`:
1. Add a handler class (copy `MeHandler` as a template).
2. Register its route in `AuthHandlerFactory::onRequest(...)` alongside the
   existing `if (path == "/api/...")` checks.
Rebuild and it's live.

### Add a field to signup (e.g. an email)
1. `static/index.html` + `static/app.js` — add the input and include it in the
   JSON sent to `/api/signup`.
2. `src/UserDb.cpp` — add an `email` column to the `users` table (in the
   `CREATE TABLE` string) and to the `INSERT` in `createUser()`.
3. `src/Handlers.cpp` — read it with `jsonStr(json, "email")` in `SignupHandler`
   and pass it through.
Rebuild.

---

## 5. Advanced: rebuild Proxygen itself from source (offline)

Only relevant if the bundle was made with `WITH_SOURCES=1` (it then also contains
`.deps/proxygen-src` and `.deps/scratch`). This recompiles the entire Proxygen
stack locally — slow (30-60 min) but produces a prefix with paths native to your
machine:

```bash
REBUILD_PROXYGEN=1 ./offline/offline-build.sh && ./run.sh
```

If your bundle doesn't contain `.deps/scratch`, this option isn't available —
stick with the prebuilt prefix (Sections 1–2).

---

## 6. Share your customized build

Once you're happy with your changes, make your own run-only bundle to pass along:

```bash
./offline/package-portable.sh     # -> proxygen-portable-amd64.tar.gz
```

Whoever receives it just runs `./run.sh` (no build needed).

---

## Troubleshooting (offline)

- **`error while loading shared libraries: libfolly…`** → run via `./run.sh`
  (it sets the library path). If it persists, your glibc is older than the build
  machine's — you'll need a bundle built on your distro version.
- **`version 'GLIBC_2.35' not found`** → the bundle was built on a newer-glibc
  distro (e.g. Ubuntu 22.04) than this machine (e.g. CentOS Stream 9 / RHEL 9,
  glibc 2.34). See `OFFLINE-CENTOS9.md` — it has both the quick unblock and how
  to build a proper EL9 bundle.
- **`sudo dpkg: command not found` on CentOS/RHEL** → that bundle carries
  Ubuntu `.deb`s. You need an EL9-built bundle (`offline/rpms/`); see
  `OFFLINE-CENTOS9.md`.
- **`cmake` can't find Proxygen / `find_package(proxygen)` fails** → the prebuilt
  prefix has absolute paths from the original build machine. Fixes, easiest first:
  1. Extract the bundle to the **same absolute path** it was built at (ask the
     sender what that was), or
  2. If the bundle has sources, rebuild Proxygen locally:
     `REBUILD_PROXYGEN=1 ./offline/offline-build.sh`.
- **`dpkg`/`rpm` errors about dependencies** → your machine is missing a base
  package the bundled packages expect. If you already have build tools, just use
  `SKIP_PKGS=1 ./offline/offline-build.sh`.
- **No compiler at all and no bundled packages** → you need
  `build-essential cmake ninja-build libsqlite3-dev libssl-dev` (Ubuntu) or
  `gcc-c++ make cmake ninja-build sqlite-devel openssl-devel` (EL9) installed
  some other way; they can't be fetched offline.
