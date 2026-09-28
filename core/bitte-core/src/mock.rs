//! In-memory mock BT engine with a shared bus, enabling full end-to-end tests
//! of the chat protocol (groups, DHT items, extension messages, sync) without
//! libtorrent. Multiple engines attached to the same [`MockBus`] behave like
//! peers in one network.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};

use crate::bencode::{self, Value};
use crate::crypto::{self, bep44_verify, Sha1Hash};
use crate::engine::*;
use crate::{CoreError, Result};

#[derive(Default)]
#[allow(clippy::type_complexity)]
struct BusState {
    immutables: HashMap<Sha1Hash, Vec<u8>>,
    /// (pk, salt) -> (seq, sig, value)
    mutables: HashMap<([u8; 32], String), (i64, [u8; 64], Vec<u8>)>,
    torrents: HashMap<String, MockTorrent>,
    /// infohash hex -> member engine ids
    swarms: HashMap<String, HashSet<usize>>,
    /// engines waiting for a torrent that is not published yet
    waiters: HashMap<String, Vec<(usize, PathBuf)>>,
    /// infohash hex -> announced trackers (url, tier); shared view like the
    /// real network's tracker responses
    trackers: HashMap<String, Vec<(String, i32)>>,
    txs: HashMap<usize, Sender<EngineEvent>>,
    next_id: usize,
}

#[derive(Clone)]
struct MockTorrent {
    #[allow(dead_code)]
    name: String,
    files: BTreeMap<String, Vec<u8>>,
    total: i64,
}

#[derive(Clone, Default)]
pub struct MockBus {
    state: Arc<Mutex<BusState>>,
}

impl MockBus {
    pub fn new() -> MockBus {
        MockBus::default()
    }

    /// Number of stored immutable items (test helper).
    pub fn immutable_count(&self) -> usize {
        self.state.lock().unwrap().immutables.len()
    }

    pub fn mutable_seq(&self, pk: &[u8; 32], salt: &str) -> Option<i64> {
        self.state
            .lock()
            .unwrap()
            .mutables
            .get(&(*pk, salt.to_string()))
            .map(|(s, _, _)| *s)
    }

    /// Test helper: flip a byte inside a stored immutable item (simulates a
    /// malicious/corrupted DHT replica).
    pub fn corrupt_immutable(&self, target: &[u8]) {
        let mut st = self.state.lock().unwrap();
        if target.len() == 20 {
            let mut h = [0u8; 20];
            h.copy_from_slice(target);
            if let Some(v) = st.immutables.get_mut(&h) {
                if !v.is_empty() {
                    let i = v.len() / 2;
                    v[i] ^= 0xFF;
                }
            }
        }
    }

    /// Test helper: raw immutable item bytes (to assert sealing).
    pub fn immutable(&self, target: &[u8; 20]) -> Option<Vec<u8>> {
        self.state.lock().unwrap().immutables.get(target).cloned()
    }

    pub fn swarm_size(&self, ih_hex: &str) -> usize {
        self.state
            .lock()
            .unwrap()
            .swarms
            .get(ih_hex)
            .map(|s| s.len())
            .unwrap_or(0)
    }
}

struct MyTorrent {
    name: String,
    save_dir: PathBuf,
    total: i64,
    paused: bool,
    finished: bool,
}

pub struct MockEngine {
    id: usize,
    bus: MockBus,
    tx: Sender<EngineEvent>,
    mine: Mutex<HashMap<String, MyTorrent>>,
}

impl MockEngine {
    /// Create an engine attached to `bus`; returns the engine and the receiver
    /// of its event stream.
    pub fn new(bus: MockBus) -> (MockEngine, Receiver<EngineEvent>) {
        let (tx, rx) = channel();
        let id = {
            let mut st = bus.state.lock().unwrap();
            let id = st.next_id;
            st.next_id += 1;
            st.txs.insert(id, tx.clone());
            id
        };
        (
            MockEngine {
                id,
                bus,
                tx,
                mine: Mutex::new(HashMap::new()),
            },
            rx,
        )
    }

