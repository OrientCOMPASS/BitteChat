//! BT engine abstraction. The core talks to *some* BitTorrent implementation
//! through this trait; production uses libtorrent (feature `native-bt`), tests
//! use the in-memory mock engine.

use serde::{Deserialize, Serialize};

use crate::crypto::Sha1Hash;
use crate::Result;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TorrentState {
    pub infohash: String,
    pub name: String,
    pub save_path: String,
    pub total_bytes: i64,
    pub progress: f32,
    pub download_rate: i64,
    pub upload_rate: i64,
    pub num_peers: i32,
    pub num_seeds: i32,
    pub paused: bool,
    pub finished: bool,
    pub error: String,
    pub state: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeerInfo {
    pub ip: String,
    pub port: u16,
    pub client: String,
    pub progress: f32,
    pub up_speed: i64,
    pub down_speed: i64,
    pub flags: String,
    /// whether the peer advertised our `bc_chat` extension
    pub chat_capable: bool,
}

/// A connected `bc_chat` peer: advertised identity pubkey (hex, may be empty
/// for pre-v0.5.2 clients) + socket endpoint.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ExtPeerInfo {
    pub pk: String,
    pub endpoint: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TrackerInfo {
    pub url: String,
    pub tier: i32,
    pub verified: bool,
    pub fails: i32,
    pub message: String,
}

#[derive(Debug, Clone)]
pub struct CreatedTorrent {
    pub infohash: Sha1Hash,
    pub torrent_bytes: Vec<u8>,
    pub magnet: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionStats {
    pub dht_nodes: i64,
    pub upload_rate: i64,
    pub download_rate: i64,
    pub num_torrents: i64,
    pub has_incoming: bool,
}

/// Events emitted by the engine (asynchronously) towards the core.
#[derive(Debug, Clone)]
pub enum EngineEvent {
    /// torrent metadata (name/files) became available
    MetadataReceived {
        infohash: String,
    },
    /// periodic/changed status snapshot for one torrent
    TorrentUpdate {
        state: TorrentState,
    },
    TorrentFinished {
        infohash: String,
    },
    TorrentError {
        infohash: String,
        error: String,
    },
    TorrentRemoved {
        infohash: String,
    },
    /// BEP44 immutable item lookup result
    DhtImmutableItem {
        target: Sha1Hash,
        found: bool,
        value: Vec<u8>,
    },
    /// BEP44 mutable item lookup result
    DhtMutableItem {
        pk: [u8; 32],
        salt: String,
        seq: i64,
        sig: [u8; 64],
        value: Vec<u8>,
        found: bool,
        authoritative: bool,
    },
    /// result of a put operation (immutable or mutable)
    DhtPutDone {
        mutable: bool,
        key: String, // target hex (immutable) or pk hex (mutable)
        num_success: i32,
    },
    /// a `bc_chat` extension message from a peer of a swarm; `pk` is the
    /// sender identity pubkey advertised in the ext handshake (may be empty)
    ExtMessage {
        infohash: String,
        peer: String,
        pk: String,
        payload: Vec<u8>,
    },
    /// a peer supporting bc_chat connected / disconnected
    ChatPeer {
        infohash: String,
        peer: String,
        pk: String,
        connected: bool,
    },
    SessionStats {
        stats: SessionStats,
    },
    Log {
        level: String,
        msg: String,
    },
}

/// Common BitTorrent backend operations needed by the core.
///
/// All methods must be safe to call from arbitrary threads. Results of
/// asynchronous operations (DHT gets/puts, downloads) arrive as
/// [`EngineEvent`]s on the channel returned by [`BtEngine::event_sender`]'s
/// receiver held by the core.
pub trait BtEngine: Send + Sync {
    fn name(&self) -> &'static str;

    fn add_magnet(&self, magnet: &str, save_dir: &str, name_hint: Option<&str>) -> Result<String>;
    fn add_torrent_bytes(&self, bytes: &[u8], save_dir: &str) -> Result<String>;
    fn remove_torrent(&self, infohash: &str, delete_files: bool) -> Result<()>;
    fn set_paused(&self, infohash: &str, paused: bool) -> Result<()>;
    fn torrent_states(&self) -> Result<Vec<TorrentState>>;
    fn torrent_peers(&self, infohash: &str) -> Result<Vec<PeerInfo>>;
    fn set_file_priorities(&self, infohash: &str, priorities: Vec<i8>) -> Result<()>;
    fn file_list(&self, infohash: &str) -> Result<Vec<FileEntry>>;

    /// Tracker management. `add_tracker` is idempotent per URL.
    fn add_tracker(&self, infohash: &str, url: &str, tier: i32) -> Result<()>;
    fn remove_tracker(&self, infohash: &str, url: &str) -> Result<()>;
    fn trackers(&self, infohash: &str) -> Result<Vec<TrackerInfo>>;

    /// Create a v1-only torrent for `path` (file or directory).
    fn create_torrent(&self, path: &str, comment: &str) -> Result<CreatedTorrent>;

    fn dht_get_immutable(&self, target: &Sha1Hash) -> Result<()>;
    fn dht_put_immutable(&self, value: &[u8], expected_target: &Sha1Hash) -> Result<()>;
    fn dht_get_mutable(&self, pk: &[u8; 32], salt: &str) -> Result<()>;
    /// seq/sig are precomputed by the core (BEP44 canonical signing in Rust).
    fn dht_put_mutable(
        &self,
        pk: &[u8; 32],
        salt: &str,
        seq: i64,
        sig: &[u8; 64],
        value: &[u8],
    ) -> Result<()>;

    /// Broadcast a bc_chat extension payload to all chat-capable peers of the
    /// swarm; returns the number of peers it was queued for.
    fn ext_send(&self, infohash: &str, payload: &[u8]) -> Result<u32>;

    /// Deliver a bc_chat payload to the single peer of the swarm that
    /// advertised identity pubkey `pk_hex` (DM transport). Returns 0 when
    /// that peer is not currently connected here.
    fn ext_send_to(&self, infohash: &str, pk_hex: &str, payload: &[u8]) -> Result<u32>;

    /// Connected chat-ready peers of the swarm with their advertised pubkeys.
    fn ext_peers(&self, infohash: &str) -> Result<Vec<ExtPeerInfo>>;

    /// Update the identity pubkey advertised in bc_chat handshakes
    /// (call on startup and on identity switch).
    fn set_chat_pk(&self, pk_hex: &str) -> Result<()>;

    /// Snapshot resume data (verified pieces + metadata) for every torrent so
    /// restarts do not re-check/re-fetch. Best effort.
    fn save_all_resume(&self) -> Result<()>;

    fn session_stats(&self) -> Result<SessionStats>;

    /// Rate limits in bytes/sec; 0 = unlimited.
    fn set_limits(&self, upload: i64, download: i64) -> Result<()>;
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileEntry {
    pub index: usize,
    pub path: String,
    pub size: i64,
    pub priority: i8,
    pub progress: f32,
}
