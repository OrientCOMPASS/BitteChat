//! `libbitte_core.so` — the C ABI consumed by the Flutter app through
//! dart:ffi. One global registry of API handles; commands cross the boundary
//! as JSON strings; events are DRAINED by the Dart side through
//! `sys.drain_events` (v0.5.27): the old NativeCallable push callback never
//! delivered on Android devices/emulator (events silently vanished), so the
//! queue is now pulled on a 200 ms Dart timer instead.

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::os::raw::c_uint;
use std::panic::AssertUnwindSafe;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use serde_json::{json, Value as Json};

use bitte_core::api::Api;
use bitte_core::engine::{BtEngine, EngineEvent};

type EventRx = std::sync::mpsc::Receiver<EngineEvent>;
type EngineResult = Result<(Arc<dyn BtEngine>, EventRx), String>;

struct HandleEntry {
    api: Api,
    /// keeps the engine (and thus the event sender) alive for the handle
    _engine: Arc<dyn BtEngine>,
    /// UI event queue; drained through `sys.drain_events` (v0.5.27)
    events: std::sync::mpsc::Receiver<String>,
}

static REGISTRY: Mutex<Option<HashMap<i64, HandleEntry>>> = Mutex::new(None);
static NEXT_HANDLE: AtomicI64 = AtomicI64::new(1);

fn with_registry<R>(f: impl FnOnce(&mut HashMap<i64, HandleEntry>) -> R) -> R {
    let mut guard = REGISTRY.lock().unwrap_or_else(|e| e.into_inner());
    let map = guard.get_or_insert_with(HashMap::new);
    f(map)
}

fn cstr_to_str<'a>(p: *const c_char) -> &'a str {
    if p.is_null() {
        return "";
    }
    unsafe { CStr::from_ptr(p) }.to_str().unwrap_or("")
}

fn to_c_string(s: String) -> *mut c_char {
    // SAFETY: allocation transferred to the caller who must free via bc_free
    let c = CString::new(s).unwrap_or_else(|_| CString::new("{}".to_string()).unwrap());
    c.into_raw()
}

fn json_error(msg: &str) -> String {
    json!({"ok": false, "error": msg}).to_string()
}

/// Global logger: tees every record to a rolling file under
/// `<data_dir>/logs/core.log` (exportable from the settings page) and to
/// logcat on Android. The file sink flushes per line so the log survives
/// hard crashes — that is the whole point.
struct TeeLogger {
    file: bitte_core::filelog::FileLog,
}

impl log::Log for TeeLogger {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::Level::Info
    }

    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let line = bitte_core::filelog::format_record(record).replace('\n', " | ");
        #[cfg(target_os = "android")]
        {
            let prio = match record.level() {
                log::Level::Error => 6,
                log::Level::Warn => 5,
                log::Level::Info => 4,
                log::Level::Debug => 3,
                log::Level::Trace => 2,
            };
            if let (Ok(tag), Ok(msg)) = (CString::new("bitte"), CString::new(line.clone())) {
                unsafe {
                    android_log_write(prio, tag.as_ptr(), msg.as_ptr());
                }
            }
        }
        self.file.line(&line);
    }

    fn flush(&self) {}
}

#[cfg(target_os = "android")]
extern "C" {
    fn __android_log_write(prio: i32, tag: *const c_char, text: *const c_char) -> i32;
}

#[cfg(target_os = "android")]
use __android_log_write as android_log_write;

static TEE_LOGGER: OnceLock<TeeLogger> = OnceLock::new();

/// Directory (`<data_dir>/logs`) the panic hook writes `crash_rust.log` into.
/// Set during [bc_init]; the hook is a no-op before that.
static CRASH_DIR: OnceLock<std::path::PathBuf> = OnceLock::new();

