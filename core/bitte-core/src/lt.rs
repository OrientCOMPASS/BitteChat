//! libtorrent-backed [`crate::engine::BtEngine`] implementation (Android /
//! native builds; feature `native-bt`).

use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};

use serde_json::{json, Value as Json};

use crate::crypto::Sha1Hash;
use crate::engine::*;
use crate::{CoreError, Result};

pub struct LibtorrentEngine {
    session: Arc<bitte_bt::LtSession>,
}

struct Bridge {
    tx: Mutex<Sender<EngineEvent>>,
}

fn b64_encode(b: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.encode(b)
}

fn b64_decode(s: &str) -> Vec<u8> {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD
        .decode(s.as_bytes())
        .unwrap_or_default()
}

fn hex20(s: &str) -> Option<Sha1Hash> {
    let b = hex::decode(s).ok()?;
    if b.len() != 20 {
        return None;
    }
    let mut a = [0u8; 20];
    a.copy_from_slice(&b);
    Some(a)
}

fn hex32(s: &str) -> Option<[u8; 32]> {
    let b = hex::decode(s).ok()?;
    if b.len() != 32 {
        return None;
    }
    let mut a = [0u8; 32];
    a.copy_from_slice(&b);
    Some(a)
}

fn parse_event(v: &Json) -> Option<EngineEvent> {
    let ty = v.get("type")?.as_str()?;
    let d = v.get("data")?;
    match ty {
        "metadata" => Some(EngineEvent::MetadataReceived {
            infohash: d.get("infohash")?.as_str()?.to_string(),
        }),
        "finished" => Some(EngineEvent::TorrentFinished {
            infohash: d.get("infohash")?.as_str()?.to_string(),
        }),
        "torrent_error" => Some(EngineEvent::TorrentError {
            infohash: d.get("infohash")?.as_str().unwrap_or("").to_string(),
            error: d.get("error")?.as_str()?.to_string(),
        }),
        "removed" => Some(EngineEvent::TorrentRemoved {
            infohash: d.get("infohash")?.as_str()?.to_string(),
        }),
        "dht_immutable" => {
            let target = hex20(d.get("target_hex")?.as_str()?)?;
            Some(EngineEvent::DhtImmutableItem {
                target,
                found: d.get("found")?.as_bool()?,
                value: b64_decode(d.get("value_b64")?.as_str().unwrap_or("")),
            })
        }
        "dht_mutable" => {
            let pk = hex32(d.get("pk_hex")?.as_str()?)?;
            let sig_b = b64_decode(d.get("sig_b64")?.as_str()?);
            let mut sig = [0u8; 64];
            if sig_b.len() == 64 {
                sig.copy_from_slice(&sig_b);
            }
            Some(EngineEvent::DhtMutableItem {
                pk,
                salt: d.get("salt")?.as_str()?.to_string(),
                seq: d.get("seq")?.as_i64()?,
                sig,
                value: b64_decode(d.get("value_b64")?.as_str().unwrap_or("")),
                found: d.get("found")?.as_bool()?,
                authoritative: d
                    .get("authoritative")
                    .and_then(|a| a.as_bool())
                    .unwrap_or(false),
            })
        }
        "dht_put" => Some(EngineEvent::DhtPutDone {
            mutable: d.get("mutable")?.as_bool()?,
            key: d.get("key")?.as_str()?.to_string(),
            num_success: d.get("num_success")?.as_i64()? as i32,
        }),
        "ext_msg" => Some(EngineEvent::ExtMessage {
            infohash: d.get("infohash")?.as_str()?.to_string(),
            peer: d.get("peer")?.as_str()?.to_string(),
            payload: b64_decode(d.get("payload_b64")?.as_str()?),
        }),
        "chat_peer" => Some(EngineEvent::ChatPeer {
            infohash: d.get("infohash")?.as_str()?.to_string(),
            peer: d.get("peer")?.as_str()?.to_string(),
            connected: d.get("connected")?.as_bool()?,
        }),
        "log" => Some(EngineEvent::Log {
            level: d
                .get("level")
                .and_then(|l| l.as_str())
                .unwrap_or("info")
                .to_string(),
            msg: d
                .get("msg")
                .and_then(|l| l.as_str())
                .unwrap_or("")
                .to_string(),
        }),
        _ => None,
    }
}

impl LibtorrentEngine {
    pub fn new(cfg: Json) -> Result<(LibtorrentEngine, Receiver<EngineEvent>)> {
        let (tx, rx) = channel::<EngineEvent>();
        let bridge = Arc::new(Bridge { tx: Mutex::new(tx) });
        let bridge2 = bridge.clone();
        let session = bitte_bt::LtSession::new(&cfg.to_string(), move |json_str| {
            if let Ok(v) = serde_json::from_str::<Json>(json_str) {
                if let Some(ev) = parse_event(&v) {
                    if let Ok(tx) = bridge2.tx.lock() {
                        let _ = tx.send(ev);
                    }
                }
            }
        })
        .ok_or_else(|| CoreError::Engine("libtorrent session init failed".into()))?;
        Ok((
            LibtorrentEngine {
                session: Arc::new(session),
            },
            rx,
        ))
    }

