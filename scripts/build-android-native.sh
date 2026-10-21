#!/usr/bin/env bash
# Build the complete Android native stack:
#   OpenSSL (static) -> libtorrent (static) -> bitte_bt_cpp (static)
#   -> libbitte_core.so (Rust cdylib, via cargo-ndk) -> app jniLibs
#
# Everything is cached under $BITTE_BUILD_DIR (default <repo>/build/android-deps)
# so CI restores a single directory between runs.
#
# Required env (CI provides): ANDROID_NDK_LATEST_HOME or ANDROID_NDK_HOME.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/versions.env"

WORK="${BITTE_BUILD_DIR:-$REPO_ROOT/build/android-deps}"
NDK="${ANDROID_NDK_LATEST_HOME:-${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}}"
if [ -z "$NDK" ] || [ ! -d "$NDK" ]; then
    echo "ERROR: Android NDK not found (set ANDROID_NDK_LATEST_HOME)" >&2
    exit 1
fi
HOST_TAG="linux-x86_64"
TC="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
JOBS="$(nproc)"

DL="$WORK/downloads"; SRC="$WORK/src"; DEPS_ROOT="$WORK/deps"; BUILD="$WORK/build"
mkdir -p "$DL" "$SRC" "$DEPS_ROOT" "$BUILD"
JNI_OUT="${JNI_OUT_DIR:-$REPO_ROOT/app/android/app/src/main/jniLibs}"

fetch() { # fetch <url> <dest>
    if [ ! -f "$2" ]; then
        echo ">> downloading $(basename "$2")"
        curl -fL --retry 3 --retry-delay 5 -o "$2.part" "$1"
        mv "$2.part" "$2"
    fi
}

# ---------------------------------------------------------------------------
# sources
# ---------------------------------------------------------------------------
BOOST_TGZ="$DL/boost-$BOOST_VERSION.tar.gz"
fetch "https://github.com/boostorg/boost/releases/download/boost-$BOOST_VERSION/boost-$BOOST_VERSION-b2-nodocs.tar.gz" "$BOOST_TGZ"
BOOST_SRC="$SRC/boost-$BOOST_VERSION"
if [ ! -f "$BOOST_SRC/boost/version.hpp" ]; then
    echo ">> extracting boost"
    rm -rf "$BOOST_SRC"; mkdir -p "$BOOST_SRC"
    tar xzf "$BOOST_TGZ" -C "$BOOST_SRC" --strip-components=1
fi

OSS_TGZ="$DL/openssl-$OPENSSL_VERSION.tar.gz"
fetch "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz" "$OSS_TGZ"

LT_TGZ="$DL/libtorrent-$LIBTORRENT_VERSION.tar.gz"
fetch "https://github.com/arvidn/libtorrent/releases/download/v$LIBTORRENT_VERSION/libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz" "$LT_TGZ"
LT_SRC="$SRC/libtorrent-$LIBTORRENT_VERSION"
if [ ! -f "$LT_SRC/CMakeLists.txt" ]; then
    echo ">> extracting libtorrent"
    rm -rf "$LT_SRC"; mkdir -p "$LT_SRC"
    tar xzf "$LT_TGZ" -C "$LT_SRC" --strip-components=1
fi

BOOST_SHIM_DIR="$REPO_ROOT/core/bitte-bt/cmake"

# ---------------------------------------------------------------------------
# per-ABI deps
# ---------------------------------------------------------------------------
build_openssl() { # <abi> <oss-target> <deps>
    local ABI="$1" OSST="$2" DEPS="$3"
    if [ -f "$DEPS/lib/libssl.a" ] && [ -f "$DEPS/lib/libcrypto.a" ]; then
        echo ">> openssl[$ABI] cached"
        return
    fi
    echo ">> building openssl[$ABI]"
    local SDIR="$BUILD/openssl-$ABI"
    rm -rf "$SDIR"; mkdir -p "$SDIR"
    tar xzf "$OSS_TGZ" -C "$SDIR" --strip-components=1
    pushd "$SDIR" >/dev/null
    export PATH="$TC/bin:$PATH"
    export ANDROID_NDK_ROOT="$NDK"
    ./Configure "$OSST" no-shared no-tests no-docs \
        -D__ANDROID_API__=$ANDROID_API --prefix="$DEPS" --openssldir="$DEPS/ssl" -O3
    make -j"$JOBS"
    make install_sw
    popd >/dev/null
}