/// Append a Rust panic record (message, thread, forced backtrace) to
/// `<data_dir>/logs/crash_rust.log`, bounded like the other logs. Written
/// DIRECTLY (not through the logger) so it survives even when the panic fires
/// while the engine/logger is being torn down — e.g. the resume-from-
/// background crash.
fn write_crash_dump(msg: &str) {
    use std::io::Write;
    let dir = match CRASH_DIR.get() {
        Some(d) => d.clone(),
        None => return,
    };
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join("crash_rust.log");
    let thread = std::thread::current()
        .name()
        .unwrap_or("<unnamed>")
        .to_string();
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let bt = std::backtrace::Backtrace::force_capture();
    let mut f = match std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        Ok(f) => f,
        Err(_) => return,
    };
    let _ = writeln!(
        f,
        "=== rust panic ts={ts} thread={thread} ===\n{msg}\nbacktrace:\n{bt}\n"
    );
    drop(f);
    // keep it bounded: beyond ~256 KiB keep the newer half of the lines
    let too_big = std::fs::metadata(&path)
        .map(|m| m.len() > 256 * 1024)
        .unwrap_or(false);
    if !too_big {
        return;
    }
    if let Ok(content) = std::fs::read_to_string(&path) {
        let lines: Vec<&str> = content.lines().collect();
        let keep = &lines[lines.len() / 2..];
        let _ = std::fs::write(
            &path,
            format!("[crash_rust.log trimmed]\n{}\n", keep.join("\n")),
        );
    }
}

/// Hard native crashes (SIGSEGV / SIGABRT / …, e.g. inside
/// libtorrent or mpv) bypass BOTH the Dart zone hook and the Rust panic
/// hook — that is why some crashes left no dump at all. Pre-open the crash
/// log fd and install a signal handler that writes one line (async-signal
/// safe: `write(2)` on a pre-opened fd, no allocation) and then restores the
/// *previous* handler (chaining) before re-raising.
///
/// Chaining matters: host apps / crash reporters installed before us keep
/// working. On Android SIGSEGV is deliberately NOT hooked: ART relies on
/// SIGSEGV for implicit null checks and stack-probe recovery — intercepting
/// and re-raising loses the original siginfo (fault address), turning
/// recoverable faults into hard crashes. The remaining signals still give us
/// a dump line, and Android tombstones are produced either way.
static CRASH_FD: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(-1);

/// Previous handlers per signal number, for chaining in the handler.
static OLD_HANDLERS: [std::sync::atomic::AtomicIsize; 16] =
    [const { std::sync::atomic::AtomicIsize::new(0) }; 16];

/// Signals we install the crash-dump handler for.
#[cfg(target_os = "android")]
const CRASH_SIGNALS: [libc::c_int; 4] = [libc::SIGABRT, libc::SIGBUS, libc::SIGILL, libc::SIGFPE];
#[cfg(not(target_os = "android"))]
const CRASH_SIGNALS: [libc::c_int; 5] = [
    libc::SIGSEGV,
    libc::SIGABRT,
    libc::SIGBUS,
    libc::SIGILL,
    libc::SIGFPE,
];

#[cfg(unix)]
unsafe extern "C" fn native_crash_handler(sig: i32) {
    let fd = CRASH_FD.load(std::sync::atomic::Ordering::Relaxed);
    if fd >= 0 {
        let ts = libc::time(std::ptr::null_mut());
        let mut buf = [0u8; 128];
        let mut pos = 0usize;
        // closure-free helpers: everything stays on the stack (signal safe)
        unsafe fn push(b: u8, buf: &mut [u8; 128], pos: &mut usize) {
            if *pos < buf.len() {
                buf[*pos] = b;
                *pos += 1;
            }
        }
        unsafe fn push_num(mut x: u64, buf: &mut [u8; 128], pos: &mut usize) {
            let mut tmp = [0u8; 24];
            let mut n = 0usize;
            if x == 0 {
                tmp[0] = b'0';
                n = 1;
            }
            while x > 0 {
                tmp[n] = (x % 10) as u8 + b'0';
                x /= 10;
                n += 1;
            }
            while n > 0 {
                n -= 1;
                push(tmp[n], buf, pos);
            }
        }
        for &b in b"=== native signal crash sig=".iter() {
            push(b, &mut buf, &mut pos);
        }
        push_num(sig as u64, &mut buf, &mut pos);
        for &b in b" ts=".iter() {
            push(b, &mut buf, &mut pos);
        }
        push_num(ts as u64, &mut buf, &mut pos);
        for &b in b" (hard native crash; see tombstone for the native backtrace)\n".iter() {
            push(b, &mut buf, &mut pos);
        }
        libc::write(fd, buf.as_ptr() as *const libc::c_void, pos);
    }
    // chain to the previous handler (or SIG_DFL if there was none) so ART /
    // host crash reporters still see the signal with a chance to act
    let old = if (sig as usize) < OLD_HANDLERS.len() {
        OLD_HANDLERS[sig as usize].load(std::sync::atomic::Ordering::Relaxed)
    } else {
        libc::SIG_DFL as isize
    };
    libc::signal(sig, old as libc::sighandler_t);
    libc::raise(sig);
}