    fn call(&self, method: &str, params: Json) -> Result<Json> {
        let resp = self.session.call(method, &params.to_string());
        let v: Json = serde_json::from_str(&resp)
            .map_err(|e| CoreError::Engine(format!("bad engine response: {e}")))?;
        if v.get("ok").and_then(|o| o.as_bool()) != Some(true) {
            return Err(CoreError::Engine(
                v.get("error")
                    .and_then(|e| e.as_str())
                    .unwrap_or("unknown engine error")
                    .to_string(),
            ));
        }
        Ok(v)
    }

    fn jstr(&self, v: &Json, key: &str) -> Result<String> {
        v.get(key)
            .and_then(|x| x.as_str())
            .map(String::from)
            .ok_or_else(|| CoreError::Engine(format!("engine response missing {key}")))
    }
}

fn parse_state(s: &Json) -> TorrentState {
    TorrentState {
        infohash: s["infohash"].as_str().unwrap_or("").to_string(),
        name: s["name"].as_str().unwrap_or("").to_string(),
        save_path: s["save_path"].as_str().unwrap_or("").to_string(),
        total_bytes: s["total_bytes"].as_i64().unwrap_or(0),
        progress: s["progress"].as_f64().unwrap_or(0.0) as f32,
        download_rate: s["download_rate"].as_i64().unwrap_or(0),
        upload_rate: s["upload_rate"].as_i64().unwrap_or(0),
        num_peers: s["num_peers"].as_i64().unwrap_or(0) as i32,
        num_seeds: s["num_seeds"].as_i64().unwrap_or(0) as i32,
        paused: s["paused"].as_bool().unwrap_or(false),
        finished: s["finished"].as_bool().unwrap_or(false),
        error: s["error"].as_str().unwrap_or("").to_string(),
        state: s["state"].as_str().unwrap_or("").to_string(),
    }
}

