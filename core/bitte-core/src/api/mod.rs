//! The JSON bridge: one entry point (`dispatch`) used by the FFI layer and a
//! background event loop + scheduler that keeps chats synced and pushes
//! events to the UI.
//!
//! Method naming: `bt.*`, `chat.*`, `rss.*`, `sys.*`.
//! Every method takes a JSON object and returns a JSON object or an error.
//!
//! Locking model: ONE state lock ([`CoreState`]) guards store + group
//! runtimes. `identity`/`profile`/`active_group` are leaf RwLocks: never
//! acquire them while holding the state lock — copy what you need first.
//! Engine calls are non-blocking (async alerts), safe under the state lock.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex, RwLock};

use serde_json::{json, Value as Json};

use crate::chat::sync::GroupSync;
use crate::crypto::{Identity, Sha1Hash};
use crate::engine::{BtEngine, EngineEvent};
use crate::store::{GroupRow, Store};
use crate::{CoreError, Result};

pub mod bt;
pub mod chat;
pub mod events;
pub mod rss;

/// The currently active identity (private key + display profile).
#[derive(Clone)]
pub struct ActiveIdentity {
    pub row_id: i64,
    pub identity: Identity,
    pub name: String,
    pub avatar_b64: String,
}

pub struct GroupRuntime {
    pub sync: GroupSync,
    pub row: GroupRow,
    /// DM only: the signed DmReq frame awaiting a chance to be delivered
    /// (peer was offline at chat_start_dm time)
    pub pending_dm_req: Option<Vec<u8>>,
    /// next sequence number for our own messages in this group
    pub own_seq: i64,
    pub last_publish: i64,
}

/// An incoming DM request awaiting the user's accept/decline.
#[derive(Debug, Clone)]
pub struct DmPendingReq {
    pub from_pk: String,
    pub from_name: String,
    pub from_x: String,
    /// swarm the request arrived on (preferred reply route)
    pub ih: String,
    pub ts: i64,
}

pub struct CoreState {
    pub store: Store,
    pub groups: HashMap<String, GroupRuntime>,
    /// manifest-torrent infohash (hex) -> group id (hex)
    pub by_ih: HashMap<String, String>,
    /// pending joins: manifest infohash -> save dir
    pub pending_joins: HashMap<String, PathBuf>,
    /// chat peer presence: identity pk (hex) -> swarms (infohash) where the
    /// peer currently holds a bc_chat connection to us
    pub presence: HashMap<String, std::collections::HashSet<String>>,
    /// gid (hex) -> incoming DM request awaiting the user's response
    pub dm_pending: HashMap<String, DmPendingReq>,
    /// gid (hex) of DM channels WE initiated but the peer hasn't accepted
    /// yet (DmReq is re-sent when the peer shows up)
    pub dm_awaiting_accept: std::collections::HashSet<String>,
    /// identity pubkeys (hex) the user blocked: their DM requests are
    /// silently dropped (anti-harassment)
    pub dm_blocked: std::collections::HashSet<String>,
}

pub struct Inner {
    pub data_dir: PathBuf,
    /// user-chosen download root (kv-persisted); None = <data_dir>/downloads
    pub download_dir: RwLock<Option<PathBuf>>,
    pub engine: Arc<dyn BtEngine>,
    pub state: Mutex<CoreState>,
    pub active: RwLock<ActiveIdentity>,
    pub emit: Sender<String>,
    pub active_group: RwLock<Option<String>>,
    pub shutdown: RwLock<bool>,
}

pub struct Api {
    pub inner: Arc<Inner>,
}

