//! `libbitte_core.so` — the C ABI consumed by the Flutter app through
//! dart:ffi. One global registry of API handles; commands cross the boundary
//! as JSON strings; events are pushed through a Dart-registered callback.

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
    _forwarder: std::thread::JoinHandle<()>,
}

struct Listener {
    cb: extern "C" fn(*mut c_void, *const c_char, c_uint),
    ctx: *mut c_void,
}

// SAFETY: the Dart side guarantees the callback+ctx stay valid for the
// lifetime of the isolate that registered them (single-isolate usage).
unsafe impl Send for Listener {}
unsafe impl Sync for Listener {}

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
    listener: extern "C" fn(*mut c_void, *const c_char, c_uint),
    ctx: *mut c_void,
) -> i64 {
    static PANIC_HOOK: OnceLock<()> = OnceLock::new();
    PANIC_HOOK.get_or_init(|| {
        std::panic::set_hook(Box::new(|info| {
            log::error!("bitte panic: {info}");
        }));
    });

    let cfg_str = cstr_to_str(cfg_json).to_string();
    let cfg: Json = serde_json::from_str(&cfg_str).unwrap_or_else(|_| json!({}));
    let data_dir = cfg
        .get("data_dir")
        .and_then(|d| d.as_str())
        .unwrap_or("./bitte-data")
        .to_string();
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

    // event forwarder: core channel -> Dart callback
    let listener = Arc::new(Listener { cb: listener, ctx });
    let listener2 = listener.clone();
    let forwarder = match std::thread::Builder::new()
        .name("bitte-events-out".into())
        .spawn(move || {
            while let Ok(s) = events.recv() {
                let l = &*listener2;
                (l.cb)(l.ctx, s.as_ptr() as *const c_char, s.len() as c_uint);
            }
        }) {
        Ok(f) => f,
        Err(_) => return -4,
    };

    let handle = NEXT_HANDLE.fetch_add(1, Ordering::SeqCst);
    with_registry(|map| {
        map.insert(
            handle,
            HandleEntry {
                api,
                _engine: engine,
                _forwarder: forwarder,
            },
        )
    });
    // keep the listener alive as long as the forwarder runs
    std::mem::forget(listener);
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
            Some(entry) => match entry.api.dispatch(&method, params) {
                Ok(mut v) => {
                    if let Some(o) = v.as_object_mut() {
                        o.insert("ok".to_string(), json!(true));
                    }
                    v.to_string()
                }
                Err(e) => json_error(&e.to_string()),
            },
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
