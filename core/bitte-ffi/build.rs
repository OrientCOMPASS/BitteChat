//! Links Android's liblog for the direct `__android_log_write` call in the
//! tee logger (we no longer depend on android_logger).

fn main() {
    let target = std::env::var("TARGET").unwrap_or_default();
    if target.contains("android") {
        println!("cargo:rustc-link-lib=log");
    }
}