impl Api {
    /// Create the API around an engine. Returns the API and the stream of
    /// JSON events for the UI.
    pub fn new(
        data_dir: PathBuf,
        engine: Arc<dyn BtEngine>,
        engine_events: Receiver<EngineEvent>,
    ) -> Result<(Api, Receiver<String>)> {
        std::fs::create_dir_all(&data_dir)?;
        std::fs::create_dir_all(data_dir.join("groups"))?;
        std::fs::create_dir_all(data_dir.join("downloads"))?;
        let store = Store::open(&data_dir.join("bitte.db"))?;

        // identity bootstrap: migrate legacy kv layout into identities table
        let legacy_seed: [u8; 32] = match store.kv_get("identity_seed")? {
            Some(seed) if seed.len() == 32 => {
                let mut s = [0u8; 32];
                s.copy_from_slice(&seed);
                s
            }
            _ => crate::crypto::new_seed(),
        };
        let legacy_profile: serde_json::Value = store
            .kv_get("profile")?
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_else(|| json!({}));
        let mut legacy_name = legacy_profile
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let legacy_avatar = legacy_profile
            .get("avatar_b64")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if legacy_name.is_empty() {
            let pk = Identity::from_seed(legacy_seed).public_key();
            legacy_name = format!("旅人-{}", hex::encode(pk)[..4].to_uppercase());
        }
        let now = crate::now_ms();
        store.identities_migrate_legacy(&legacy_seed, &legacy_name, &legacy_avatar, now)?;
        store.kv_set("identity_seed", &legacy_seed)?;
        let active_id = store
            .identities_active_id()?
            .ok_or_else(|| CoreError::Internal("no active identity".into()))?;
        let row = store
            .identity_get(active_id)?
            .ok_or_else(|| CoreError::Internal("active identity row missing".into()))?;
        let mut seed32 = [0u8; 32];
        seed32.copy_from_slice(&row.seed);
        let active = ActiveIdentity {
            row_id: row.id,
            identity: Identity::from_seed(seed32),
            name: row.name,
            avatar_b64: row.avatar,
        };

        let (emit, events) = channel::<String>();
        // restore custom download dir (set via sys.set_download_dir)
        let custom_dl = store
            .kv_get("download_dir")
            .ok()
            .flatten()
            .and_then(|b| String::from_utf8(b).ok())
            .map(PathBuf::from)
            .filter(|p| !p.as_os_str().is_empty());
        let inner = Arc::new(Inner {
            data_dir,
            download_dir: RwLock::new(custom_dl),
            engine,
            state: Mutex::new(CoreState {
                store,
                groups: HashMap::new(),
                by_ih: HashMap::new(),
                pending_joins: HashMap::new(),
                presence: HashMap::new(),
                dm_pending: HashMap::new(),
                dm_awaiting_accept: std::collections::HashSet::new(),
                dm_blocked: std::collections::HashSet::new(),
            }),
            active: RwLock::new(active),
            emit,
            active_group: RwLock::new(None),
            shutdown: RwLock::new(false),
        });
        let api = Api { inner };
        api.apply_persisted_limits();
        // advertise our identity pubkey in bc_chat handshakes (presence +
        // DM addressing); re-issued on every identity switch
        if let Err(e) = api.inner.engine.set_chat_pk(&api.own_pk_hex()) {
            log::warn!("set_chat_pk failed: {e}");
        }
        api.restore_state()?;
        api.spawn_event_loop(engine_events);
        api.spawn_scheduler();
        Ok((api, events))
    }

    pub fn emit_json(&self, v: Json) {
        let _ = self.inner.emit.send(v.to_string());
    }

    pub fn emit_event(&self, ty: &str, data: Json) {
        self.emit_json(json!({ "type": ty, "data": data }));
    }

    /// Same as emit_event but callable with just the Inner (threads).
    pub fn emit_from(inner: &Inner, ty: &str, data: Json) {
        let _ = inner
            .emit
            .send(json!({ "type": ty, "data": data }).to_string());
    }

    pub fn data_dir(&self) -> &std::path::Path {
        &self.inner.data_dir
    }

    pub fn groups_dir(&self) -> PathBuf {
        self.inner.data_dir.join("groups")
    }

    pub fn downloads_dir(&self) -> PathBuf {
        self.inner
            .download_dir
            .read()
            .unwrap()
            .clone()
            .unwrap_or_else(|| self.inner.data_dir.join("downloads"))
    }

    pub fn sys_get_download_dir(&self) -> Result<Json> {
        Ok(json!({
            "path": self.downloads_dir().to_string_lossy(),
            "default": self.inner.data_dir.join("downloads").to_string_lossy(),
            "custom": self.inner.download_dir.read().unwrap().is_some(),
        }))
    }

    /// Point NEW downloads (BT tasks + received chat attachments) at a
    /// user-chosen directory. Existing tasks keep their recorded save_path.
    /// An empty path resets to the app-private default.
    pub fn sys_set_download_dir(&self, p: Json) -> Result<Json> {
        let raw = jstr(&p, "path")?.trim().to_string();
        if raw.is_empty() {
            *self.inner.download_dir.write().unwrap() = None;
            let st = self.inner.state.lock().unwrap();
            let _ = st.store.kv_set("download_dir", b"");
            return Ok(json!({"ok": true, "path": self.downloads_dir().to_string_lossy()}));
        }
        let path = PathBuf::from(&raw);
        // validate: create + write probe (fail fast with a clear error)
        std::fs::create_dir_all(&path)
            .map_err(|e| CoreError::Invalid(format!("目录不可用: {e}")))?;
        let probe = path.join(".bitte-write-probe");
        std::fs::write(&probe, b"x").map_err(|e| CoreError::Invalid(format!("目录不可写: {e}")))?;
        let _ = std::fs::remove_file(&probe);
        *self.inner.download_dir.write().unwrap() = Some(path.clone());
        {
            let st = self.inner.state.lock().unwrap();
            let _ = st.store.kv_set("download_dir", raw.as_bytes());
        }
        log::info!("download dir set to {}", path.display());
        Ok(json!({"ok": true, "path": path.to_string_lossy()}))
    }