build_libtorrent() { # <abi> <deps>
    local ABI="$1" DEPS="$2"
    if [ -f "$DEPS/lib/libtorrent-rasterbar.a" ]; then
        echo ">> libtorrent[$ABI] cached"
        return
    fi
    echo ">> building libtorrent[$ABI]"
    cmake -S "$LT_SRC" -B "$BUILD/lt-$ABI" --fresh \
        -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$ABI" \
        -DANDROID_PLATFORM="android-$ANDROID_API" \
        -DANDROID_STL=c++_shared \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
        -DBUILD_SHARED_LIBS=OFF \
        -DBoost_DIR="$BOOST_SHIM_DIR" \
        -DBITTE_BOOST_INCLUDE="$BOOST_SRC" \
        -DOPENSSL_ROOT_DIR="$DEPS" \
        -DOPENSSL_INCLUDE_DIR="$DEPS/include" \
        -DOPENSSL_CRYPTO_LIBRARY="$DEPS/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="$DEPS/lib/libssl.a" \
        -DOPENSSL_USE_STATIC_LIBS=TRUE \
        -Dwebtorrent=OFF \
        -Dbuild_tests=OFF -Dbuild_examples=OFF -Dbuild_tools=OFF \
        -Dpython-bindings=OFF -Dpython-egg-info=OFF \
        -Diconv=OFF \
        -DCMAKE_INSTALL_PREFIX="$DEPS" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    cmake --build "$BUILD/lt-$ABI" -j"$JOBS"
    cmake --install "$BUILD/lt-$ABI"
}

build_cpp_wrapper() { # <abi> <deps>
    local ABI="$1" DEPS="$2"
    echo ">> building bitte_bt_cpp[$ABI]"
    cmake -S "$REPO_ROOT/core/bitte-bt/cpp" -B "$BUILD/cpp-$ABI" --fresh \
        -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$ABI" \
        -DANDROID_PLATFORM="android-$ANDROID_API" \
        -DANDROID_STL=c++_shared \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
        -DCMAKE_PREFIX_PATH="$DEPS" \
        -DLibtorrentRasterbar_DIR="$DEPS/lib/cmake/LibtorrentRasterbar" \
        -DBoost_DIR="$BOOST_SHIM_DIR" \
        -DBITTE_BOOST_INCLUDE="$BOOST_SRC" \
        -DOPENSSL_ROOT_DIR="$DEPS" \
        -DOPENSSL_INCLUDE_DIR="$DEPS/include" \
        -DOPENSSL_CRYPTO_LIBRARY="$DEPS/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="$DEPS/lib/libssl.a" \
        -DOPENSSL_USE_STATIC_LIBS=TRUE \
        -DCMAKE_INSTALL_PREFIX="$DEPS" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    cmake --build "$BUILD/cpp-$ABI" -j"$JOBS"
    cmake --install "$BUILD/cpp-$ABI"
}

# ---------------------------------------------------------------------------
# rust cdylib per ABI
# ---------------------------------------------------------------------------
build_rust() { # <abi> <rust-target> <deps>
    local ABI="$1" RT="$2" DEPS="$3"
    echo ">> building libbitte_core.so[$ABI]"
    pushd "$REPO_ROOT/core" >/dev/null
    BITTE_BT_PREFIX="$DEPS" BITTE_OPENSSL_PREFIX="$DEPS" \
        cargo ndk --platform "$ANDROID_API" -t "$ABI" -o "$JNI_OUT" \
        build --profile "$RUST_PROFILE" -p bitte-ffi --features native-bt --target "$RT"
    popd >/dev/null
}

for ABI in $ABIS; do
    DEPS="$DEPS_ROOT/$ABI"
    mkdir -p "$DEPS"
    case "$ABI" in
        arm64-v8a)   OSS_TARGET="android-arm64";  RUST_TARGET="aarch64-linux-android";  SYSROOT_TRIPLE="aarch64-linux-android" ;;
        x86_64)      OSS_TARGET="android-x86_64"; RUST_TARGET="x86_64-linux-android";   SYSROOT_TRIPLE="x86_64-linux-android" ;;
        armeabi-v7a) OSS_TARGET="android-arm";    RUST_TARGET="armv7-linux-androideabi"; SYSROOT_TRIPLE="arm-linux-androideabi" ;;
        x86)         OSS_TARGET="android-x86";    RUST_TARGET="i686-linux-android";     SYSROOT_TRIPLE="i686-linux-android" ;;
        *) echo "unknown ABI $ABI" >&2; exit 1 ;;
    esac
    build_openssl "$ABI" "$OSS_TARGET" "$DEPS"
    build_libtorrent "$ABI" "$DEPS"
    build_cpp_wrapper "$ABI" "$DEPS"
    build_rust "$ABI" "$RUST_TARGET" "$DEPS"
    # libbitte_core.so is linked against libc++_shared: ship it alongside
    mkdir -p "$JNI_OUT/$ABI"
    cp "$TC/sysroot/usr/lib/$SYSROOT_TRIPLE/libc++_shared.so" "$JNI_OUT/$ABI/"
done

echo ">> native libs:"
find "$JNI_OUT" -name "*.so" -exec ls -la {} \;
echo ">> done"