    pub fn id(&self) -> usize {
        self.id
    }

    fn post(&self, ev: EngineEvent) {
        let _ = self.tx.send(ev);
    }

    fn post_to(state: &BusState, engine: usize, ev: EngineEvent) {
        if let Some(tx) = state.txs.get(&engine) {
            let _ = tx.send(ev);
        }
    }

    fn join_swarm(state: &mut BusState, ih: &str, id: usize) {
        state.swarms.entry(ih.to_string()).or_default().insert(id);
    }

    fn materialize(
        state: &BusState,
        ih: &str,
        save_dir: &Path,
        ev_tx: &Sender<EngineEvent>,
    ) -> Result<()> {
        let t = state
            .torrents
            .get(ih)
            .ok_or_else(|| CoreError::NotFound(format!("torrent {ih}")))?
            .clone();
        std::fs::create_dir_all(save_dir)?;
        for (rel, data) in &t.files {
            let p = save_dir.join(rel);
            if let Some(parent) = p.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(p, data)?;
        }
        let _ = ev_tx.send(EngineEvent::MetadataReceived {
            infohash: ih.to_string(),
        });
        let _ = ev_tx.send(EngineEvent::TorrentFinished {
            infohash: ih.to_string(),
        });
        Ok(())
    }
}

impl Drop for MockEngine {
    fn drop(&mut self) {
        let mut st = self.bus.state.lock().unwrap();
        st.txs.remove(&self.id);
        for members in st.swarms.values_mut() {
            members.remove(&self.id);
        }
        st.waiters.retain(|_, v| {
            v.retain(|(id, _)| *id != self.id);
            !v.is_empty()
        });
    }
}

/// Minimal magnet parser: extracts the v1 infohash (hex or base32) and dn.
pub fn parse_magnet(magnet: &str) -> Result<(String, Option<String>)> {
    if !magnet.starts_with("magnet:?") {
        return Err(CoreError::Invalid("not a magnet link".into()));
    }
    let mut xt: Option<String> = None;
    let mut dn: Option<String> = None;
    for part in magnet["magnet:?".len()..].split('&') {
        if let Some(v) = part.strip_prefix("xt=urn:btih:") {
            xt = Some(v.to_string());
        } else if let Some(v) = part.strip_prefix("dn=") {
            dn = Some(urldecode(v).replace('+', " ").trim().to_string());
        }
    }
    let xt = xt.ok_or_else(|| CoreError::Invalid("magnet without btih".into()))?;
    let ih = if xt.len() == 40 && xt.chars().all(|c| c.is_ascii_hexdigit()) {
        xt.to_lowercase()
    } else if xt.len() == 32 {
        let bytes = base32_decode(&xt.to_ascii_uppercase())
            .ok_or_else(|| CoreError::Invalid("bad base32 infohash".into()))?;
        hex::encode(bytes)
    } else {
        return Err(CoreError::Invalid("unsupported infohash encoding".into()));
    };
    Ok((ih, dn))
}

fn urldecode(s: &str) -> String {
    let mut out = String::new();
    let mut chars = s.bytes();
    while let Some(b) = chars.next() {
        if b == b'%' {
            let h = chars.next().unwrap_or(b'0');
            let l = chars.next().unwrap_or(b'0');
            let hexval = |c: u8| -> u8 {
                match c {
                    b'0'..=b'9' => c - b'0',
                    b'a'..=b'f' => c - b'a' + 10,
                    b'A'..=b'F' => c - b'A' + 10,
                    _ => 0,
                }
            };
            out.push((hexval(h) * 16 + hexval(l)) as char);
        } else {
            out.push(b as char);
        }
    }
    out
}

fn base32_decode(s: &str) -> Option<Vec<u8>> {
    let alpha = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    let mut bits = 0u32;
    let mut nbits = 0u32;
    let mut out = Vec::new();
    for c in s.bytes() {
        let v = alpha.iter().position(|&a| a == c)? as u32;
        bits = (bits << 5) | v;
        nbits += 5;
        if nbits >= 8 {
            nbits -= 8;
            out.push(((bits >> nbits) & 0xFF) as u8);
        }
    }
    Some(out)
}