    pub fn own_pk_hex(&self) -> String {
        hex::encode(self.inner.active.read().unwrap().identity.public_key())
    }

    pub fn profile_name(&self) -> String {
        self.inner.active.read().unwrap().name.clone()
    }

    pub fn profile_avatar(&self) -> String {
        self.inner.active.read().unwrap().avatar_b64.clone()
    }

    /// Main JSON entry point.
    pub fn dispatch(&self, method: &str, params: Json) -> Result<Json> {
        let p = params;
        match method {
            "sys.info" => self.sys_info(),
            "sys.identity.get" => self.identity_get(),
            "sys.identity.list" => self.identity_list(),
            "sys.identity.create" => self.identity_create(p),
            "sys.identity.switch" => self.identity_switch(p),
            "sys.identity.delete" => self.identity_delete(p),
            "sys.identity.set_avatar" => self.identity_set_avatar(p),
            "sys.set_active_group" => self.set_active_group(p),
            "sys.get_download_dir" => self.sys_get_download_dir(),
            "sys.set_download_dir" => self.sys_set_download_dir(p),

            "bt.add" => self.bt_add(p),
            "bt.add_file" => self.bt_add_file(p),
            "bt.create_seed" => self.bt_create_seed(p),
            "bt.list" => self.bt_list(crate::api::jbool(&p, "include_chat", false)),
            "bt.control" => self.bt_control(p),
            "bt.files" => self.bt_files(p),
            "bt.file_priorities" => self.bt_file_priorities(p),
            "bt.peers" => self.bt_peers(p),
            "bt.stats" => self.bt_stats(),
            "bt.set_limits" => self.bt_set_limits(p),
            "bt.get_limits" => self.bt_get_limits(),
            "bt.trackers" => self.bt_trackers(p),
            "bt.add_tracker" => self.bt_add_tracker(p),
            "bt.remove_tracker" => self.bt_remove_tracker(p),
            "bt.get_default_trackers" => self.bt_get_default_trackers(),
            "bt.set_default_trackers" => self.bt_set_default_trackers(p),

            "chat.groups" => self.chat_groups(),
            "chat.create_group" => self.chat_create_group(p),
            "chat.join_group" => self.chat_join_group(p),
            "chat.join_dm" => self.chat_join_dm(p),
            "chat.leave_group" => self.chat_leave_group(p),
            "chat.messages" => self.chat_messages(p),
            "chat.send" => self.chat_send(p),
            "chat.send_file" => self.chat_send_file(p),
            "chat.download_attachment" => self.chat_download_attachment(p),
            "chat.mark_read" => self.chat_mark_read(p),
            "chat.rename_group" => self.chat_rename_group(p),
            "chat.sync" => self.chat_sync(p),
            "chat.start_dm" => self.chat_start_dm(p),
            "chat.dm_respond" => self.chat_dm_respond(p),
            "chat.dm_requests" => self.chat_dm_requests(),
            "chat.dm_block" => self.chat_dm_block(p),
            "chat.members" => self.chat_members(p),
            "filter.rules" => self.filter_rules(),
            "filter.set_rules" => self.filter_set_rules(p),
            "chat.group_detail" => self.chat_group_detail(p),

            "rss.feeds" => self.rss_feeds(),
            "rss.add" => self.rss_add(p),
            "rss.remove" => self.rss_remove(p),
            "rss.refresh" => self.rss_refresh(p),
            "rss.items" => self.rss_items(p),
            "rss.item_detail" => self.rss_item_detail(p),
            "rss.mark_read" => self.rss_mark_read(p),
            "rss.mark_feed_read" => self.rss_mark_feed_read(p),
            "rss.download" => self.rss_download(p),

            _ => Err(CoreError::NotFound(format!("method {method}"))),
        }
    }

    fn sys_info(&self) -> Result<Json> {
        Ok(json!({
            "version": crate::VERSION,
            "engine": self.inner.engine.name(),
            "data_dir": self.inner.data_dir.to_string_lossy(),
            "protocol": crate::EXT_NAME,
        }))
    }

