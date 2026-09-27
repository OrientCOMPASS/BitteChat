#![allow(clippy::type_complexity)]
//! Safe-ish Rust wrapper over the `bitte_torrent` C ABI.
//!
//! The C++ side is only linked when `BITTE_BT_PREFIX` was set at build time
//! (Android builds). Linking fails otherwise, so desktop builds must never
//! construct a [`LtSession`].

use std::ffi::{c_char, c_void, CStr, CString};
use std::os::raw::c_uint;
use std::sync::Mutex;

// ---- raw C ABI -------------------------------------------------------------

#[allow(non_camel_case_types)]
pub type bc_session = c_void;

/// Event callback signature expected by `bc_create`.
pub type EventCallback = extern "C" fn(ctx: *mut c_void, json: *const c_char, len: c_uint);

extern "C" {
    pub fn bc_create(
        cfg_json: *const c_char,
        cb: EventCallback,
        ctx: *mut c_void,
    ) -> *mut bc_session;
    pub fn bc_call(
        s: *mut bc_session,
        method: *const c_char,
        params_json: *const c_char,
    ) -> *mut c_char;
    pub fn bc_free_str(s: *mut c_char);
    pub fn bc_destroy(s: *mut bc_session);
    pub fn bc_libtorrent_version() -> *const c_char;
}

// ---- safe wrapper ----------------------------------------------------------

/// Thread-safe holder of the event sink used as the C callback context.
pub struct EventSink<F: Fn(&str) + Send + 'static> {
    pub f: Mutex<F>,
}

/// One libtorrent session. All methods are thread-safe (the C++ side
/// serializes through libtorrent's session and internal mutexes).
pub struct LtSession {
    handle: *mut bc_session,
    // keeps the boxed callback context alive for the session's lifetime
    _ctx: Box<EventSink<Box<dyn Fn(&str) + Send>>>,
}

// SAFETY: the C++ session object is internally synchronized and designed for
// cross-thread use (bc_call from any thread; events emitted from its alert
// thread through our callback which is itself synchronized).
unsafe impl Send for LtSession {}
unsafe impl Sync for LtSession {}

impl LtSession {
    /// Create a session. `cfg_json`: see `bc_create`. `on_event` receives JSON
    /// event documents from the alert thread.
    pub fn new<F>(cfg_json: &str, on_event: F) -> Option<LtSession>
    where
        F: Fn(&str) + Send + 'static,
    {
        let boxed: Box<EventSink<Box<dyn Fn(&str) + Send>>> = Box::new(EventSink {
            f: Mutex::new(Box::new(on_event)),
        });
        let ctx_ptr = Box::into_raw(boxed);
        // SAFETY: ctx_ptr validity is tied to this LtSession (leaked on purpose
        // until Drop, which reclaims it).
        let cfg = CString::new(cfg_json).ok()?;
        let handle = unsafe { bc_create(cfg.as_ptr(), trampoline, ctx_ptr as *mut c_void) };
        if handle.is_null() {
            // reclaim the context to avoid a leak
            unsafe { drop(Box::from_raw(ctx_ptr)) };
            return None;
        }
        // SAFETY: we just created it from ctx_ptr; reconstruct the Box to own it
        let owned = unsafe { Box::from_raw(ctx_ptr) };
        Some(LtSession {
            handle,
            _ctx: owned,
        })
    }

    /// Call a command; returns the raw JSON response string.
    pub fn call(&self, method: &str, params_json: &str) -> String {
        let m = match CString::new(method) {
            Ok(v) => v,
            Err(_) => return r#"{"ok":false,"error":"bad method"}"#.to_string(),
        };
        let p = match CString::new(params_json) {
            Ok(v) => v,
            Err(_) => return r#"{"ok":false,"error":"params contain NUL"}"#.to_string(),
        };
        // SAFETY: handle is valid for self's lifetime; result freed below.
        let out = unsafe { bc_call(self.handle, m.as_ptr(), p.as_ptr()) };
        if out.is_null() {
            return r#"{"ok":false,"error":"null response"}"#.to_string();
        }
        // SAFETY: bc_call returns a malloc'd NUL-terminated string
        let s = unsafe { CStr::from_ptr(out) }.to_string_lossy().to_string();
        unsafe { bc_free_str(out) };
        s
    }

    pub fn libtorrent_version() -> String {
        // SAFETY: static string from the library
        unsafe { CStr::from_ptr(bc_libtorrent_version()) }
            .to_string_lossy()
            .to_string()
    }
}

impl Drop for LtSession {
    fn drop(&mut self) {
        // SAFETY: destroys the session exactly once; the alert thread is
        // joined inside bc_destroy before the ctx callback could dangle.
        unsafe { bc_destroy(self.handle) };
        // NOTE: _ctx (the Box) drops after bc_destroy, so no events can arrive
        // into a freed sink.
    }
}

extern "C" fn trampoline(ctx: *mut c_void, json: *const c_char, len: c_uint) {
    if ctx.is_null() || json.is_null() {
        return;
    }
    // SAFETY: ctx is the leaked EventSink box owned by the LtSession; it stays
    // valid because bc_destroy joins the alert thread before the box drops.
    let sink = unsafe { &*(ctx as *const EventSink<Box<dyn Fn(&str) + Send>>) };
    let bytes = unsafe { std::slice::from_raw_parts(json as *const u8, len as usize) };
    let s = String::from_utf8_lossy(bytes);
    if let Ok(f) = sink.f.lock() {
        f(&s);
    }
}