/// Normalize user input into `(infohash_hex_lowercase, dn, magnet)`.
///
/// Accepts, in addition to full magnet links:
///   * a bare 40-char hex infohash (any case, whitespace tolerated)
///   * a bare 32-char base32 infohash
///   * `btih:` / `urn:btih:` prefixed hashes
///
/// Bare hashes are expanded into a canonical `magnet:?xt=urn:btih:<hex>`.
pub fn normalize_torrent_input(input: &str) -> Result<(String, Option<String>, String)> {
    let s = input.trim();
    if s.is_empty() {
        return Err(CoreError::Invalid("empty input".into()));
    }
    if s.starts_with("magnet:?") {
        let compact: String = s.chars().filter(|c| !c.is_whitespace()).collect();
        let (ih, dn) = parse_magnet(&compact)?;
        return Ok((ih, dn, compact));
    }
    let bare: String = s.chars().filter(|c| !c.is_whitespace()).collect();
    let b = bare
        .strip_prefix("urn:btih:")
        .or_else(|| bare.strip_prefix("btih:"))
        .unwrap_or(&bare);
    let ih = if b.len() == 40 && b.chars().all(|c| c.is_ascii_hexdigit()) {
        b.to_lowercase()
    } else if b.len() == 32
        && b.chars()
            .all(|c| "abcdefghijklmnopqrstuvwxyz234567".contains(c.to_ascii_lowercase()))
    {
        let bytes = base32_decode(&b.to_ascii_uppercase())
            .ok_or_else(|| CoreError::Invalid("bad base32 infohash".into()))?;
        if bytes.len() != 20 {
            return Err(CoreError::Invalid("bad base32 infohash".into()));
        }
        hex::encode(bytes)
    } else {
        return Err(CoreError::Invalid(
            "not a magnet link or infohash (expected magnet:?, 40 hex or 32 base32 chars)".into(),
        ));
    };
    let magnet = format!("magnet:?xt=urn:btih:{ih}");
    Ok((ih, None, magnet))
}

/// Validate a tracker announce URL (http/https/udp, no whitespace).
pub fn valid_tracker_url(url: &str) -> bool {
    let u = url.trim();
    if u.is_empty() || u.len() > 512 || u.chars().any(|c| c.is_whitespace()) {
        return false;
    }
    let l = u.to_ascii_lowercase();
    l.starts_with("http://") || l.starts_with("https://") || l.starts_with("udp://")
}

