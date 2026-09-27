//! Raw FFI bindings to the C ABI exported by `cpp/bitte_torrent.cpp`
//! (libtorrent-backed engine). The static C++ library is built ahead of time
//! by `scripts/build-android-native.sh`; this build script only wires the
//! linker flags when `BITTE_BT_PREFIX` is set (Android cross-builds).
//!
//! On plain `cargo check`/`cargo test` (Linux CI, no prefix) the crate still
//! compiles: the extern declarations simply never link.

use std::env;

fn main() {
    println!("cargo:rerun-if-env-changed=BITTE_BT_PREFIX");
    println!("cargo:rerun-if-env-changed=BITTE_OPENSSL_PREFIX");
    println!("cargo:rerun-if-changed=cpp/bitte_torrent.h");

    let target = env::var("TARGET").unwrap_or_default();

    if target.contains("android") {
        println!("cargo:rustc-link-lib=dylib=c++_shared");
        println!("cargo:rustc-link-lib=log");
        println!("cargo:rustc-link-lib=z");
    } else {
        // host smoke tests: the static C++ archive needs libstdc++
        println!("cargo:rustc-link-lib=dylib=stdc++");
    }

    if let Ok(prefix) = env::var("BITTE_BT_PREFIX") {
        println!("cargo:rustc-link-search=native={prefix}/lib");
        println!("cargo:rustc-link-search=native={prefix}/lib64");
        println!("cargo:rustc-link-lib=static=bitte_bt_cpp");
        println!("cargo:rustc-link-lib=static=torrent-rasterbar");
        if let Ok(ssl) = env::var("BITTE_OPENSSL_PREFIX") {
            println!("cargo:rustc-link-search=native={ssl}");
            println!("cargo:rustc-link-search=native={ssl}/lib");
            println!("cargo:rustc-link-search=native={ssl}/lib64");
        } else if !target.contains("android") {
            // host smoke builds: distro multiarch locations
            println!("cargo:rustc-link-search=native=/usr/lib/x86_64-linux-gnu");
            println!("cargo:rustc-link-search=native=/usr/lib/aarch64-linux-gnu");
        }
        println!("cargo:rustc-link-lib=static=ssl");
        println!("cargo:rustc-link-lib=static=crypto");
    }
}