    fn identity_get(&self) -> Result<Json> {
        let a = self.inner.active.read().unwrap().clone();
        let xs = crate::crypto::x_secret_from_seed(&a.identity.seed);
        Ok(json!({
            "id": a.row_id,
            "name": a.name,
            "avatar_b64": a.avatar_b64,
            "pk": hex::encode(a.identity.public_key()),
            "x": hex::encode(crate::crypto::x_public(&xs)),
        }))
    }

    fn identity_list(&self) -> Result<Json> {
        let st = self.inner.state.lock().unwrap();
        let rows = st.store.identities_all()?;
        let out: Vec<Json> = rows
            .iter()
            .map(|r| {
                let mut seed = [0u8; 32];
                seed.copy_from_slice(&r.seed);
                let id = Identity::from_seed(seed);
                let xs = crate::crypto::x_secret_from_seed(&seed);
                json!({
                    "id": r.id,
                    "name": r.name,
                    "avatar_b64": r.avatar,
                    "pk": hex::encode(id.public_key()),
                    "x": hex::encode(crate::crypto::x_public(&xs)),
                    "created": r.created,
                    "active": r.active,
                })
            })
            .collect();
        Ok(json!({"identities": out}))
    }

    /// Create a NEW identity (new keypair). Renaming is intentionally not
    /// supported: a nickname is bound to its key, so changing it means a
    /// new identity.
    fn identity_create(&self, p: Json) -> Result<Json> {
        let name = crate::api::jstr(&p, "name")?.trim().to_string();
        if name.is_empty() || name.chars().count() > 32 {
            return Err(CoreError::Invalid("IDENTITY_NAME_LEN".into()));
        }
        let avatar = p
            .get("avatar_b64")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if avatar.len() > 16 * 1024 {
            return Err(CoreError::Invalid("avatar too large".into()));
        }
        let seed = crate::crypto::new_seed();
        let st = self.inner.state.lock().unwrap();
        let id = st
            .store
            .identity_insert(&name, &seed, &avatar, crate::now_ms())?;
        let ident = Identity::from_seed(seed);
        Ok(json!({
            "id": id,
            "pk": hex::encode(ident.public_key()),
        }))
    }

    fn identity_switch(&self, p: Json) -> Result<Json> {
        let id = crate::api::ji64(&p, "id", 0);
        let st = self.inner.state.lock().unwrap();
        let row = st
            .store
            .identity_get(id)?
            .ok_or_else(|| CoreError::NotFound("identity".into()))?;
        st.store.identity_set_active(id)?;
        let mut seed = [0u8; 32];
        seed.copy_from_slice(&row.seed);
        drop(st);
        let mut a = self.inner.active.write().unwrap();
        a.row_id = row.id;
        a.identity = Identity::from_seed(seed);
        a.name = row.name;
        a.avatar_b64 = row.avatar;
        let pk = hex::encode(a.identity.public_key());
        drop(a);
        // bc_chat handshakes must advertise the NEW identity from now on
        if let Err(e) = self.inner.engine.set_chat_pk(&pk) {
            log::warn!("set_chat_pk failed: {e}");
        }
        Ok(json!({"ok": true, "pk": pk}))
    }

    fn identity_delete(&self, p: Json) -> Result<Json> {
        let id = crate::api::ji64(&p, "id", 0);
        let st = self.inner.state.lock().unwrap();
        let row = st
            .store
            .identity_get(id)?
            .ok_or_else(|| CoreError::NotFound("identity".into()))?;
        if row.active {
            return Err(CoreError::Invalid("IDENTITY_ACTIVE".into()));
        }
        if st.store.identities_all()?.len() <= 1 {
            return Err(CoreError::Invalid("IDENTITY_LAST".into()));
        }
        st.store.identity_delete(id)?;
        Ok(json!({"ok": true}))
    }

    fn identity_set_avatar(&self, p: Json) -> Result<Json> {
        let avatar = p
            .get("avatar_b64")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if avatar.len() > 16 * 1024 {
            return Err(CoreError::Invalid("avatar too large".into()));
        }
        let row_id = self.inner.active.read().unwrap().row_id;
        let st = self.inner.state.lock().unwrap();
        st.store.identity_set_avatar(row_id, &avatar)?;
        drop(st);
        self.inner.active.write().unwrap().avatar_b64 = avatar;
        Ok(json!({"ok": true}))
    }

    pub fn filter_rules(&self) -> Result<Json> {
        let st = self.inner.state.lock().unwrap();
        let raw = st.store.kv_get("filter_rules")?;
        let rules: Vec<crate::filter::FilterRule> = match raw {
            Some(b) => serde_json::from_slice(&b).unwrap_or_default(),
            None => vec![],
        };
        Ok(json!({"rules": rules}))
    }