impl BtEngine for MockEngine {
    fn name(&self) -> &'static str {
        "mock"
    }

    fn add_magnet(&self, magnet: &str, save_dir: &str, name_hint: Option<&str>) -> Result<String> {
        let (ih, dn) = parse_magnet(magnet)?;
        let name = dn.unwrap_or_else(|| ih.clone());
        let _ = name_hint;
        let save = PathBuf::from(save_dir);
        let mut st = self.bus.state.lock().unwrap();
        Self::join_swarm(&mut st, &ih, self.id);
        if st.torrents.contains_key(&ih) {
            let total = st.torrents[&ih].total;
            Self::materialize(&st, &ih, &save, &self.tx)?;
            drop(st);
            self.mine.lock().unwrap().insert(
                ih.clone(),
                MyTorrent {
                    name,
                    save_dir: save,
                    total,
                    paused: false,
                    finished: true,
                },
            );
            self.post_status(&ih);
        } else {
            st.waiters
                .entry(ih.clone())
                .or_default()
                .push((self.id, save.clone()));
            drop(st);
            self.mine.lock().unwrap().insert(
                ih.clone(),
                MyTorrent {
                    name,
                    save_dir: save,
                    total: 0,
                    paused: false,
                    finished: false,
                },
            );
            self.post_status(&ih);
        }
        Ok(ih)
    }

    fn add_torrent_bytes(&self, bytes: &[u8], save_dir: &str) -> Result<String> {
        // mock torrent file format: d4:mocki1e4:name...5:files d...e8:infohash40:hex e
        let v = bencode::decode(bytes)?;
        if v.get_int("mock").unwrap_or(0) != 1 {
            return Err(CoreError::Invalid("not a mock torrent".into()));
        }
        let ih = v
            .get_str("infohash")
            .ok_or_else(|| CoreError::Invalid("mock torrent missing infohash".into()))?
            .to_string();
        let name = v.get_str("name").unwrap_or(&ih).to_string();
        let mut files = BTreeMap::new();
        let mut total = 0i64;
        if let Some(Value::Dict(d)) = v.get("files") {
            for (k, val) in d {
                if let Value::Str(data) = val {
                    total += data.len() as i64;
                    files.insert(String::from_utf8_lossy(k).to_string(), data.clone());
                }
            }
        }
        let mt = MockTorrent {
            name: name.clone(),
            files,
            total,
        };
        let save = PathBuf::from(save_dir);
        {
            let mut st = self.bus.state.lock().unwrap();
            st.torrents.insert(ih.clone(), mt);
            Self::join_swarm(&mut st, &ih, self.id);
            // seed to everyone waiting
            if let Some(waiters) = st.waiters.remove(&ih) {
                for (wid, wdir) in waiters {
                    let Some(tx) = st.txs.get(&wid).cloned() else {
                        continue;
                    };
                    if let Err(e) = Self::materialize(&st, &ih, &wdir, &tx) {
                        log::warn!("mock seed to waiter failed: {e}");
                    }
                }
            }
        }
        self.mine.lock().unwrap().insert(
            ih.clone(),
            MyTorrent {
                name,
                save_dir: save,
                total,
                paused: false,
                finished: true,
            },
        );
        self.post_status(&ih);
        Ok(ih)
    }

    fn remove_torrent(&self, infohash: &str, delete_files: bool) -> Result<()> {
        let removed = self.mine.lock().unwrap().remove(infohash);
        if let Some(t) = removed {
            if delete_files {
                let _ = std::fs::remove_dir_all(&t.save_dir);
            }
        }
        let mut st = self.bus.state.lock().unwrap();
        if let Some(members) = st.swarms.get_mut(infohash) {
            members.remove(&self.id);
        }
        drop(st);
        self.post(EngineEvent::TorrentRemoved {
            infohash: infohash.to_string(),
        });
        Ok(())
    }

    fn set_paused(&self, infohash: &str, paused: bool) -> Result<()> {
        let mut mine = self.mine.lock().unwrap();
        let t = mine
            .get_mut(infohash)
            .ok_or_else(|| CoreError::NotFound(infohash.into()))?;
        t.paused = paused;
        drop(mine);
        self.post_status(infohash);
        Ok(())
    }

    fn torrent_states(&self) -> Result<Vec<TorrentState>> {
        let mine = self.mine.lock().unwrap();
        let st = self.bus.state.lock().unwrap();
        let mut out = Vec::new();
        for (ih, t) in mine.iter() {
            let seeds = st.swarms.get(ih).map(|m| m.len() as i32).unwrap_or(0);
            out.push(TorrentState {
                infohash: ih.clone(),
                name: t.name.clone(),
                save_path: t.save_dir.to_string_lossy().to_string(),
                total_bytes: t.total,
                progress: if t.finished { 1.0 } else { 0.0 },
                download_rate: 0,
                upload_rate: 0,
                num_peers: seeds.saturating_sub(1),
                num_seeds: seeds,
                paused: t.paused,
                finished: t.finished,
                error: String::new(),
                state: if t.finished {
                    "seeding".into()
                } else {
                    "downloading".into()
                },
            });
        }
        Ok(out)
    }

    fn torrent_peers(&self, infohash: &str) -> Result<Vec<PeerInfo>> {
        let st = self.bus.state.lock().unwrap();
        let mut out = Vec::new();
        if let Some(members) = st.swarms.get(infohash) {
            for m in members {
                if *m == self.id {
                    continue;
                }
                out.push(PeerInfo {
                    ip: format!("10.0.0.{}", m + 1),
                    port: 6881,
                    client: format!("MockEngine/{}", m),
                    progress: 1.0,
                    up_speed: 0,
                    down_speed: 0,
                    flags: "D".into(),
                    chat_capable: true,
                });
            }
        }
        Ok(out)
    }

    fn set_file_priorities(&self, _infohash: &str, _priorities: Vec<i8>) -> Result<()> {
        Ok(())
    }

    fn file_list(&self, infohash: &str) -> Result<Vec<FileEntry>> {
        let st = self.bus.state.lock().unwrap();
        let t = st
            .torrents
            .get(infohash)
            .ok_or_else(|| CoreError::NotFound(infohash.into()))?;
        Ok(t.files
            .iter()
            .enumerate()
            .map(|(i, (p, d))| FileEntry {
                index: i,
                path: p.clone(),
                size: d.len() as i64,
                priority: 4,
                progress: 1.0,
            })
            .collect())
    }

    fn create_torrent(&self, path: &str, _comment: &str) -> Result<CreatedTorrent> {
        let p = Path::new(path);
        let mut files = BTreeMap::new();
        if p.is_dir() {
            for entry in walkdir_shim(p, p)? {
                files.insert(entry.0, entry.1);
            }
        } else {
            let name = p
                .file_name()
                .map(|s| s.to_string_lossy().to_string())
                .ok_or_else(|| CoreError::Invalid("bad path".into()))?;
            files.insert(name, std::fs::read(p)?);
        }
        // deterministic infohash: sha1 over sorted (path, sha1(content))
        let mut hv = Value::dict();
        let mut files_v = Value::dict();
        for (name, data) in &files {
            hv.insert(name.as_bytes(), Value::Str(crypto::sha1(data).to_vec()));
            files_v.insert(name.as_bytes(), Value::Str(data.clone()));
        }
        let ih = crypto::sha1(&bencode::encode(&hv));
        let ih_hex = hex::encode(ih);
        let display_name = files.keys().next().cloned().unwrap_or(ih_hex.clone());
        let mut td = Value::dict();
        td.insert("mock", Value::Int(1));
        td.insert("infohash", Value::Str(ih_hex.as_bytes().to_vec()));
        td.insert("name", Value::Str(display_name.as_bytes().to_vec()));
        td.insert("files", files_v);
        let torrent_bytes = bencode::encode(&td);
        let magnet = format!(
            "magnet:?xt=urn:btih:{ih_hex}&dn={}",
            urlquery(&display_name)
        );
        Ok(CreatedTorrent {
            infohash: ih,
            torrent_bytes,
            magnet,
        })
    }

    fn dht_get_immutable(&self, target: &Sha1Hash) -> Result<()> {
        let st = self.bus.state.lock().unwrap();
        match st.immutables.get(target) {
            Some(v) => self.post(EngineEvent::DhtImmutableItem {
                target: *target,
                found: true,
                value: v.clone(),
            }),
            None => self.post(EngineEvent::DhtImmutableItem {
                target: *target,
                found: false,
                value: vec![],
            }),
        }
        Ok(())
    }

    fn dht_put_immutable(&self, value: &[u8], expected_target: &Sha1Hash) -> Result<()> {
        let t = crypto::sha1(value);
        if &t != expected_target {
            return Err(CoreError::Engine("immutable target mismatch".into()));
        }
        {
            let mut st = self.bus.state.lock().unwrap();
            st.immutables.insert(t, value.to_vec());
        }
        self.post(EngineEvent::DhtPutDone {
            mutable: false,
            key: hex::encode(t),
            num_success: 8,
        });
        Ok(())
    }

    fn dht_get_mutable(&self, pk: &[u8; 32], salt: &str) -> Result<()> {
        let st = self.bus.state.lock().unwrap();
        match st.mutables.get(&(*pk, salt.to_string())) {
            Some((seq, sig, value)) => self.post(EngineEvent::DhtMutableItem {
                pk: *pk,
                salt: salt.to_string(),
                seq: *seq,
                sig: *sig,
                value: value.clone(),
                found: true,
                authoritative: true,
            }),
            None => self.post(EngineEvent::DhtMutableItem {
                pk: *pk,
                salt: salt.to_string(),
                seq: -1,
                sig: [0u8; 64],
                value: vec![],
                found: false,
                authoritative: true,
            }),
        }
        Ok(())
    }

    fn dht_put_mutable(
        &self,
        pk: &[u8; 32],
        salt: &str,
        seq: i64,
        sig: &[u8; 64],
        value: &[u8],
    ) -> Result<()> {
        if !bep44_verify(pk, seq, value, salt.as_bytes(), sig) {
            return Err(CoreError::Engine("bad BEP44 signature".into()));
        }
        {
            let mut st = self.bus.state.lock().unwrap();
            let cur = st
                .mutables
                .get(&(*pk, salt.to_string()))
                .map(|(s, _, _)| *s);
            if let Some(cur) = cur {
                if seq <= cur {
                    self.post(EngineEvent::DhtPutDone {
                        mutable: true,
                        key: hex::encode(pk),
                        num_success: 0,
                    });
                    return Ok(());
                }
            }
            st.mutables
                .insert((*pk, salt.to_string()), (seq, *sig, value.to_vec()));
        }
        self.post(EngineEvent::DhtPutDone {
            mutable: true,
            key: hex::encode(pk),
            num_success: 8,
        });
        Ok(())
    }

    fn ext_send(&self, infohash: &str, payload: &[u8]) -> Result<u32> {
        let st = self.bus.state.lock().unwrap();
        let mut n = 0;
        if let Some(members) = st.swarms.get(infohash) {
            for m in members {
                if *m == self.id {
                    continue;
                }
                Self::post_to(
                    &st,
                    *m,
                    EngineEvent::ExtMessage {
                        infohash: infohash.to_string(),
                        peer: format!("10.0.0.{}:6881", self.id + 1),
                        payload: payload.to_vec(),
                    },
                );
                n += 1;
            }
        }
        Ok(n)
    }

    fn add_tracker(&self, infohash: &str, url: &str, tier: i32) -> Result<()> {
        if !self.mine.lock().unwrap().contains_key(infohash) {
            return Err(CoreError::NotFound(infohash.into()));
        }
        let mut st = self.bus.state.lock().unwrap();
        let v = st.trackers.entry(infohash.to_string()).or_default();
        if !v.iter().any(|(u, _)| u == url) {
            v.push((url.to_string(), tier));
        }
        Ok(())
    }

    fn remove_tracker(&self, infohash: &str, url: &str) -> Result<()> {
        if !self.mine.lock().unwrap().contains_key(infohash) {
            return Err(CoreError::NotFound(infohash.into()));
        }
        let mut st = self.bus.state.lock().unwrap();
        if let Some(v) = st.trackers.get_mut(infohash) {
            v.retain(|(u, _)| u != url);
        }
        Ok(())
    }

    fn trackers(&self, infohash: &str) -> Result<Vec<TrackerInfo>> {
        if !self.mine.lock().unwrap().contains_key(infohash) {
            return Err(CoreError::NotFound(infohash.into()));
        }
        let st = self.bus.state.lock().unwrap();
        Ok(st
            .trackers
            .get(infohash)
            .map(|v| {
                v.iter()
                    .map(|(u, t)| TrackerInfo {
                        url: u.clone(),
                        tier: *t,
                        verified: false,
                        fails: 0,
                        message: String::new(),
                    })
                    .collect()
            })
            .unwrap_or_default())
    }

    fn set_limits(&self, _upload: i64, _download: i64) -> Result<()> {
        Ok(())
    }

    fn session_stats(&self) -> Result<SessionStats> {
        // lock order: mine -> bus (same as torrent_states) to avoid deadlock
        let num_torrents = self.mine.lock().unwrap().len() as i64;
        let st = self.bus.state.lock().unwrap();
        Ok(SessionStats {
            dht_nodes: (st.immutables.len() + st.mutables.len()) as i64,
            upload_rate: 0,
            download_rate: 0,
            num_torrents,
            has_incoming: false,
        })
    }
}

