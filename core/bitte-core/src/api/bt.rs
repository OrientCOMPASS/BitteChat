//! bt.* JSON methods — the plain BitTorrent client surface.

use base64::Engine as _;
use serde_json::{json, Value as Json};

use crate::api::{jbool, ji64, jstr, Api};
use crate::store::TorrentRow;
use crate::{CoreError, Result};

/// Append `tr=` params for trackers not already present in the magnet.
pub fn magnet_with_trackers(magnet: &str, urls: &[String]) -> String {
    let mut out = magnet.to_string();
    for u in urls {
        let enc = crate::api::chat::urlquery(u);
        if out.contains(&format!("tr={enc}")) || out.contains(&format!("tr={u}")) {
            continue;
        }
        out.push_str("&tr=");
        out.push_str(&enc);
    }
    out
}

/// Strip `tr=` params matching `url` (raw or percent-encoded) from a magnet.
pub fn magnet_without_tracker(magnet: &str, url: &str) -> String {
    let enc = crate::api::chat::urlquery(url);
    magnet
        .split('&')
        .filter(|part| match part.strip_prefix("tr=") {
            Some(v) => v != enc && v != url,
            None => true,
        })
        .collect::<Vec<_>>()
        .join("&")
}

impl Api {
    pub fn save_dir_for(&self, ih_hex: &str) -> String {
        self.downloads_dir()
            .join(ih_hex)
            .to_string_lossy()
            .to_string()
    }

    /// User-configured default tracker list (applied to every torrent added).
    pub fn default_trackers(&self) -> Vec<String> {
        let st = self.inner.state.lock().unwrap();
        let raw = st.store.kv_get("default_trackers").ok().flatten();
        raw.and_then(|b| serde_json::from_slice::<Vec<String>>(&b).ok())
            .unwrap_or_default()
    }

    /// Add a magnet to the engine and apply the default trackers.
    /// Returns the infohash. Shared by the BT page, chat rooms and RSS.
    pub fn engine_add_magnet(
        &self,
        magnet: &str,
        save_dir: &str,
        name_hint: Option<&str>,
    ) -> Result<String> {
        let ih = self.inner.engine.add_magnet(magnet, save_dir, name_hint)?;
        self.apply_default_trackers(&ih);
        Ok(ih)
    }

    /// Register default trackers on a live engine torrent (best effort).
    pub fn apply_default_trackers(&self, ih_hex: &str) {
        for (tier, url) in self.default_trackers().into_iter().enumerate() {
            let _ = self.inner.engine.add_tracker(ih_hex, &url, tier as i32);
        }
    }

    /// The magnet we persist for a torrent: user input extended with the
    /// default trackers so restarts/rechecks keep them.
    pub fn stored_magnet_with_defaults(&self, magnet: &str) -> String {
        let urls = self.default_trackers();
        if urls.is_empty() {
            magnet.to_string()
        } else {
            magnet_with_trackers(magnet, &urls)
        }
    }

