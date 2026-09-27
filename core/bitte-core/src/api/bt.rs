//! bt.* JSON methods — the plain BitTorrent client surface.

use base64::Engine as _;
use serde_json::{json, Value as Json};

use crate::api::{jbool, jstr, Api};
use crate::store::TorrentRow;
use crate::{CoreError, Result};

impl Api {
    fn save_dir_for(&self, ih_hex: &str) -> String {
        self.downloads_dir()
            .join(ih_hex)
            .to_string_lossy()
            .to_string()
    }

    pub fn bt_add(&self, p: Json) -> Result<Json> {
        let magnet = jstr(&p, "magnet")?.trim().to_string();
        let (ih_hex, dn) = crate::mock::parse_magnet(&magnet)?;
        let name = p
            .get("name")
            .and_then(|v| v.as_str())
            .map(String::from)
            .or(dn)
            .unwrap_or_else(|| ih_hex.clone());
        let save_dir = self.save_dir_for(&ih_hex);
        std::fs::create_dir_all(&save_dir)?;
        {
            let st = self.inner.state.lock().unwrap();
            // never let the BT page hijack chat-internal torrents
            if let Ok(Some(row)) = st.store.group_by_magnet_ih(&ih_hex) {
                return Ok(json!({
                    "infohash": ih_hex,
                    "note": "this torrent is a chat group manifest",
                    "group_id": hex::encode(row.gid),
                }));
            }
            st.store.torrent_upsert(&TorrentRow {
                infohash: ih_hex.clone(),
                name: name.clone(),
                magnet: magnet.clone(),
                save_path: save_dir.clone(),
                kind: 0,
                group_id: None,
                added: crate::now_ms(),
            })?;
        }
        self.inner
            .engine
            .add_magnet(&magnet, &save_dir, Some(&name))?;
        self.emit_event("bt.added", json!({"infohash": ih_hex, "name": name}));
        Ok(json!({"infohash": ih_hex, "name": name, "save_path": save_dir}))
    }

    pub fn bt_add_file(&self, p: Json) -> Result<Json> {
        let b64 = jstr(&p, "torrent_b64")?;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(b64)
            .map_err(|_| CoreError::Invalid("bad base64".to_string()))?;
        // ask the engine to parse it (it knows the format)
        let tmp = self.inner.data_dir.join("tmp");
        std::fs::create_dir_all(&tmp)?;
        let tmp_file = tmp.join(format!("import-{}.torrent", crate::now_ms()));
        std::fs::write(&tmp_file, &bytes)?;
        // create_torrent is not the parser; engines expose add_torrent_bytes
        // which returns the infohash, so add into a staging dir first
        let staging = tmp.join(format!("stage-{}", crate::now_ms()));
        std::fs::create_dir_all(&staging)?;
        let ih = self
            .inner
            .engine
            .add_torrent_bytes(&bytes, &staging.to_string_lossy())?;
        // move to canonical dir: we must re-add with the right save dir.
        let save_dir = self.save_dir_for(&ih);
        let _ = self.inner.engine.remove_torrent(&ih, false);
        std::fs::create_dir_all(&save_dir)?;
        // move already-downloaded files (usually none) into place
        if let Ok(entries) = std::fs::read_dir(&staging) {
            for e in entries.flatten() {
                let target = std::path::Path::new(&save_dir).join(e.file_name());
                let _ = std::fs::rename(e.path(), target);
            }
        }
        let _ = std::fs::remove_dir_all(&staging);
        let _ = std::fs::remove_file(&tmp_file);
        self.inner.engine.add_torrent_bytes(&bytes, &save_dir)?;
        let magnet = p
            .get("magnet")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let name = p
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or(&ih)
            .to_string();
        {
            let st = self.inner.state.lock().unwrap();
            st.store.torrent_upsert(&TorrentRow {
                infohash: ih.clone(),
                name: name.clone(),
                magnet,
                save_path: save_dir.clone(),
                kind: 0,
                group_id: None,
                added: crate::now_ms(),
            })?;
        }
        self.emit_event("bt.added", json!({"infohash": ih, "name": name}));
        Ok(json!({"infohash": ih, "name": name, "save_path": save_dir}))
    }