    pub fn filter_set_rules(&self, p: Json) -> Result<Json> {
        let arr = p
            .get("rules")
            .and_then(|r| r.as_array())
            .ok_or_else(|| CoreError::Invalid("missing rules array".into()))?;
        let mut rules: Vec<crate::filter::FilterRule> = Vec::new();
        for (i, r) in arr.iter().enumerate() {
            let rule: crate::filter::FilterRule = serde_json::from_value(r.clone())
                .map_err(|e| CoreError::Invalid(format!("rule {i}: {e}")))?;
            crate::filter::validate_rule(&rule)
                .map_err(|e| CoreError::Invalid(format!("rule {i}: {e}")))?;
            rules.push(rule);
        }
        if rules.len() > 100 {
            return Err(CoreError::Invalid("too many rules (max 100)".into()));
        }
        let st = self.inner.state.lock().unwrap();
        st.store.kv_set(
            "filter_rules",
            &serde_json::to_vec(&rules).unwrap_or_default(),
        )?;
        Ok(json!({"ok": true, "count": rules.len()}))
    }

    /// Rules snapshot for the message pipeline.
    pub fn filter_rules_cached(&self) -> Vec<crate::filter::FilterRule> {
        let st = self.inner.state.lock().unwrap();
        st.store
            .kv_get("filter_rules")
            .ok()
            .flatten()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    fn set_active_group(&self, p: Json) -> Result<Json> {
        let gid = p.get("group_id").and_then(|v| v.as_str()).map(String::from);
        *self.inner.active_group.write().unwrap() = gid;
        Ok(json!({"ok": true}))
    }

    /// Re-register persisted groups/torrents with the engine after startup.
    fn restore_state(&self) -> Result<()> {
        let own_pk = self.own_pk_hex();
        let mut st = self.inner.state.lock().unwrap();
        // restore DM request inbox + blocklist (persisted as kv JSON)
        if let Ok(Some(raw)) = st.store.kv_get("dm_pending_v1") {
            if let Ok(arr) = serde_json::from_slice::<Vec<Json>>(&raw) {
                for e in arr {
                    let (Some(gid), Some(pk)) = (
                        e["gid"].as_str().map(str::to_string),
                        e["from_pk"].as_str().map(str::to_string),
                    ) else {
                        continue;
                    };
                    st.dm_pending.insert(
                        gid,
                        crate::api::DmPendingReq {
                            from_pk: pk,
                            from_name: e["from_name"].as_str().unwrap_or("").to_string(),
                            from_x: e["from_x"].as_str().unwrap_or("").to_string(),
                            ih: e["ih"].as_str().unwrap_or("").to_string(),
                            ts: e["ts"].as_i64().unwrap_or(0),
                        },
                    );
                }
            }
        }
        if let Ok(Some(raw)) = st.store.kv_get("dm_blocked_v1") {
            if let Ok(arr) = serde_json::from_slice::<Vec<String>>(&raw) {
                st.dm_blocked.extend(arr);
            }
        }
        let torrents: std::collections::HashMap<String, crate::store::TorrentRow> = st
            .store
            .torrents_all()?
            .into_iter()
            .map(|r| (r.infohash.clone(), r))
            .collect();
        let groups = st.store.groups_all()?;
        for row in &groups {
            if row.left {
                continue;
            }
            let gid_hex = hex::encode(row.gid);
            let is_dm = row.manifest.is_dm();
            let swarm_ih = if is_dm {
                // v0.5.2 DM channels have NO torrent of their own — frames
                // ride the swarms of shared rooms. Legacy manifest torrents
                // are deliberately not re-added (history stays local).
                String::new()
            } else if row.manifest.is_torrent_room() {
                // torrent room: the swarm IS the content torrent; the
                // torrents loop below re-adds it (kind=0) with its stored
                // magnet (trackers included)
                gid_hex.clone()
            } else {
                // legacy manifest channel: re-add the internal manifest torrent
                let ih = crate::mock::parse_magnet(&row.magnet)
                    .map(|(ih, _)| ih)
                    .unwrap_or_default();
                if !ih.is_empty() {
                    let save_dir = self.groups_dir().join(&ih);
                    if let Err(e) = self.inner.engine.add_magnet(
                        &row.magnet,
                        &save_dir.to_string_lossy(),
                        Some(crate::MANIFEST_FILE),
                    ) {
                        log::warn!("restore: re-add manifest failed: {e}");
                    }
                }
                ih
            };
            if !is_dm && swarm_ih.is_empty() {
                continue;
            }
            if row.manifest.is_torrent_room() && !torrents.contains_key(&swarm_ih) {
                // group without a registry row (shouldn't happen): add anyway
                let save_dir = self.downloads_dir().join(&swarm_ih);
                let _ = self.inner.engine.add_magnet(
                    &row.magnet,
                    &save_dir.to_string_lossy(),
                    Some(&row.name),
                );
            }
            if !swarm_ih.is_empty() {
                st.by_ih.insert(swarm_ih.clone(), gid_hex.clone());
            }
            let dag = crate::chat::sync::rebuild_dag(&st.store, &row.gid, &own_pk)?;
            let own_seq = dag.author_seq(&own_pk);
            let mut sync = GroupSync::new(row.gid, row.manifest.clone(), row.head_seq, swarm_ih);
            sync.dag = dag;
            st.groups.insert(
                gid_hex,
                GroupRuntime {
                    sync,
                    row: row.clone(),
                    own_seq,
                    last_publish: 0,
                    pending_dm_req: None,
                },
            );
        }
        for t in torrents.values() {
            if t.kind == 1 {
                continue; // manifest torrents handled above
            }
            let save_dir = if t.save_path.is_empty() {
                self.downloads_dir()
                    .join(&t.infohash)
                    .to_string_lossy()
                    .to_string()
            } else {
                t.save_path.clone()
            };
            if !t.magnet.is_empty() {
                let _ = self
                    .inner
                    .engine
                    .add_magnet(&t.magnet, &save_dir, Some(&t.name));
            }
        }
        Ok(())
    }

    fn apply_persisted_limits(&self) {
        let st = self.inner.state.lock().unwrap();
        let raw = st.store.kv_get("limits").ok().flatten();
        drop(st);
        if let Some(raw) = raw {
            if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&raw) {
                let up = v.get("up").and_then(|x| x.as_i64()).unwrap_or(0);
                let down = v.get("down").and_then(|x| x.as_i64()).unwrap_or(0);
                let _ = self.inner.engine.set_limits(up, down);
            }
        }
    }