impl BtEngine for LibtorrentEngine {
    fn name(&self) -> &'static str {
        "libtorrent"
    }

    fn add_magnet(&self, magnet: &str, save_dir: &str, name_hint: Option<&str>) -> Result<String> {
        let v = self.call(
            "add_magnet",
            json!({
                "magnet": magnet,
                "save_dir": save_dir,
                "name": name_hint.unwrap_or(""),
                "always_active": true,
            }),
        )?;
        self.jstr(&v, "infohash")
    }

    fn add_torrent_bytes(&self, bytes: &[u8], save_dir: &str) -> Result<String> {
        let v = self.call(
            "add_torrent",
            json!({
                "torrent_b64": b64_encode(bytes),
                "save_dir": save_dir,
                "always_active": true,
            }),
        )?;
        self.jstr(&v, "infohash")
    }

    fn remove_torrent(&self, infohash: &str, delete_files: bool) -> Result<()> {
        self.call(
            "remove",
            json!({"infohash": infohash, "delete_files": delete_files}),
        )?;
        Ok(())
    }

    fn set_paused(&self, infohash: &str, paused: bool) -> Result<()> {
        self.call("pause", json!({"infohash": infohash, "paused": paused}))?;
        Ok(())
    }

    fn torrent_states(&self) -> Result<Vec<TorrentState>> {
        let v = self.call("states", json!({}))?;
        let mut out = Vec::new();
        if let Some(arr) = v.get("torrents").and_then(|a| a.as_array()) {
            for s in arr {
                out.push(parse_state(s));
            }
        }
        Ok(out)
    }

    fn torrent_peers(&self, infohash: &str) -> Result<Vec<PeerInfo>> {
        let v = self.call("peers", json!({"infohash": infohash}))?;
        let mut out = Vec::new();
        if let Some(arr) = v.get("peers").and_then(|a| a.as_array()) {
            for p in arr {
                out.push(PeerInfo {
                    ip: p["ip"].as_str().unwrap_or("").to_string(),
                    port: p["port"].as_i64().unwrap_or(0) as u16,
                    client: p["client"].as_str().unwrap_or("").to_string(),
                    progress: p["progress"].as_f64().unwrap_or(0.0) as f32,
                    up_speed: p["up_speed"].as_i64().unwrap_or(0),
                    down_speed: p["down_speed"].as_i64().unwrap_or(0),
                    flags: p["flags"]
                        .as_i64()
                        .map(|f| format!("{f:x}"))
                        .unwrap_or_default(),
                    chat_capable: p["chat_capable"].as_bool().unwrap_or(false),
                });
            }
        }
        Ok(out)
    }

    fn set_file_priorities(&self, infohash: &str, priorities: Vec<i8>) -> Result<()> {
        self.call(
            "file_priorities",
            json!({"infohash": infohash, "priorities": priorities}),
        )?;
        Ok(())
    }

    fn file_list(&self, infohash: &str) -> Result<Vec<FileEntry>> {
        let v = self.call("files", json!({"infohash": infohash}))?;
        let mut out = Vec::new();
        if let Some(arr) = v.get("files").and_then(|a| a.as_array()) {
            for f in arr {
                out.push(FileEntry {
                    index: f["index"].as_i64().unwrap_or(0) as usize,
                    path: f["path"].as_str().unwrap_or("").to_string(),
                    size: f["size"].as_i64().unwrap_or(0),
                    priority: f["priority"].as_i64().unwrap_or(4) as i8,
                    progress: f["progress"].as_f64().unwrap_or(0.0) as f32,
                });
            }
        }
        Ok(out)
    }

    fn add_tracker(&self, infohash: &str, url: &str, tier: i32) -> Result<()> {
        self.call(
            "add_tracker",
            json!({"infohash": infohash, "url": url, "tier": tier}),
        )?;
        Ok(())
    }

    fn remove_tracker(&self, infohash: &str, url: &str) -> Result<()> {
        self.call("remove_tracker", json!({"infohash": infohash, "url": url}))?;
        Ok(())
    }

    fn trackers(&self, infohash: &str) -> Result<Vec<TrackerInfo>> {
        let v = self.call("trackers", json!({"infohash": infohash}))?;
        let mut out = Vec::new();
        if let Some(arr) = v.get("trackers").and_then(|a| a.as_array()) {
            for t in arr {
                out.push(TrackerInfo {
                    url: t["url"].as_str().unwrap_or("").to_string(),
                    tier: t["tier"].as_i64().unwrap_or(0) as i32,
                    verified: t["verified"].as_bool().unwrap_or(false),
                    fails: t["fails"].as_i64().unwrap_or(0) as i32,
                    message: t["message"].as_str().unwrap_or("").to_string(),
                });
            }
        }
        Ok(out)
    }

    fn create_torrent(&self, path: &str, comment: &str) -> Result<CreatedTorrent> {
        let v = self.call("create_torrent", json!({"path": path, "comment": comment}))?;
        let ih_hex = self.jstr(&v, "infohash")?;
        let ih = hex20(&ih_hex).ok_or_else(|| CoreError::Engine("bad infohash".into()))?;
        Ok(CreatedTorrent {
            infohash: ih,
            torrent_bytes: b64_decode(&self.jstr(&v, "torrent_b64")?),
            magnet: self.jstr(&v, "magnet")?,
        })
    }

    fn dht_get_immutable(&self, target: &Sha1Hash) -> Result<()> {
        self.call(
            "dht_get_immutable",
            json!({"target_hex": hex::encode(target)}),
        )?;
        Ok(())
    }

    fn dht_put_immutable(&self, value: &[u8], expected_target: &Sha1Hash) -> Result<()> {
        let v = self.call(
            "dht_put_immutable",
            json!({
                "value_b64": b64_encode(value),
                "target_hex": hex::encode(expected_target),
            }),
        )?;
        if v.get("matches_expected").and_then(|m| m.as_bool()) == Some(false) {
            return Err(CoreError::Engine(
                "bencode canonicality mismatch: DHT target differs from local hash".into(),
            ));
        }
        Ok(())
    }

    fn dht_get_mutable(&self, pk: &[u8; 32], salt: &str) -> Result<()> {
        self.call(
            "dht_get_mutable",
            json!({"pk_hex": hex::encode(pk), "salt": salt}),
        )?;
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
        self.call(
            "dht_put_mutable",
            json!({
                "pk_hex": hex::encode(pk),
                "salt": salt,
                "seq": seq,
                "sig_b64": b64_encode(sig),
                "value_b64": b64_encode(value),
            }),
        )?;
        Ok(())
    }

    fn ext_send(&self, infohash: &str, payload: &[u8]) -> Result<u32> {
        let v = self.call(
            "ext_send",
            json!({"infohash": infohash, "payload_b64": b64_encode(payload)}),
        )?;
        Ok(v.get("sent").and_then(|s| s.as_i64()).unwrap_or(0) as u32)
    }

    fn set_limits(&self, upload: i64, download: i64) -> Result<()> {
        self.call(
            "set_limits",
            json!({"up_limit": upload, "down_limit": download}),
        )?;
        Ok(())
    }

    fn session_stats(&self) -> Result<SessionStats> {
        let v = self.call("stats", json!({}))?;
        Ok(SessionStats {
            dht_nodes: v["dht_nodes"].as_i64().unwrap_or(-1),
            upload_rate: v["upload_rate"].as_i64().unwrap_or(0),
            download_rate: v["download_rate"].as_i64().unwrap_or(0),
            num_torrents: v["num_torrents"].as_i64().unwrap_or(0),
            has_incoming: v["has_incoming"].as_bool().unwrap_or(false),
        })
    }
}

/// Create the production engine + event stream (used by the FFI layer).
pub fn create_engine(cfg: Json) -> Result<(Arc<dyn BtEngine>, Receiver<EngineEvent>)> {
    let (engine, rx) = LibtorrentEngine::new(cfg)?;
    Ok((Arc::new(engine), rx))
}