fn init_logging(data_dir: &str) {
    let logger = TeeLogger {
        file: bitte_core::filelog::FileLog::open(std::path::Path::new(data_dir)),
    };
    if TEE_LOGGER.set(logger).is_ok() {
        let _ = log::set_logger(TEE_LOGGER.get().unwrap());
        log::set_max_level(log::LevelFilter::Info);
    }
}

fn create_engine(cfg: Json) -> EngineResult {
    #[cfg(feature = "native-bt")]
    {
        bitte_core::lt::create_engine(cfg).map_err(|e| e.to_string())
    }
    #[cfg(not(feature = "native-bt"))]
    {
        let _ = cfg;
        let bus = bitte_core::mock::MockBus::new();
        let (eng, rx) = bitte_core::mock::MockEngine::new(bus);
        Ok((Arc::new(eng) as Arc<dyn BtEngine>, rx))
    }
}

/// Create the core. Returns a positive handle, or a negative error code.
///
/// `cfg_json`: {"data_dir": "...", "listen_port": 17531}
///
/// # Safety
/// `cfg_json` must be a valid NUL-terminated UTF-8 C string; `listener` must
/// remain valid for the handle's lifetime and may be called from background
/// threads.
#[no_mangle]
pub unsafe extern "C" fn bc_init(
    cfg_json: *const c_char,
    // v0.5.27: the push callback is ACCEPTED BUT IGNORED — events are pulled
    // via sys.drain_events instead (the callback never fired on Android)
    _listener: extern "C" fn(*mut c_void, *const c_char, c_uint),
    _ctx: *mut c_void,
) -> i64 {
    static PANIC_HOOK: OnceLock<()> = OnceLock::new();
    PANIC_HOOK.get_or_init(|| {
        std::panic::set_hook(Box::new(|info| {
            let msg = format!("bitte panic: {info}");
            log::error!("{msg}");
            write_crash_dump(&msg);
        }));
    });

    let cfg_str = cstr_to_str(cfg_json).to_string();
    let cfg: Json = serde_json::from_str(&cfg_str).unwrap_or_else(|_| json!({}));
    let data_dir = cfg
        .get("data_dir")
        .and_then(|d| d.as_str())
        .unwrap_or("./bitte-data")
        .to_string();
    let _ = CRASH_DIR.set(std::path::PathBuf::from(&data_dir).join("logs"));
    // pre-open the crash-log fd + install the native signal handlers
    #[cfg(unix)]
    {
        let dir = std::path::Path::new(&data_dir).join("logs");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("crash_rust.log");
        if let Ok(cs) = std::ffi::CString::new(path.to_string_lossy().as_ref()) {
            let fd = libc::open(
                cs.as_ptr(),
                libc::O_APPEND | libc::O_CREAT | libc::O_WRONLY,
                0o644,
            );
            CRASH_FD.store(fd, std::sync::atomic::Ordering::Relaxed);
            for sig in CRASH_SIGNALS {
                let old =
                    libc::signal(sig, native_crash_handler as *const () as libc::sighandler_t);
                if (sig as usize) < OLD_HANDLERS.len() {
                    OLD_HANDLERS[sig as usize]
                        .store(old as isize, std::sync::atomic::Ordering::Relaxed);
                }
            }
        }
    }
    init_logging(&data_dir);
    log::info!("bc_init: bitte {} data_dir={data_dir}", bitte_core::VERSION);

    let engine_cfg = json!({
        "listen_port": cfg.get("listen_port").and_then(|p| p.as_i64()).unwrap_or(17531),
        "data_dir": data_dir,
        "user_agent": format!("BitteChat/{}", bitte_core::VERSION),
        "up_limit": cfg.get("up_limit").and_then(|p| p.as_i64()).unwrap_or(0),
        "down_limit": cfg.get("down_limit").and_then(|p| p.as_i64()).unwrap_or(0),
        "resume_dir": format!("{data_dir}/resume"),
    });

    let (engine, engine_rx) = match create_engine(engine_cfg) {
        Ok(v) => v,
        Err(e) => {
            log::error!("engine init failed: {e}");
            return -2;
        }
    };

    let (api, events) = match Api::new(
        std::path::PathBuf::from(&data_dir),
        engine.clone(),
        engine_rx,
    ) {
        Ok(v) => v,
        Err(e) => {
            log::error!("api init failed: {e}");
            return -3;
        }
    };

    let handle = NEXT_HANDLE.fetch_add(1, Ordering::SeqCst);
    with_registry(|map| {
        map.insert(
            handle,
            HandleEntry {
                api,
                _engine: engine,
                events,
            },
        )
    });
    handle
}