    /// Kick the join pipeline for a manifest torrent that just got metadata.
    /// Called from the event loop; safe to call repeatedly. Only DM/legacy
    /// manifest channels use the pending-join pipeline — torrent rooms bind
    /// synchronously in `enter_torrent_room`.
    pub fn try_complete_join(&self, ih_hex: &str) {
        let save_dir = {
            let st = self.inner.state.lock().unwrap();
            match st.pending_joins.get(ih_hex) {
                Some(d) => d.clone(),
                None => return,
            }
        };
        let mf = save_dir.join(crate::MANIFEST_FILE);
        let Ok(bytes) = std::fs::read(&mf) else {
            return;
        };
        let manifest = match crate::chat::GroupManifest::decode(&bytes) {
            Ok(m) => m,
            Err(e) => {
                log::warn!("bad manifest in {ih_hex}: {e}");
                Api::emit_from(
                    &self.inner,
                    "sys.log",
                    json!({"level": "warn", "msg": format!("无效的群清单: {e}")}),
                );
                return;
            }
        };
        self.complete_join(ih_hex, save_dir, manifest);
    }

    fn complete_join(&self, ih_hex: &str, save_dir: PathBuf, manifest: crate::chat::GroupManifest) {
        let own_pk = self.own_pk_hex();
        let gid_hex = hex::encode(manifest.gid);
        let now = crate::now_ms();
        let (row, existed) = {
            let mut st = self.inner.state.lock().unwrap();
            st.pending_joins.remove(ih_hex);
            if st.groups.contains_key(&gid_hex) {
                // runtime already exists (restart with manifest on disk)
                let row = st.groups[&gid_hex].row.clone();
                st.by_ih.insert(ih_hex.to_string(), gid_hex.clone());
                (row, true)
            } else {
                let existing = st.store.group_get(&manifest.gid).ok().flatten();
                let row = match existing {
                    Some(mut r) => {
                        r.left = false;
                        r.magnet = st
                            .store
                            .torrents_all()
                            .ok()
                            .unwrap_or_default()
                            .into_iter()
                            .find(|t| t.infohash == ih_hex)
                            .map(|t| t.magnet)
                            .unwrap_or(r.magnet);
                        st.store.group_set_left(&manifest.gid, false).ok();
                        r
                    }
                    None => GroupRow {
                        gid: manifest.gid,
                        name: manifest.name.clone(),
                        avatar: manifest.avatar.clone(),
                        magnet: format!(
                            "magnet:?xt=urn:btih:{ih_hex}&dn={}",
                            crate::api::chat::urlquery(crate::MANIFEST_FILE)
                        ),
                        manifest: manifest.clone(),
                        head_seq: 0,
                        created: manifest.created,
                        joined: now,
                        last_read_ts: now,
                        left: false,
                    },
                };
                st.store.group_upsert(&row).ok();
                st.store
                    .torrent_upsert(&crate::store::TorrentRow {
                        infohash: ih_hex.to_string(),
                        name: crate::MANIFEST_FILE.to_string(),
                        magnet: row.magnet.clone(),
                        save_path: save_dir.to_string_lossy().to_string(),
                        kind: 1,
                        group_id: Some(manifest.gid),
                        added: now,
                    })
                    .ok();
                let dag = crate::chat::sync::rebuild_dag(&st.store, &manifest.gid, &own_pk)
                    .unwrap_or_default();
                let own_seq = dag.author_seq(&own_pk);
                let mut sync = GroupSync::new(
                    manifest.gid,
                    manifest.clone(),
                    row.head_seq,
                    ih_hex.to_string(),
                );
                sync.dag = dag;
                sync.dirty_heads = false;
                st.groups.insert(
                    gid_hex.clone(),
                    GroupRuntime {
                        sync,
                        row: row.clone(),
                        own_seq,
                        last_publish: 0,
                        pending_dm_req: None,
                    },
                );
                st.by_ih.insert(ih_hex.to_string(), gid_hex.clone());
                (row, false)
            }
        };
        // announce ourselves with a signed system message (git-like log)
        if !existed {
            self.send_system_message(&gid_hex, "join", "");
        }
        // kick sync outside the lock
        self.kick_group_sync(&gid_hex);
        Api::emit_from(
            &self.inner,
            if existed {
                "chat.group_restored"
            } else {
                "chat.group_joined"
            },
            json!({"group": chat::group_summary_from_row(&row)}),
        );
    }

