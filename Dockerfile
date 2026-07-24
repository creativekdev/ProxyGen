# syntax=docker/dockerfile:1
#
# Builds facebook/proxygen from source (via Meta's getdeps.py), then compiles
# this auth server against it. The same image runs on Windows (Docker Desktop)
# and Ubuntu — Proxygen itself only ever builds/runs on Linux, and the container
# hides that difference.
#
# NOTE: the getdeps step compiles folly/wangle/fizz/mvfst/proxygen from source.
# The first build is SLOW (typically 30-60 min) and wants >=4 GB RAM given to
# Docker. It is cached afterwards, so app-only rebuilds are fast.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Pin the Proxygen revision for reproducible builds. Override at build time with:
#   docker build --build-arg PROXYGEN_REF=v2025.01.06.00 .
# If a pinned tag ever fails to build, set this to "main".
ARG PROXYGEN_REF=main

# --- Toolchain + our app's own system libraries -------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      cmake \
      ninja-build \
      build-essential \
      python3 \
      python3-pip \
      pkg-config \
      ca-certificates \
      sudo \
      libsqlite3-dev \
      libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# --- Build Proxygen + its dependency closure into /opt/pg ---------------------
WORKDIR /src
RUN git clone --depth 1 --branch "${PROXYGEN_REF}" \
      https://github.com/facebook/proxygen.git

WORKDIR /src/proxygen
# Install the apt packages Proxygen's build needs, then build+install the whole
# dependency closure (folly, wangle, fizz, mvfst, proxygen) into one prefix.
RUN python3 ./build/fbcode_builder/getdeps.py \
      --allow-system-packages install-system-deps --recursive proxygen
RUN python3 ./build/fbcode_builder/getdeps.py \
      --allow-system-packages build \
      --install-prefix /opt/pg \
      --no-tests \
      proxygen

# --- Build this application ---------------------------------------------------
# Copy build inputs first so that editing static/ later doesn't rebuild C++.
WORKDIR /app
COPY CMakeLists.txt ./
COPY src ./src
RUN cmake -S . -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH=/opt/pg \
  && cmake --build build -j "$(nproc)"

COPY static ./static

# Proxygen's shared libraries live under the install prefix.
ENV LD_LIBRARY_PATH=/opt/pg/lib:/opt/pg/lib64

# Persist the SQLite database on a mounted volume.
VOLUME ["/app/data"]
EXPOSE 8080

ENTRYPOINT ["/app/build/server"]
CMD ["--host=0.0.0.0", "--port=8080", "--db=/app/data/users.db", "--static_dir=/app/static"]