fn urlquery(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn walkdir_shim(root: &Path, dir: &Path) -> Result<Vec<(String, Vec<u8>)>> {
    let mut out = Vec::new();
    for e in std::fs::read_dir(dir)? {
        let e = e?;
        let p = e.path();
        if p.is_dir() {
            out.extend(walkdir_shim(root, &p)?);
        } else {
            let rel = p
                .strip_prefix(root)
                .map_err(|_| CoreError::Internal("path escape".into()))?
                .to_string_lossy()
                .replace('\\', "/");
            out.push((rel, std::fs::read(&p)?));
        }
    }
    Ok(out)
}

impl MockEngine {
    fn post_status(&self, ih: &str) {
        if let Ok(states) = self.torrent_states() {
            if let Some(s) = states.into_iter().find(|s| s.infohash == ih) {
                self.post(EngineEvent::TorrentUpdate { state: s });
            }
        }
    }
}

#[cfg(test)]
mod normalize_tests {
    use super::*;

    #[test]
    fn normalize_full_magnet_passthrough() {
        let m = "magnet:?xt=urn:btih:AABBCCDDEEFF00112233445566778899AABBCCDD&dn=My%20File&tr=udp%3A%2F%2Fx.org%3A1337";
        let (ih, dn, mag) = normalize_torrent_input(m).unwrap();
        assert_eq!(ih, "aabbccddeeff00112233445566778899aabbccdd");
        assert_eq!(dn.as_deref(), Some("My File"));
        assert_eq!(mag, m);
    }

    #[test]
    fn normalize_bare_hex_hash() {
        let (ih, dn, mag) =
            normalize_torrent_input("  AABBCCDDEEFF00112233445566778899AABBCCDD ").unwrap();
        assert_eq!(ih, "aabbccddeeff00112233445566778899aabbccdd");
        assert!(dn.is_none());
        assert_eq!(
            mag,
            "magnet:?xt=urn:btih:aabbccddeeff00112233445566778899aabbccdd"
        );
    }

    #[test]
    fn normalize_base32_and_prefixed() {
        // base32 of 20 zero bytes = 32 'A's
        let (ih, _, _) = normalize_torrent_input("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA").unwrap();
        assert_eq!(ih, "0".repeat(40));
        let (ih2, _, _) =
            normalize_torrent_input("btih:aabbccddeeff00112233445566778899aabbccdd").unwrap();
        assert_eq!(ih2, "aabbccddeeff00112233445566778899aabbccdd");
        let (ih3, _, _) =
            normalize_torrent_input("urn:btih:AABBCCDDEEFF00112233445566778899AABBCCDD").unwrap();
        assert_eq!(ih3, ih2);
    }

    #[test]
    fn normalize_rejects_junk() {
        for bad in [
            "",
            "hello world",
            "aabbccddeeff00112233445566778899aabbccd", // 39 hex
            "http://example.com/file.torrent",
            "magnet:?xt=urn:btmh:1220aabb",
        ] {
            assert!(
                normalize_torrent_input(bad).is_err(),
                "should reject {bad:?}"
            );
        }
    }

    #[test]
    fn tracker_url_validation() {
        assert!(valid_tracker_url(
            "udp://tracker.opentrackr.org:1337/announce"
        ));
        assert!(valid_tracker_url("https://t.example/announce"));
        assert!(!valid_tracker_url("ftp://x/announce"));
        assert!(!valid_tracker_url("udp://x y/announce"));
        assert!(!valid_tracker_url(""));
    }
}