    /// Torrent metadata arrived: adopt the real torrent name for its chat
    /// room (unless the user renamed the room — then only the internal
    /// "auto name" tracker in the manifest is updated).
    pub fn refresh_torrent_group_name(&self, ih_hex: &str) {
        let eng_name = self
            .inner
            .engine
            .torrent_states()
            .ok()
            .and_then(|v| v.into_iter().find(|s| s.infohash == ih_hex).map(|s| s.name))
            .unwrap_or_default();
        let eng_name = eng_name.trim().to_string();
        if eng_name.is_empty()
            || (eng_name.len() == 40
                && eng_name.chars().all(|c| c.is_ascii_hexdigit())
                && eng_name.eq_ignore_ascii_case(ih_hex))
        {
            return;
        }
        let eng_name = crate::chat::group::clamp_name(&eng_name);
        let mut changed = false;
        {
            let mut guard = self.inner.state.lock().unwrap();
            // reborrow as &mut CoreState so groups/store field borrows stay
            // disjoint (the guard's Deref would otherwise borrow it whole)
            let st = &mut *guard;
            let Some(rt) = st.groups.get_mut(ih_hex) else {
                return;
            };
            if !rt.sync.manifest.is_torrent_room() {
                return;
            }
            // rename ingest only updates the store — sync the runtime row
            // so the rename is not clobbered by the auto-name below
            if let Ok(Some(stored)) = st.store.group_get(&rt.sync.gid) {
                rt.row.name = stored.name;
            }
            let auto = rt.sync.manifest.name.clone();
            if auto == eng_name && rt.row.name == eng_name {
                return;
            }
            rt.sync.manifest.name = eng_name.clone();
            if rt.row.name == auto || rt.row.name.is_empty() {
                rt.row.name = eng_name.clone();
                changed = true;
            }
            // keep the persisted copy in sync, then persist
            rt.row.manifest = rt.sync.manifest.clone();
            if let Err(e) = st.store.group_upsert(&rt.row) {
                log::warn!("name refresh persist failed: {e}");
            }
            // keep the BT registry name in sync when it is still a placeholder
            if let Ok(Some(trow)) = st.store.torrent_get(ih_hex) {
                let n = trow.name.trim();
                let placeholder = n.is_empty()
                    || (n.len() == 40
                        && n.chars().all(|c| c.is_ascii_hexdigit())
                        && n.eq_ignore_ascii_case(ih_hex));
                if placeholder {
                    let _ = st.store.torrent_set_name(ih_hex, &eng_name);
                }
            }
        }
        if changed {
            Api::emit_from(
                &self.inner,
                "chat.group_updated",
                serde_json::json!({"group": ih_hex}),
            );
        }
    }