/// Invoke a JSON method. Returns a malloc'd JSON string (free with `bc_free`):
/// `{"ok":true, ...}` or `{"ok":false,"error":"..."}`.
///
/// # Safety
/// `method`/`params_json` must be valid NUL-terminated UTF-8 C strings.
#[no_mangle]
pub unsafe extern "C" fn bc_call(
    handle: i64,
    method: *const c_char,
    params_json: *const c_char,
) -> *mut c_char {
    let method = cstr_to_str(method).to_string();
    let method_for_log = method.clone();
    let params_str = cstr_to_str(params_json).to_string();
    let result = std::panic::catch_unwind(AssertUnwindSafe(move || {
        let params: Json = if params_str.trim().is_empty() {
            json!({})
        } else {
            match serde_json::from_str(&params_str) {
                Ok(v) => v,
                Err(e) => return json_error(&format!("bad params json: {e}")),
            }
        };
        with_registry(|map| match map.get(&handle) {
            Some(entry) => {
                // v0.5.27: pull channel for UI events (replaces the push
                // callback that never delivered on Android)
                if method == "sys.drain_events" {
                    let evs: Vec<String> = entry.events.try_iter().collect();
                    return json!({"ok": true, "events": evs}).to_string();
                }
                match entry.api.dispatch(&method, params) {
                    Ok(mut v) => {
                        if let Some(o) = v.as_object_mut() {
                            o.insert("ok".to_string(), json!(true));
                        }
                        v.to_string()
                    }
                    Err(e) => json_error(&e.to_string()),
                }
            }
            None => json_error("invalid handle"),
        })
    }));
    match result {
        Ok(s) => {
            if s.contains("\"ok\":false") {
                log::warn!("bc_call {method_for_log} failed: {s}");
            }
            to_c_string(s)
        }
        Err(_) => {
            log::error!("bc_call {method_for_log} PANICKED");
            to_c_string(json_error("internal panic"))
        }
    }
}

/// # Safety
/// Pointer must come from `bc_call`.
#[no_mangle]
pub unsafe extern "C" fn bc_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// Shut down a handle: stops threads, destroys the engine.
///
/// # Safety
/// `handle` must be a valid handle from `bc_init` and no other calls may be
/// in flight for it.
#[no_mangle]
pub unsafe extern "C" fn bc_shutdown(handle: i64) {
    if let Some(entry) = with_registry(|map| {
        map.get(&handle).map(|e| {
            (
                Api {
                    inner: e.api.inner.clone(),
                },
                e._engine.clone(),
            )
        })
    }) {
        *entry.0.inner.shutdown.write().unwrap() = true;
        // snapshot resume data (verified pieces + metadata) so the next start
        // does not re-check/re-fetch; give the alert thread a moment to write
        log::info!("bc_shutdown: saving resume data");
        let _ = entry.1.save_all_resume();
        std::thread::sleep(std::time::Duration::from_millis(700));
    }
    let entry = with_registry(|map| map.remove(&handle));
    drop(entry);
}

/// Static version string (do not free).
#[no_mangle]
pub extern "C" fn bc_version() -> *const c_char {
    static VERSION_C: OnceLock<CString> = OnceLock::new();
    let v = VERSION_C.get_or_init(|| {
        let lt = {
            #[cfg(feature = "native-bt")]
            {
                bitte_bt::LtSession::libtorrent_version()
            }
            #[cfg(not(feature = "native-bt"))]
            {
                "mock".to_string()
            }
        };
        CString::new(format!("{} engine:{}", bitte_core::VERSION, lt)).unwrap()
    });
    v.as_ptr()
}