    pub fn bt_add(&self, p: Json) -> Result<Json> {
        let input = jstr(&p, "magnet")?.trim().to_string();
        // accepts a magnet link, a bare 40-hex infohash or 32-char base32
        let (ih_hex, dn, magnet) = crate::mock::normalize_torrent_input(&input)?;
        let magnet = self.stored_magnet_with_defaults(&magnet);
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
            // never let the BT page hijack DM channel manifest torrents
            if let Ok(Some(row)) = st.store.group_by_magnet_ih(&ih_hex) {
                if row.manifest.is_dm() {
                    return Ok(json!({
                        "infohash": ih_hex,
                        "note": "this torrent is an encrypted DM channel",
                        "group_id": hex::encode(row.gid),
                    }));
                }
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
            st.store.torrent_set_magnet(&ih_hex, &magnet)?;
        }
        self.inner
            .engine
            .add_magnet(&magnet, &save_dir, Some(&name))?;
        self.apply_default_trackers(&ih_hex);
        let group_id = self.active_group_id_for(&ih_hex);
        self.emit_event(
            "bt.added",
            json!({
                "infohash": ih_hex.clone(),
                "name": name.clone(),
                "group_id": group_id,
            }),
        );
        Ok(json!({
            "infohash": ih_hex,
            "name": name,
            "magnet": magnet,
            "save_path": save_dir,
        }))
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
        self.apply_default_trackers(&ih);
        let magnet = {
            let given = p
                .get("magnet")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim()
                .to_string();
            let base = if given.is_empty() {
                format!("magnet:?xt=urn:btih:{ih}")
            } else {
                given
            };
            self.stored_magnet_with_defaults(&base)
        };
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
                magnet: magnet.clone(),
                save_path: save_dir.clone(),
                kind: 0,
                group_id: None,
                added: crate::now_ms(),
            })?;
            st.store.torrent_set_magnet(&ih, &magnet)?;
        }
        let group_id = self.active_group_id_for(&ih);
        self.emit_event(
            "bt.added",
            json!({
                "infohash": ih.clone(),
                "name": name.clone(),
                "group_id": group_id,
            }),
        );
        Ok(json!({"infohash": ih, "name": name, "magnet": magnet, "save_path": save_dir}))
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
        self.apply_default_trackers(&ih_hex);
        let magnet = self.stored_magnet_with_defaults(&created.magnet);
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
                magnet: magnet.clone(),
                save_path: save_dir.clone(),
                kind: 0,
                group_id: None,
                added: crate::now_ms(),
            })?;
            st.store.torrent_set_magnet(&ih_hex, &magnet)?;
        }
        self.emit_event(
            "bt.added",
            json!({
                "infohash": ih_hex.clone(),
                "name": name.clone(),
                "group_id": self.active_group_id_for(&ih_hex),
            }),
        );
        Ok(json!({
            "infohash": ih_hex,
            "magnet": magnet,
            "name": name,
        }))
    }

    /// Merge live engine state with the persistent registry.
    /// Chat-internal torrents (group manifests, chat attachments) are hidden
    /// unless `include_chat` is true, so the BT page stays about *the user's*
    /// downloads instead of being polluted by chat plumbing.
    pub fn bt_list(&self, include_chat: bool) -> Result<Json> {
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
            // kind 4 = self-published seeds: their OWN scope, always listed
            // (files live scattered in place); only chat-internal kinds 1 & 2
            // hide behind the include_chat toggle.
            if !include_chat && (kind == 1 || kind == 2) {
                continue;
            }
            let display_name = match kind {
                1 if !group_name.is_empty() => format!("私聊·{group_name}"),
                _ => row
                    .map(|r| r.name.clone())
                    .filter(|n| !n.is_empty())
                    .unwrap_or(s.name.clone()),
            };
            // torrent rooms: the group id equals the torrent infohash and an
            // active runtime exists iff we are in the room
            let room = if st.groups.contains_key(&s.infohash) {
                s.infohash.clone()
            } else {
                String::new()
            };
            out.push(json!({
                "infohash": s.infohash,
                "name": display_name,
                "kind": kind,
                "group_name": group_name,
                "group_id": room,
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
            // see note above: kind 4 is its own always-visible scope
            if !include_chat && (r.kind == 1 || r.kind == 2) {
                continue;
            }
            let room = if st.groups.contains_key(ih) {
                ih.clone()
            } else {
                String::new()
            };
            out.push(json!({
                "infohash": ih,
                "name": r.name,
                "kind": r.kind,
                "group_id": room,
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
                                "这是私聊频道的清单种子，请通过聊天页退出该私聊来移除".into(),
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

    /// Active (not-left) chat room bound to a torrent, if any. For torrent
    /// rooms the group id equals the infohash.
    pub fn active_group_id_for(&self, ih_hex: &str) -> String {
        let st = self.inner.state.lock().unwrap();
        match st.by_ih.get(ih_hex) {
            Some(gid) if st.groups.contains_key(gid) => gid.clone(),
            _ => String::new(),
        }
    }

    // ---- trackers ----------------------------------------------------------

    pub fn bt_trackers(&self, p: Json) -> Result<Json> {
        let ih = jstr(&p, "infohash")?;
        let trackers = self.inner.engine.trackers(ih)?;
        Ok(json!({
            "trackers": trackers,
            "defaults": self.default_trackers(),
        }))
    }

    pub fn bt_add_tracker(&self, p: Json) -> Result<Json> {
        let ih = jstr(&p, "infohash")?.to_string();
        let url = jstr(&p, "url")?.trim().to_string();
        if !crate::mock::valid_tracker_url(&url) {
            return Err(CoreError::Invalid(
                "tracker 地址需以 http:// https:// 或 udp:// 开头".into(),
            ));
        }
        let tier = ji64(&p, "tier", 0).clamp(0, 1000) as i32;
        // best effort on the live torrent; the stored magnet is the source of
        // truth across restarts/rechecks
        let live = self.inner.engine.add_tracker(&ih, &url, tier).is_ok();
        {
            let st = self.inner.state.lock().unwrap();
            if let Ok(Some(row)) = st.store.torrent_get(&ih) {
                let m = magnet_with_trackers(&row.magnet, std::slice::from_ref(&url));
                st.store.torrent_set_magnet(&ih, &m)?;
            }
        }
        Ok(json!({"ok": true, "live": live, "url": url, "tier": tier}))
    }

    pub fn bt_remove_tracker(&self, p: Json) -> Result<Json> {
        let ih = jstr(&p, "infohash")?.to_string();
        let url = jstr(&p, "url")?.trim().to_string();
        let _ = self.inner.engine.remove_tracker(&ih, &url);
        {
            let st = self.inner.state.lock().unwrap();
            if let Ok(Some(row)) = st.store.torrent_get(&ih) {
                let m = magnet_without_tracker(&row.magnet, &url);
                st.store.torrent_set_magnet(&ih, &m)?;
            }
        }
        Ok(json!({"ok": true}))
    }

    pub fn bt_get_default_trackers(&self) -> Result<Json> {
        Ok(json!({"trackers": self.default_trackers()}))
    }

    /// Persist a global default tracker list and apply it to every torrent
    /// currently in the session (and to all future adds).
    pub fn bt_set_default_trackers(&self, p: Json) -> Result<Json> {
        let urls: Vec<String> = p
            .get("trackers")
            .and_then(|v| v.as_array())
            .ok_or_else(|| CoreError::Invalid("missing trackers array".into()))?
            .iter()
            .filter_map(|v| v.as_str().map(|s| s.trim().to_string()))
            .filter(|s| !s.is_empty())
            .collect();
        if urls.len() > 64 {
            return Err(CoreError::Invalid("too many trackers (max 64)".into()));
        }
        // dedupe preserving order
        let mut seen = std::collections::HashSet::new();
        let urls: Vec<String> = urls
            .into_iter()
            .filter(|u| seen.insert(u.clone()))
            .collect();
        for u in &urls {
            if !crate::mock::valid_tracker_url(u) {
                return Err(CoreError::Invalid(format!(
                    "无效的 tracker 地址: {u}（需以 http:// https:// 或 udp:// 开头）"
                )));
            }
        }
        {
            let st = self.inner.state.lock().unwrap();
            st.store.kv_set(
                "default_trackers",
                &serde_json::to_vec(&urls).unwrap_or_default(),
            )?;
        }
        // apply to live torrents and persist into their stored magnets
        let states = self.inner.engine.torrent_states().unwrap_or_default();
        let mut touched = 0i64;
        for s in &states {
            for (tier, u) in urls.iter().enumerate() {
                let _ = self.inner.engine.add_tracker(&s.infohash, u, tier as i32);
            }
            touched += 1;
            let st = self.inner.state.lock().unwrap();
            if let Ok(Some(row)) = st.store.torrent_get(&s.infohash) {
                let m = magnet_with_trackers(&row.magnet, &urls);
                let _ = st.store.torrent_set_magnet(&s.infohash, &m);
            }
        }
        Ok(json!({"ok": true, "count": urls.len(), "applied_to": touched}))
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

    pub fn bt_get_limits(&self) -> Result<Json> {
        let st = self.inner.state.lock().unwrap();
        let raw = st.store.kv_get("limits").ok().flatten();
        drop(st);
        let v = raw
            .and_then(|r| serde_json::from_slice::<Json>(&r).ok())
            .unwrap_or_else(|| json!({"up": 0, "down": 0}));
        let mut o = v.as_object().cloned().unwrap_or_default();
        o.insert("ok".to_string(), json!(true));
        Ok(Json::Object(o))
    }

    pub fn bt_set_limits(&self, p: Json) -> Result<Json> {
        let up = ji64(&p, "up", 0).max(0);
        let down = ji64(&p, "down", 0).max(0);
        self.inner.engine.set_limits(up, down)?;
        let st = self.inner.state.lock().unwrap();
        st.store.kv_set(
            "limits",
            &serde_json::to_vec(&json!({"up": up, "down": down})).unwrap_or_default(),
        )?;
        Ok(json!({"ok": true, "up": up, "down": down}))
    }

    /// Periodic broadcast used by the scheduler.
    pub fn push_bt_updates(&self) {
        if let Ok(list) = self.bt_list(false) {
            self.emit_event("bt.updated", list);
        }
        if let Ok(stats) = self.bt_stats() {
            self.emit_event("bt.stats", stats);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn magnet_tracker_merge_and_strip() {
        let base = "magnet:?xt=urn:btih:aabbccddeeff00112233445566778899aabbccdd";
        let urls = vec![
            "udp://tracker.example.org:1337/announce".to_string(),
            "https://t.example/announce".to_string(),
        ];
        let m = magnet_with_trackers(base, &urls);
        assert!(m.contains("tr=udp%3A%2F%2Ftracker.example.org%3A1337%2Fannounce"));
        assert!(m.contains("tr=https%3A%2F%2Ft.example%2Fannounce"));
        // idempotent
        let m2 = magnet_with_trackers(&m, &urls);
        assert_eq!(m, m2);
        // strip one
        let m3 = magnet_without_tracker(&m, &urls[0]);
        assert!(!m3.contains("tracker.example.org"));
        assert!(m3.contains("t.example"));
        assert!(m3.starts_with("magnet:?xt=urn:btih:"));
        // strip the rest -> base magnet
        let m4 = magnet_without_tracker(&m3, &urls[1]);
        assert_eq!(m4, base);
    }
}