    /// Create + broadcast a y=3 system message (join/leave/rename...).
    pub fn send_system_message(&self, gid_hex: &str, code: &str, detail: &str) {
        let gid = match crate::api::hex20(gid_hex) {
            Ok(g) => g,
            Err(_) => return,
        };
        let (identity, profile_name) = {
            let id = self.inner.active.read().unwrap().identity.clone();
            let pn = self.inner.active.read().unwrap().name.clone();
            (id, pn)
        };
        let now = crate::now_ms();
        let (sm, is_dm, dm_peer) = {
            let mut guard = self.inner.state.lock().unwrap();
            let st = &mut *guard;
            let Some(rt) = st.groups.get_mut(gid_hex) else {
                return;
            };
            let is_dm = rt.sync.manifest.is_dm();
            let dm_peer = self.dm_peer_pk_hex(&rt.sync.manifest);
            let parents = rt.sync.dag.heads();
            let channel_key = self.dm_channel_key(&rt.sync.manifest);
            rt.own_seq += 1;
            let sm = match crate::chat::message::create_message_opts(
                &gid,
                &parents,
                rt.own_seq,
                now,
                &identity,
                &profile_name,
                crate::chat::message::MsgKind::System,
                &crate::chat::message::Payload::System {
                    code: code.to_string(),
                    detail: detail.to_string(),
                },
                &crate::chat::message::MsgOpts { channel_key },
            ) {
                Ok(sm) => sm,
                Err(e) => {
                    log::warn!("system message failed: {e}");
                    return;
                }
            };
            rt.sync.pending_puts.insert(sm.id);
            if let Err(e) = rt.sync.ingest(&st.store, sm.clone(), 0) {
                log::warn!("system message ingest failed: {e}");
                return;
            }
            st.store.outbox_add(&gid, &sm.id).ok();
            rt.sync.dirty_heads = true;
            (sm, is_dm, dm_peer)
        };
        if is_dm {
            if let Some(pk) = dm_peer {
                let frame = crate::chat::sync::ExtPayload::DmMsg {
                    gid,
                    msg: sm.bytes.clone(),
                }
                .encode();
                let _ = self.dm_deliver_frame(&pk, &frame);
            }
        } else {
            let _ = self.inner.engine.dht_put_immutable(&sm.bytes, &sm.id);
            let mut guard = self.inner.state.lock().unwrap();
            let st = &mut *guard;
            if let Some(rt) = st.groups.get_mut(gid_hex) {
                let payload = crate::chat::sync::ExtPayload::Msg(sm.bytes.clone()).encode();
                let _ = self.inner.engine.ext_send(&rt.sync.swarm_ih, &payload);
                if rt.sync.publish_heads(&st.store, &*self.inner.engine, now) {
                    rt.last_publish = now;
                }
            }
        }
        self.emit_event(
            "chat.message_new",
            serde_json::json!({"group": gid_hex, "message": sm.msg}),
        );
    }

    pub fn kick_group_sync(&self, gid_hex: &str) {
        let mut st = self.inner.state.lock().unwrap();
        if let Some(rt) = st.groups.get_mut(gid_hex) {
            if rt.sync.manifest.is_dm() {
                // DM channels sync over addressed ext frames only (the
                // reconnect handler gap-fills); no DHT heads/objects
                return;
            }
            let now = crate::now_ms();
            rt.sync.poll_heads(&*self.inner.engine, now);
            let backoff = rt.sync.fetch_backoff_table().clone();
            rt.sync
                .pump_fetches_filtered(&*self.inner.engine, &backoff, now);
        }
    }
}

// ---- small helpers shared by submodules --------------------------------

pub fn jstr<'a>(p: &'a Json, key: &str) -> Result<&'a str> {
    p.get(key)
        .and_then(|v| v.as_str())
        .ok_or_else(|| CoreError::Invalid(format!("missing param {key}")))
}

pub fn ji64(p: &Json, key: &str, default: i64) -> i64 {
    p.get(key)
        .and_then(|v| {
            v.as_i64()
                .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
        })
        .unwrap_or(default)
}

pub fn jbool(p: &Json, key: &str, default: bool) -> bool {
    p.get(key).and_then(|v| v.as_bool()).unwrap_or(default)
}

pub fn hex20(s: &str) -> Result<Sha1Hash> {
    let b = hex::decode(s).map_err(|_| CoreError::Invalid("bad hex id".to_string()))?;
    if b.len() != 20 {
        return Err(CoreError::Invalid("bad id length".into()));
    }
    let mut a = [0u8; 20];
    a.copy_from_slice(&b);
    Ok(a)
}

pub fn hex32(s: &str) -> Result<[u8; 32]> {
    let b = hex::decode(s).map_err(|_| CoreError::Invalid("bad hex".to_string()))?;
    if b.len() != 32 {
        return Err(CoreError::Invalid("bad length".into()));
    }
    let mut a = [0u8; 32];
    a.copy_from_slice(&b);
    Ok(a)
}
