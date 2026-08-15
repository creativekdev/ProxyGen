# Offline build for CentOS Stream 9 / RHEL 9 (glibc 2.34)

This covers building an offline bundle that runs on **CentOS Stream 9, RHEL 9,
Rocky Linux 9 and AlmaLinux 9** — the EL9 family, all of which ship **glibc
2.34**.

> There is no "CentOS 9" release as such: CentOS Linux stopped at 8. What you
> have is almost certainly **CentOS Stream 9**. Everything here applies equally
> to RHEL 9 / Rocky 9 / Alma 9 — same glibc, same RPMs, same result.

---

## Why the old bundle fails there

The existing `proxygen-offline-bundle.tar.gz` was built on **Ubuntu 22.04**,
which has **glibc 2.35**. glibc is forward-compatible only: something built
against 2.35 cannot run on 2.34.

Scanning that bundle, exactly one file is over the line:

| File | Needs |
| --- | --- |
| `offline/runtime-libs/libgcc_s.so.1` | `GLIBC_2.35` ❌ |
| `bin/server` | `GLIBC_2.34` ✅ |
| `offline/runtime-libs/libstdc++.so.6` and the other 12 libs | `GLIBC_2.34` ✅ |

`libgcc_s.so.1` is part of the compiler runtime that is built against the build
machine's glibc — it must come from the **target** system, exactly like
`libc.so.6` itself. `prefetch.sh` was copying it into the bundle, and `run.sh`
puts that directory on `LD_LIBRARY_PATH`, so on CentOS 9 the loader picks up
Ubuntu's `libgcc_s.so.1`, which then demands `GLIBC_2.35` and everything stops
with:

```
error while loading shared libraries: libgcc_s.so.1:
  version `GLIBC_2.35' not found (required by ...)
```

Two fixes, in increasing order of thoroughness.

---

## Fix A — unblock the bundle you already have (30 seconds)

On the CentOS 9 machine, inside the extracted bundle:

```bash
rm -f offline/runtime-libs/libgcc_s.so.1
./run.sh
```

CentOS 9's own `libgcc_s.so.1` takes over. It is new enough: `bin/server` only
asks for `GCC_3.0` symbols, and the bundled `libstdc++.so.6` (which the binary
*does* need, because it wants `GLIBCXX_3.4.30` and EL9 only ships `3.4.29`) is
itself clean at glibc 2.34.

This gets the **prebuilt server running**. It does not give you an offline
*rebuild*, because the bundle carries Ubuntu `.deb`s and CentOS has no `dpkg`.
For that, use Fix B.

The scripts in this repo no longer bundle `libgcc_s.so.1`, so bundles you build
from now on don't need this step.

---

## Fix B — build a real EL9 bundle

Pick whichever machine you have.

### Option 1 — from Windows, with Docker Desktop (no CentOS machine needed)

```powershell
cd e:\zhang\ProxyGen\ProxyGen
docker build -f Dockerfile.el9 --target bundle -o type=local,dest=.\out .
```

→ `out\proxygen-offline-bundle-el9.tar.gz`

First run takes ~30–60 min (Proxygen compiles from source) and wants **≥ 4 GB
RAM** given to Docker — raise it in Docker Desktop → Settings → Resources.

Want the small run-only artifact instead of the full dev bundle?

```powershell
docker build -f Dockerfile.el9 --target portable -o type=local,dest=.\out .
```

→ `out\proxygen-portable-el9-x86_64.tar.gz` (binary + libs + web UI + launcher)

Other EL9 bases work the same way:

```powershell
docker build -f Dockerfile.el9 --build-arg BASE_IMAGE=rockylinux:9 --target bundle -o type=local,dest=.\out .
```

### Option 2 — on an online CentOS Stream 9 machine (end to end)

This is the full walkthrough: build on **your online CentOS box**, pack there,
hand the result to an **air-gapped CentOS box**.

**What the build machine needs:** CentOS Stream 9 (or RHEL/Rocky/Alma 9),
`x86_64`, **internet**, `sudo`, **≥ 4 GB RAM**, **≥ 25 GB free disk**, and
30–60 minutes. It must be the *same major version* as your friend's machine.

#### Step 1 — get the project onto the CentOS box

If the repo has a git remote, just clone it. Otherwise copy the source across —
from Windows PowerShell, in the project's parent directory:

```powershell
tar --exclude=.git --exclude=.deps --exclude=build --exclude=bin `
    --exclude=offline/debs --exclude=offline/rpms --exclude=offline/runtime-libs `
    --exclude=*.tar.gz -czf proxygen-src.tar.gz ProxyGen
