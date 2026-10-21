#!/usr/bin/env bash
# Host (linux-x86_64) build of the native stack for the FFI smoke test job.
# Uses system OpenSSL + system Boost headers from the runner image.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/versions.env"

WORK="${BITTE_BUILD_DIR:-$REPO_ROOT/build/linux-deps}"
SRC="$WORK/src"; DEPS="$WORK/deps"; BUILD="$WORK/build"
mkdir -p "$SRC" "$DEPS" "$BUILD"

LT_TGZ="$WORK/libtorrent-$LIBTORRENT_VERSION.tar.gz"
if [ ! -f "$LT_TGZ" ]; then
    curl -fL --retry 3 -o "$LT_TGZ" \
        "https://github.com/arvidn/libtorrent/releases/download/v$LIBTORRENT_VERSION/libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz"
fi
LT_SRC="$SRC/libtorrent-$LIBTORRENT_VERSION"
if [ ! -f "$LT_SRC/CMakeLists.txt" ]; then
    rm -rf "$LT_SRC"; mkdir -p "$LT_SRC"
    tar xzf "$LT_TGZ" -C "$LT_SRC" --strip-components=1
fi

if [ ! -f "$DEPS/lib/libtorrent-rasterbar.a" ]; then
    echo ">> building libtorrent (host)"
    cmake -S "$LT_SRC" -B "$BUILD/lt" --fresh \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -Dwebtorrent=OFF \
        -Dbuild_tests=OFF -Dbuild_examples=OFF -Dbuild_tools=OFF \
        -Dpython-bindings=OFF -Dpython-egg-info=OFF \
        -DCMAKE_INSTALL_PREFIX="$DEPS" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    cmake --build "$BUILD/lt" -j"$(nproc)"
    cmake --install "$BUILD/lt"
else
    echo ">> libtorrent (host) cached"
fi

echo ">> building bitte_bt_cpp (host)"
cmake -S "$REPO_ROOT/core/bitte-bt/cpp" -B "$BUILD/cpp" --fresh \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$DEPS" \
    -DCMAKE_INSTALL_PREFIX="$DEPS" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "$BUILD/cpp" -j"$(nproc)"
cmake --install "$BUILD/cpp"
echo ">> host native stack ready at $DEPS"
