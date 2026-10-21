use std::env;

fn main() {
    println!("cargo:rerun-if-env-changed=BITTE_BT_PREFIX");
    println!("cargo:rerun-if-env-changed=BITTE_OPENSSL_PREFIX");
    println!("cargo:rerun-if-changed=cpp/bitte_torrent.h");

    let target = env::var("TARGET").unwrap_or_default();

    emit_cxx_runtime(&target);

    // The native stack (libtorrent + Boost + OpenSSL + the C++ wrapper) is
    // built out-of-band by scripts/build-*-native.sh and handed to rustc via
    // BITTE_BT_PREFIX. Without the variable nothing is linked, which keeps
    // plain `cargo check/test` working on any platform (the crate only needs
    // the symbols at final cdylib link time).
    if let Ok(prefix) = env::var("BITTE_BT_PREFIX") {
        emit_native_stack(&target, &prefix);
    }
}

/// C++ runtime / platform framework linkage per target family.
///
/// Android and Linux are the shipping paths and must not change; the
/// windows-msvc and apple arms are multi-platform groundwork (see
/// docs/PLATFORMS.md) — they have never been exercised by a build yet and
/// will likely need per-platform OpenSSL/libtorrent prefixes via
/// BITTE_OPENSSL_PREFIX / BITTE_BT_PREFIX.
fn emit_cxx_runtime(target: &str) {
    if target.contains("android") {
        println!("cargo:rustc-link-lib=dylib=c++_shared");
        println!("cargo:rustc-link-lib=log");
        println!("cargo:rustc-link-lib=z");
    } else if target.contains("windows-msvc") {
        // MSVC links the C++ runtime automatically; emitting stdc++ here
        // would break the link.
    } else if target.contains("apple") {
        println!("cargo:rustc-link-lib=dylib=c++");
        // Static OpenSSL pulls in these frameworks on Apple targets.
        println!("cargo:rustc-link-lib=framework=Security");
        println!("cargo:rustc-link-lib=framework=CoreFoundation");
    } else {
        // linux (gnu/musl) and windows-gnu
        println!("cargo:rustc-link-lib=dylib=stdc++");
    }
}

fn emit_native_stack(target: &str, prefix: &str) {
    println!("cargo:rustc-link-search=native={prefix}/lib");
    println!("cargo:rustc-link-search=native={prefix}/lib64");
    println!("cargo:rustc-link-lib=static=bitte_bt_cpp");
    println!("cargo:rustc-link-lib=static=torrent-rasterbar");
    if let Ok(ssl) = env::var("BITTE_OPENSSL_PREFIX") {
        println!("cargo:rustc-link-search=native={ssl}");
        println!("cargo:rustc-link-search=native={ssl}/lib");
        println!("cargo:rustc-link-search=native={ssl}/lib64");
    } else if !target.contains("android") && !target.contains("apple") {
        // Host linux CI: system OpenSSL lives in the multiarch dirs.
        println!("cargo:rustc-link-search=native=/usr/lib/x86_64-linux-gnu");
        println!("cargo:rustc-link-search=native=/usr/lib/aarch64-linux-gnu");
    }
    println!("cargo:rustc-link-lib=static=ssl");
    println!("cargo:rustc-link-lib=static=crypto");
}