    pub fn bt_create_seed(&self, p: Json) -> Result<Json> {
        let path = jstr(&p, "path")?.to_string();
        if !std::path::Path::new(&path).exists() {
            return Err(CoreError::NotFound(path));
        }
        let created = self.inner.engine.create_torrent(&path, "BitteChat seed")?;
        let ih_hex = hex::encode(created.infohash);
        let save_dir = std::path::Path::new(&path)
            .parent()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|| self.save_dir_for(&ih_hex));
        self.inner
            .engine
            .add_torrent_bytes(&created.torrent_bytes, &save_dir)?;
        let name = p
            .get("name")
            .and_then(|v| v.as_str())
            .map(String::from)
            .unwrap_or_else(|| {
                std::path::Path::new(&path)
                    .file_name()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_else(|| ih_hex.clone())
            });
        {
            let st = self.inner.state.lock().unwrap();
            st.store.torrent_upsert(&TorrentRow {
                infohash: ih_hex.clone(),
                name: name.clone(),
                magnet: created.magnet.clone(),
                save_path: save_dir.clone(),
                kind: 0,
                group_id: None,
                added: crate::now_ms(),
            })?;
        }
        self.emit_event("bt.added", json!({"infohash": ih_hex, "name": name}));
        Ok(json!({
            "infohash": ih_hex,
            "magnet": created.magnet,
            "name": name,
        }))
    }

    /// Merge live engine state with the persistent registry.
    pub fn bt_list(&self) -> Result<Json> {
        let states = self.inner.engine.torrent_states()?;
        let st = self.inner.state.lock().unwrap();
        let rows: std::collections::HashMap<String, TorrentRow> = st
            .store
            .torrents_all()?
            .into_iter()
            .map(|r| (r.infohash.clone(), r))
            .collect();
        let mut out: Vec<Json> = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for s in states {
            seen.insert(s.infohash.clone());
            let row = rows.get(&s.infohash);
            let (kind, group_name) = match row {
                Some(r) if r.kind == 1 => {
                    let gname = r
                        .group_id
                        .and_then(|g| st.store.group_get(&g).ok().flatten())
                        .map(|g| g.name)
                        .unwrap_or_default();
                    (1, gname)
                }
                Some(r) => (r.kind, String::new()),
                None => (0, String::new()),
            };
            let display_name = match kind {
                1 if !group_name.is_empty() => format!("群聊·{group_name}"),
                _ => row
                    .map(|r| r.name.clone())
                    .filter(|n| !n.is_empty())
                    .unwrap_or(s.name.clone()),
            };
            out.push(json!({
                "infohash": s.infohash,
                "name": display_name,
                "kind": kind,
                "group_name": group_name,
                "save_path": s.save_path,
                "total_bytes": s.total_bytes,
                "progress": s.progress,
                "download_rate": s.download_rate,
                "upload_rate": s.upload_rate,
                "num_peers": s.num_peers,
                "num_seeds": s.num_seeds,
                "paused": s.paused,
                "finished": s.finished,
                "error": s.error,
                "state": s.state,
                "magnet": row.map(|r| r.magnet.clone()).unwrap_or_default(),
            }));
        }
        // registered but not (yet) in the engine: show as queued
        for (ih, r) in rows.iter() {
            if seen.contains(ih) {
                continue;
            }
            out.push(json!({
                "infohash": ih,
                "name": r.name,
                "kind": r.kind,
                "save_path": r.save_path,
                "total_bytes": 0,
                "progress": 0.0,
                "download_rate": 0,
                "upload_rate": 0,
                "num_peers": 0,
                "num_seeds": 0,
                "paused": false,
                "finished": false,
                "error": "",
                "state": "queued",
                "magnet": r.magnet,
            }));
        }
        Ok(json!({"torrents": out}))
    }

    pub fn bt_control(&self, p: Json) -> Result<Json> {
        let ih = jstr(&p, "infohash")?.to_string();
        let op = jstr(&p, "op")?;
        match op {
            "pause" => self.inner.engine.set_paused(&ih, true)?,
            "resume" => self.inner.engine.set_paused(&ih, false)?,
            "remove" => {
                let delete = jbool(&p, "delete_files", false);
                {
                    let st = self.inner.state.lock().unwrap();
                    // protect chat-critical torrents unless explicitly forced
                    if let Some(row) = st
                        .store
                        .torrents_all()?
                        .into_iter()
                        .find(|t| t.infohash == ih)
                    {
                        if row.kind == 1 && !jbool(&p, "force", false) {
                            return Err(CoreError::Invalid(
                                "这是群聊清单种子，请通过聊天页退群来移除".into(),
                            ));
                        }
                    }
                    st.store.torrent_remove(&ih)?;
                }
                self.inner.engine.remove_torrent(&ih, delete)?;
            }
            "recheck" => {
                // re-add via stored magnet forces a hash check in libtorrent
                let st = self.inner.state.lock().unwrap();
                if let Some(row) = st
                    .store
                    .torrents_all()?
                    .into_iter()
                    .find(|t| t.infohash == ih)
                {
                    if !row.magnet.is_empty() {
                        let save = row.save_path.clone();
                        drop(st);
                        let _ = self.inner.engine.remove_torrent(&ih, false);
                        self.inner
                            .engine
                            .add_magnet(&row.magnet, &save, Some(&row.name))?;
                    }
                }
            }
            _ => return Err(CoreError::Invalid(format!("unknown op {op}"))),
        }
        Ok(json!({"ok": true}))
    }

    pub fn bt_files(&self, p: Json) -> Result<Json> {
        let ih = jstr(&p, "infohash")?;
        let files = self.inner.engine.file_list(ih)?;
        Ok(json!({"files": files}))
    }

    pub fn bt_file_priorities(&self, p: Json) -> Result<Json> {
        let ih = jstr(&p, "infohash")?.to_string();
        let prios: Vec<i8> = p
            .get("priorities")
            .and_then(|v| v.as_array())
            .ok_or_else(|| CoreError::Invalid("missing priorities".into()))?
            .iter()
            .map(|v| v.as_i64().unwrap_or(4) as i8)
            .collect();
        self.inner.engine.set_file_priorities(&ih, prios)?;
        Ok(json!({"ok": true}))
    }

    pub fn bt_peers(&self, p: Json) -> Result<Json> {
        let ih = jstr(&p, "infohash")?;
        let peers = self.inner.engine.torrent_peers(ih)?;
        Ok(json!({"peers": peers}))
    }

    pub fn bt_stats(&self) -> Result<Json> {
        let stats = self.inner.engine.session_stats()?;
        Ok(serde_json::to_value(stats).unwrap_or(json!({})))
    }

    /// Periodic broadcast used by the scheduler.
    pub fn push_bt_updates(&self) {
        if let Ok(list) = self.bt_list() {
            self.emit_event("bt.updated", list);
        }
        if let Ok(stats) = self.bt_stats() {
            self.emit_event("bt.stats", stats);
        }
    }
}
