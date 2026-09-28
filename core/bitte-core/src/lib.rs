//! BitteChat core library.
//!
//! Pure-Rust application core: bencode codec, Ed25519/BEP44 crypto, the
//! hash-chained group-chat DAG, SQLite object store, RSS parsing and the JSON
//! bridge (`api`) used by the Flutter frontend over FFI.
//!
//! The actual BitTorrent transport is abstracted behind [`engine::BtEngine`]:
//!   * `engine::mock::MockEngine` — in-memory bus for tests (default builds)
//!   * `lt::LibtorrentEngine` — real libtorrent backend (feature `native-bt`,
//!     built via the `bitte-bt` crate for Android)

pub mod api;
pub mod bencode;
pub mod chat;
pub mod crypto;
pub mod engine;
pub mod filelog;
pub mod filter;
pub mod rss;
pub mod store;

#[cfg(feature = "native-bt")]
pub mod lt;

pub mod mock;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("storage error: {0}")]
    Store(#[from] rusqlite::Error),
    #[error("bt engine error: {0}")]
    Engine(String),
    #[error("invalid input: {0}")]
    Invalid(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("bencode error: {0}")]
    Bencode(#[from] bencode::BencodeError),
    #[error("internal error: {0}")]
    Internal(String),
}

pub type Result<T> = std::result::Result<T, CoreError>;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Unix time in milliseconds (system clock).
pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Protocol identifier used in extension handshakes (BEP10 `m` dict).
pub const EXT_NAME: &str = "bc_chat";
/// Salt prefix for the group head mutable DHT item (BEP44).
pub const HEAD_SALT_PREFIX: &str = "bc1:";
/// File name of the group manifest inside the manifest torrent.
pub const MANIFEST_FILE: &str = "bitte-group.benc";