scp proxygen-src.tar.gz user@centos-box:~/
```

Then on the CentOS box:

```bash
tar -xzf proxygen-src.tar.gz && cd ProxyGen
chmod +x build.sh run.sh offline/*.sh
```

> If a script dies with `bad interpreter: /usr/bin/env bash^M`, the files picked
> up Windows CRLF endings in transit: `sed -i 's/\r$//' build.sh run.sh offline/*.sh`.
> (`.gitattributes` prevents this when you go through git.)

#### Step 2 — build and pack, one command

```bash
./offline/prefetch.sh
```

It prints the distro/glibc/arch it is building for, then:
1. installs build packages (enables **CRB** + **EPEL** first — several `-devel`
   packages live only there) and compiles Proxygen + the app *(slow part)*;
2. downloads the `.rpm` closure for an offline recompile into `offline/rpms/`;
3. copies the runtime `.so` files the binary needs into `offline/runtime-libs/`;
4. writes **`proxygen-offline-bundle-el9.tar.gz`** (~2 GB).

Want the small run-only artifact as well? It reuses the same build, so it's quick:

```bash
./offline/package-portable.sh   # → proxygen-portable-el9-x86_64.tar.gz
```

#### Step 3 — verify before you send it

```bash
./run.sh &                                   # smoke test
curl -s localhost:8080/api/me; echo          # → {"authenticated":false}
kill %1

# nothing in the bundle may need a glibc newer than the target's 2.34:
for f in bin/server offline/runtime-libs/* $(find .deps/install -name '*.so*'); do
  v=$(grep -ao 'GLIBC_2\.3[5-9]' "$f" 2>/dev/null | sort -u | tr '\n' ' ')
  [ -n "$v" ] && echo "TOO NEW: $f needs $v"
done; echo "audit done"
```

#### Step 4 — hand it over

Send `proxygen-offline-bundle-el9.tar.gz` (editable) or
`proxygen-portable-el9-x86_64.tar.gz` (run-only). Nothing else is needed — no
internet, no repos, no build tools on the receiving end.

---

## Using the bundle on the air-gapped CentOS 9 box

```bash
mkdir proxygen && tar -xzf proxygen-offline-bundle-el9.tar.gz -C proxygen
cd proxygen
chmod +x run.sh offline/*.sh

./run.sh                        # run the prebuilt binary right away, OR
./offline/offline-build.sh      # install bundled RPMs + recompile src/, then ./run.sh
```

`offline-build.sh` installs `offline/rpms/*.rpm` with
`dnf --disablerepo='*' install` (never touches the network), then compiles the
app against the prebuilt Proxygen prefix. If the machine already has
`gcc-c++`/`cmake`/`ninja` and the `sqlite-devel`/`openssl-devel` headers:

```bash
SKIP_PKGS=1 ./offline/offline-build.sh
```

`offline/BUNDLE-INFO.txt` inside the bundle records the distro, glibc version
and architecture it was built on; `offline-build.sh` prints it next to the
current machine's so a mismatch is obvious.

---

## Checking compatibility yourself

On the target machine:

```bash
ldd --version | head -1                       # 2.34 on EL9
cat /etc/os-release | head -2
```

To find anything in a bundle that is too new for the target, from inside the
extracted directory:

```bash
for f in bin/server offline/runtime-libs/* $(find .deps/install -name '*.so*'); do
  v=$(grep -ao 'GLIBC_2\.3[5-9]' "$f" 2>/dev/null | sort -u | tr '\n' ' ')
  [ -n "$v" ] && echo "$f needs $v"
done
```

Silence means the bundle is glibc-2.34-safe. That check is exactly how the
`libgcc_s.so.1` problem above was found.

---

## Notes and gotchas

- **Build on the oldest target you support.** EL9 (glibc 2.34) artifacts run on
  Ubuntu 22.04/24.04 too; the reverse is not true. If you must support both, EL9
  is the right build host.
- **`GLIBCXX_3.4.30`.** Ubuntu 22.04's libstdc++ comes from GCC 12; EL9's comes
  from GCC 11 and tops out at `3.4.29`. An EL9-built binary never asks for
  `3.4.30`, so this stops being a concern once you build on EL9.
- **CRB and EPEL are needed at build time only** (`ninja-build`, `gflags-devel`,
  `glog-devel`, `libsodium-devel`, `double-conversion-devel`, `libzstd-devel`,
  `snappy-devel`, `libdwarf-devel`). Package installs are best-effort: anything
  genuinely unavailable is compiled from source by `getdeps` instead, so a
  missing repo costs build time rather than breaking the build.
- **RHEL 9 subscriptions.** On registered RHEL (not CentOS Stream/Rocky/Alma),
  CRB is enabled with
  `subscription-manager repos --enable codeready-builder-for-rhel-9-$(arch)-rpms`.
- **Air-gapped RPM install** uses `--disablerepo='*'`; if some dependency was
  already present on the build machine and therefore absent from the closure,
  the script falls back to `rpm -Uvh` and finally `rpm -Uvh --nodeps`, printing
  what it did.
