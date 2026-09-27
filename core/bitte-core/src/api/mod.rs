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

use serde::{Deserialize, Serialize};
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

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Profile {
    pub name: String,
    #[serde(default)]
    pub avatar_b64: String,
}

pub struct GroupRuntime {
    pub sync: GroupSync,
    pub row: GroupRow,
    /// next sequence number for our own messages in this group
    pub own_seq: i64,
    pub last_publish: i64,
}

pub struct CoreState {
    pub store: Store,
    pub groups: HashMap<String, GroupRuntime>,
    /// manifest-torrent infohash (hex) -> group id (hex)
    pub by_ih: HashMap<String, String>,
    /// pending joins: manifest infohash -> save dir
    pub pending_joins: HashMap<String, PathBuf>,
}

pub struct Inner {
    pub data_dir: PathBuf,
    pub engine: Arc<dyn BtEngine>,
    pub state: Mutex<CoreState>,
    pub identity: RwLock<Identity>,
    pub profile: RwLock<Profile>,
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

        // identity bootstrap
        let identity = match store.kv_get("identity_seed")? {
            Some(seed) if seed.len() == 32 => {
                let mut s = [0u8; 32];
                s.copy_from_slice(&seed);
                Identity::from_seed(s)
            }
            _ => {
                let id = Identity::generate();
                store.kv_set("identity_seed", &id.seed)?;
                id
            }
        };
        let mut profile: Profile = match store.kv_get("profile")? {
            Some(b) => serde_json::from_slice(&b).unwrap_or_default(),
            None => Profile::default(),
        };
        if profile.name.is_empty() {
            let pk = identity.public_key();
            profile.name = format!("旅人-{}", hex::encode(pk)[..4].to_uppercase());
            store.kv_set("profile", &serde_json::to_vec(&profile).unwrap_or_default())?;
        }

        let (emit, events) = channel::<String>();
        let inner = Arc::new(Inner {
            data_dir,
            engine,
            state: Mutex::new(CoreState {
                store,
                groups: HashMap::new(),
                by_ih: HashMap::new(),
                pending_joins: HashMap::new(),
            }),
            identity: RwLock::new(identity),
            profile: RwLock::new(profile),
            emit,
            active_group: RwLock::new(None),
            shutdown: RwLock::new(false),
        });
        let api = Api { inner };
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
        self.inner.data_dir.join("downloads")
    }

    pub fn own_pk_hex(&self) -> String {
        hex::encode(self.inner.identity.read().unwrap().public_key())
    }

    pub fn profile(&self) -> Profile {
        self.inner.profile.read().unwrap().clone()
    }

    /// Main JSON entry point.
    pub fn dispatch(&self, method: &str, params: Json) -> Result<Json> {
        let p = params;
        match method {
            "sys.info" => self.sys_info(),
            "sys.identity.get" => self.identity_get(),
            "sys.identity.set" => self.identity_set(p),
            "sys.set_active_group" => self.set_active_group(p),

            "bt.add" => self.bt_add(p),
            "bt.add_file" => self.bt_add_file(p),
            "bt.create_seed" => self.bt_create_seed(p),
            "bt.list" => self.bt_list(),
            "bt.control" => self.bt_control(p),
            "bt.files" => self.bt_files(p),
            "bt.file_priorities" => self.bt_file_priorities(p),
            "bt.peers" => self.bt_peers(p),
            "bt.stats" => self.bt_stats(),

            "chat.groups" => self.chat_groups(),
            "chat.create_group" => self.chat_create_group(p),
            "chat.join_group" => self.chat_join_group(p),
            "chat.leave_group" => self.chat_leave_group(p),
            "chat.messages" => self.chat_messages(p),
            "chat.send" => self.chat_send(p),
            "chat.send_file" => self.chat_send_file(p),
            "chat.mark_read" => self.chat_mark_read(p),
            "chat.sync" => self.chat_sync(p),
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
        let p = self.profile();
        Ok(json!({
            "name": p.name,
            "avatar_b64": p.avatar_b64,
            "pk": self.own_pk_hex(),
        }))
    }

    fn identity_set(&self, p: Json) -> Result<Json> {
        let new_profile = {
            let mut prof = self.inner.profile.write().unwrap();
            if let Some(n) = p.get("name").and_then(|v| v.as_str()) {
                let n = n.trim();
                if n.is_empty() || n.chars().count() > 32 {
                    return Err(CoreError::Invalid("name must be 1..32 chars".into()));
                }
                prof.name = n.to_string();
            }
            if let Some(a) = p.get("avatar_b64").and_then(|v| v.as_str()) {
                if a.len() > 16 * 1024 {
                    return Err(CoreError::Invalid("avatar too large".into()));
                }
                prof.avatar_b64 = a.to_string();
            }
            prof.clone()
        };
        let st = self.inner.state.lock().unwrap();
        st.store.kv_set(
            "profile",
            &serde_json::to_vec(&new_profile).unwrap_or_default(),
        )?;
        Ok(json!({"ok": true}))
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
        let groups = st.store.groups_all()?;
        for row in &groups {
            if row.left {
                continue;
            }
            let gid_hex = hex::encode(row.gid);
            let ih = crate::mock::parse_magnet(&row.magnet)
                .map(|(ih, _)| ih)
                .unwrap_or_default();
            let save_dir = self.groups_dir().join(&ih);
            if !ih.is_empty() {
                if let Err(e) = self.inner.engine.add_magnet(
                    &row.magnet,
                    &save_dir.to_string_lossy(),
                    Some(crate::MANIFEST_FILE),
                ) {
                    log::warn!("restore: re-add manifest failed: {e}");
                }
                // maybe the manifest is already on disk (previous run)
                let mf = save_dir.join(crate::MANIFEST_FILE);
                if mf.exists() {
                    st.pending_joins.insert(ih.clone(), save_dir.clone());
                }
                st.by_ih.insert(ih.clone(), gid_hex.clone());
            }
            let dag = crate::chat::sync::rebuild_dag(&st.store, &row.gid, &own_pk)?;
            let own_seq = dag.author_seq(&own_pk);
            let mut sync = GroupSync::new(row.gid, row.manifest.clone(), row.head_seq, ih);
            sync.dag = dag;
            st.groups.insert(
                gid_hex,
                GroupRuntime {
                    sync,
                    row: row.clone(),
                    own_seq,
                    last_publish: 0,
                },
            );
        }
        for t in st.store.torrents_all()? {
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

    /// Kick the join pipeline for a manifest torrent that just got metadata.
    /// Called from the event loop; safe to call repeatedly.
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
                    },
                );
                st.by_ih.insert(ih_hex.to_string(), gid_hex.clone());
                (row, false)
            }
        };
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

    pub fn kick_group_sync(&self, gid_hex: &str) {
        let mut st = self.inner.state.lock().unwrap();
        if let Some(rt) = st.groups.get_mut(gid_hex) {
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
