//! chat.* JSON methods.

use base64::Engine as _;
use serde_json::{json, Value as Json};

use crate::api::{hex20, jbool, ji64, jstr, Api, GroupRuntime};
use crate::chat::group::{DmParty, GroupManifest};
use crate::chat::message::{
    create_message, create_message_opts, plan_text, AttachmentInfo, MsgKind, MsgOpts, Payload,
};
use crate::chat::sync::ExtPayload;
use crate::crypto::Identity;
use crate::store::{GroupRow, TorrentRow};
use crate::{CoreError, Result, MANIFEST_FILE};

pub fn urlquery(s: &str) -> String {
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

pub fn group_summary_from_row(row: &GroupRow) -> Json {
    json!({
        "group_id": hex::encode(row.gid),
        "name": row.name,
        "avatar_b64": base64::engine::general_purpose::STANDARD.encode(&row.avatar),
        "invite_magnet": row.magnet,
        "created": row.created,
        "joined": row.joined,
        "left": row.left,
        "dm": row.manifest.is_dm(),
    })
}

impl Api {
    fn identity_snapshot(&self) -> (Identity, String) {
        let id = self.inner.identity.read().unwrap().clone();
        let pn = self.inner.profile.read().unwrap().name.clone();
        (id, pn)
    }

    /// Symmetric channel key for a DM manifest (None for plain groups).
    pub fn dm_channel_key(&self, manifest: &GroupManifest) -> Option<[u8; 32]> {
        let (a, b) = manifest.dm.as_ref()?;
        let identity = self.inner.identity.read().unwrap().clone();
        let own_pk = identity.public_key();
        let peer = if a.k == own_pk {
            b
        } else if b.k == own_pk {
            a
        } else {
            return None;
        };
        let xs = crate::crypto::x_secret_from_seed(&identity.seed);
        Some(crate::crypto::channel_key(&xs, &peer.x, &manifest.gid))
    }

    pub fn chat_groups(&self) -> Result<Json> {
        let own_pk = self.own_pk_hex();
        let st = self.inner.state.lock().unwrap();
        let mut out = Vec::new();
        let rows = st.store.groups_all()?;
        for row in rows.iter().filter(|r| !r.left) {
            let gid_hex = hex::encode(row.gid);
            let unread = st
                .store
                .unread_count(&row.gid, row.last_read_ts, &own_pk)
                .unwrap_or(0);
            let last = st.store.last_message_ts(&row.gid).unwrap_or(0);
            let (online, syncing, total, missing) = match st.groups.get(&gid_hex) {
                Some(rt) => {
                    let peers = self
                        .inner
                        .engine
                        .torrent_peers(&rt.sync.swarm_ih)
                        .unwrap_or_default();
                    let p = rt.sync.progress();
                    (
                        peers.iter().filter(|p| p.chat_capable).count() as i64,
                        p.missing > 0 || p.inflight > 0,
                        p.total,
                        p.missing,
                    )
                }
                None => (0, false, 0, 0),
            };
            let preview = self.last_display_message(&st.store, &row.gid, &own_pk);
            let mut j = group_summary_from_row(row);
            j["unread"] = json!(unread);
            j["last_ts"] = json!(last);
            j["online"] = json!(online);
            j["syncing"] = json!(syncing);
            j["messages"] = json!(total);
            j["missing"] = json!(missing);
            j["preview"] = preview;
            out.push(j);
        }
        // most recent activity first
        out.sort_by_key(|g| -(g["last_ts"].as_i64().unwrap_or(0)));
        Ok(json!({"groups": out}))
    }

    fn last_display_message(
        &self,
        store: &crate::store::Store,
        gid: &[u8; 20],
        own_pk: &str,
    ) -> Json {
        let msgs = store.messages_of_group(gid, own_pk).unwrap_or_default();
        if msgs.is_empty() {
            return Json::Null;
        }
        let mut dag = crate::chat::Dag::new();
        for sm in msgs {
            let _ = dag.insert(sm.id, sm.msg, sm.bytes);
        }
        let display = crate::store::Store::display_messages(dag.ordered());
        match display.last() {
            Some(m) => json!({
                "author_name": m.author_name,
                "ts": m.ts,
                "kind": m.kind,
                "text": message_preview(m),
                "own": m.own,
            }),
            None => Json::Null,
        }
    }

    pub fn chat_create_group(&self, p: Json) -> Result<Json> {
        let name = jstr(&p, "name")?.to_string();
        let avatar = p
            .get("avatar_b64")
            .and_then(|v| v.as_str())
            .and_then(|s| base64::engine::general_purpose::STANDARD.decode(s).ok())
            .unwrap_or_default();
        let (identity, profile_name) = self.identity_snapshot();
        let head = Identity::generate();
        let manifest = GroupManifest::new(&name, &profile_name, &identity, &head, avatar)?;
        self.create_channel(manifest)
    }

    /// Start (or fetch) an encrypted DM channel with the author of any
    /// message we have seen (their X25519 key travels in the `x` field).
    pub fn chat_start_dm(&self, p: Json) -> Result<Json> {
        let their_pk_hex = jstr(&p, "author_pk")?.to_string();
        let their_pk = crate::api::hex32(&their_pk_hex)?;
        let identity = self.inner.identity.read().unwrap().clone();
        let own_pk = identity.public_key();
        if their_pk == own_pk {
            return Err(CoreError::Invalid("不能和自己私聊".into()));
        }
        let gid = GroupManifest::dm_gid(&own_pk, &their_pk);
        {
            let st = self.inner.state.lock().unwrap();
            if let Ok(Some(row)) = st.store.group_get(&gid) {
                return Ok(
                    json!({"group_id": hex::encode(gid), "existing": true, "name": row.name}),
                );
            }
        }
        let (their_x_hex, their_name) = {
            let st = self.inner.state.lock().unwrap();
            st.store.message_author_x(&their_pk_hex)?.ok_or_else(|| {
                CoreError::NotFound("还没有对方的密钥信息：先在同群聊里收到 TA 至少一条消息".into())
            })?
        };
        let mut their_x = [0u8; 32];
        their_x.copy_from_slice(&crate::api::hex32(&their_x_hex)?);
        let own_xs = crate::crypto::x_secret_from_seed(&identity.seed);
        let own_x = crate::crypto::x_public(&own_xs);
        let head = Identity::generate();
        let mut manifest =
            GroupManifest::new(&their_name, &self.profile().name, &identity, &head, vec![])?;
        manifest.gid = gid;
        let (a, b) = if own_pk <= their_pk {
            (
                DmParty {
                    k: own_pk,
                    x: own_x,
                },
                DmParty {
                    k: their_pk,
                    x: their_x,
                },
            )
        } else {
            (
                DmParty {
                    k: their_pk,
                    x: their_x,
                },
                DmParty {
                    k: own_pk,
                    x: own_x,
                },
            )
        };
        manifest.dm = Some((a, b));
        let mut r = self.create_channel(manifest.clone())?;
        if let Some(o) = r.as_object_mut() {
            o.insert("dm".to_string(), json!(true));
        }
        // invite the peer through any group we share: the magnet is a
        // capability, message bodies stay E2E encrypted
        let magnet = r
            .get("invite_magnet")
            .and_then(|m| m.as_str())
            .unwrap_or_default()
            .to_string();
        let shared = {
            let st = self.inner.state.lock().unwrap();
            st.store.message_group_of_author(&their_pk_hex)?
        };
        if let Some(gid) = shared {
            self.send_system_message(
                &hex::encode(gid),
                "dm_invite",
                &format!("{their_pk_hex} {magnet}"),
            );
        }
        Ok(r)
    }

    /// Shared pipeline: persist manifest torrent, register runtime, genesis.
    fn create_channel(&self, manifest: GroupManifest) -> Result<Json> {
        let (identity, profile_name) = self.identity_snapshot();
        let gid_hex = hex::encode(manifest.gid);
        let now = crate::now_ms();

        let staging = self.groups_dir().join(format!("_new_{}", &gid_hex[..8]));
        std::fs::create_dir_all(&staging)?;
        let mf = staging.join(crate::MANIFEST_FILE);
        std::fs::write(&mf, manifest.encode())?;
        let created = self
            .inner
            .engine
            .create_torrent(&mf.to_string_lossy(), "BitteChat group manifest")?;
        let ih_hex = hex::encode(created.infohash);
        let final_dir = self.groups_dir().join(&ih_hex);
        if final_dir.exists() {
            let _ = std::fs::remove_dir_all(&final_dir);
        }
        std::fs::rename(&staging, &final_dir)
            .map_err(|e| CoreError::Internal(format!("staging rename failed: {e}")))?;
        self.inner
            .engine
            .add_torrent_bytes(&created.torrent_bytes, &final_dir.to_string_lossy())?;

        let magnet = created.magnet.clone();
        let row = GroupRow {
            gid: manifest.gid,
            name: manifest.name.clone(),
            avatar: manifest.avatar.clone(),
            magnet: magnet.clone(),
            manifest: manifest.clone(),
            head_seq: 0,
            created: now,
            joined: now,
            last_read_ts: now,
            left: false,
        };

        let channel_key = self.dm_channel_key(&manifest);
        let genesis = crate::chat::message::create_message_opts(
            &manifest.gid,
            &[],
            1,
            now,
            &identity,
            &profile_name,
            MsgKind::System,
            &Payload::System {
                code: "create".into(),
                detail: manifest.name.clone(),
            },
            &crate::chat::message::MsgOpts { channel_key },
        )?;
        let genesis_id = genesis.id;

        {
            let mut st = self.inner.state.lock().unwrap();
            st.store.group_upsert(&row)?;
            st.store.torrent_upsert(&crate::store::TorrentRow {
                infohash: ih_hex.clone(),
                name: format!("清单·{}", manifest.name),
                magnet: magnet.clone(),
                save_path: final_dir.to_string_lossy().to_string(),
                kind: 1,
                group_id: Some(manifest.gid),
                added: now,
            })?;
            let mut sync = crate::chat::sync::GroupSync::new(
                manifest.gid,
                manifest.clone(),
                0,
                ih_hex.clone(),
            );
            sync.pending_puts.insert(genesis_id);
            sync.ingest(&st.store, genesis.clone(), 0)?;
            st.store.outbox_add(&manifest.gid, &genesis_id)?;
            st.by_ih.insert(ih_hex.clone(), gid_hex.clone());
            st.groups.insert(
                gid_hex.clone(),
                GroupRuntime {
                    sync,
                    row: row.clone(),
                    own_seq: 1,
                    last_publish: 0,
                },
            );
        }

        let _ = self
            .inner
            .engine
            .dht_put_immutable(&genesis.bytes, &genesis.id);
        {
            let mut guard = self.inner.state.lock().unwrap();
            let st = &mut *guard;
            if let Some(rt) = st.groups.get_mut(&gid_hex) {
                if rt.sync.publish_heads(&st.store, &*self.inner.engine, now) {
                    rt.last_publish = now;
                }
                rt.sync.ext_announce_heads(&*self.inner.engine);
            }
        }
        self.emit_event(
            "chat.message_new",
            json!({"group": gid_hex, "message": genesis.msg}),
        );
        self.emit_event(
            "chat.group_joined",
            json!({"group": group_summary_from_row(&row)}),
        );

        Ok(json!({
            "group_id": gid_hex,
            "invite_magnet": magnet,
            "manifest_infohash": ih_hex,
            "genesis": hex::encode(genesis_id),
        }))
    }

    pub fn chat_join_group(&self, p: Json) -> Result<Json> {
        let magnet = jstr(&p, "magnet")?.trim().to_string();
        let (ih_hex, _dn) = crate::mock::parse_magnet(&magnet)?;
        let now = crate::now_ms();
        {
            let st = self.inner.state.lock().unwrap();
            if let Some(gid) = st.by_ih.get(&ih_hex) {
                return Ok(json!({"group_id": gid, "already": true}));
            }
            if let Ok(Some(row)) = st.store.group_by_magnet_ih(&ih_hex) {
                return Ok(json!({"group_id": hex::encode(row.gid), "already": true}));
            }
        }
        let save_dir = self.groups_dir().join(&ih_hex);
        std::fs::create_dir_all(&save_dir)?;
        {
            let mut st = self.inner.state.lock().unwrap();
            st.pending_joins.insert(ih_hex.clone(), save_dir.clone());
            st.store.torrent_upsert(&TorrentRow {
                infohash: ih_hex.clone(),
                name: "群聊清单(加入中)".into(),
                magnet: magnet.clone(),
                save_path: save_dir.to_string_lossy().to_string(),
                kind: 1,
                group_id: None,
                added: now,
            })?;
        }
        self.inner
            .engine
            .add_magnet(&magnet, &save_dir.to_string_lossy(), Some(MANIFEST_FILE))?;
        // in case the manifest is already on disk (re-join), try immediately
        self.try_complete_join(&ih_hex);
        Ok(json!({"pending": true, "infohash": ih_hex}))
    }

    pub fn chat_leave_group(&self, p: Json) -> Result<Json> {
        let gid_hex = jstr(&p, "group_id")?.to_string();
        let delete_history = jbool(&p, "delete_history", false);
        let gid = hex20(&gid_hex)?;
        // best-effort farewell message while we are still a member
        self.send_system_message(&gid_hex, "leave", "");
        let mut st = self.inner.state.lock().unwrap();
        let ih = st
            .groups
            .get(&gid_hex)
            .map(|rt| rt.sync.swarm_ih.clone())
            .unwrap_or_default();
        if !ih.is_empty() {
            let _ = st.store.torrent_remove(&ih);
            let _ = self.inner.engine.remove_torrent(&ih, true);
            st.by_ih.remove(&ih);
        }
        if delete_history {
            st.store.group_purge(&gid)?;
        }
        st.store.group_set_left(&gid, true)?;
        st.groups.remove(&gid_hex);
        Ok(json!({"ok": true}))
    }

    pub fn chat_messages(&self, p: Json) -> Result<Json> {
        let gid_hex = jstr(&p, "group_id")?.to_string();
        let limit = ji64(&p, "limit", 200).clamp(1, 2000);
        let own_pk = self.own_pk_hex();
        let st = self.inner.state.lock().unwrap();
        let gid = hex20(&gid_hex)?;
        let msgs = st.store.messages_of_group(&gid, &own_pk)?;
        let mut dag = crate::chat::Dag::new();
        for sm in msgs {
            let _ = dag.insert(sm.id, sm.msg, sm.bytes);
        }
        let mut display = crate::store::Store::display_messages(dag.ordered());
        // decrypt DM payloads
        if let Some(rt) = st.groups.get(&gid_hex) {
            if let Some(key) = self.dm_channel_key(&rt.sync.manifest) {
                for m in display.iter_mut() {
                    if let Payload::Sealed { sealed_b64 } = &m.payload {
                        let opened =
                            crate::chat::message::open_dm_payload(&key, m.author_seq, sealed_b64);
                        match opened {
                            Some((kind_i, payload)) => {
                                m.kind = kind_i;
                                m.payload = payload;
                            }
                            None => {
                                m.payload = Payload::System {
                                    code: "sealed".into(),
                                    detail: "解密失败（密钥不匹配？）".into(),
                                };
                            }
                        }
                    }
                }
            }
        }
        let total = display.len();
        let from = (total as i64 - limit).max(0) as usize;
        display.drain(0..from);
        let downloads = self.downloads_dir();
        let states = self
            .inner
            .engine
            .torrent_states()
            .unwrap_or_default()
            .into_iter()
            .map(|s| (s.infohash.clone(), s))
            .collect::<std::collections::HashMap<_, _>>();
        let items: Vec<Json> = display
            .iter()
            .map(|m| {
                let mut j = serde_json::to_value(m).unwrap_or(json!({}));
                if let Payload::Attachment(a) = &m.payload {
                    let path = downloads.join(&a.infohash).join(&a.name);
                    j["local_path"] = json!(path.to_string_lossy());
                    j["have_file"] = json!(path.exists());
                    if let Some(s) = states.get(&a.infohash) {
                        j["dl"] = json!({
                            "progress": s.progress,
                            "finished": s.finished,
                            "paused": s.paused,
                            "rate": s.download_rate,
                            "peers": s.num_peers,
                            "state": s.state,
                        });
                    }
                }
                j
            })
            .collect();
        Ok(json!({"messages": items, "total": total}))
    }

    pub fn chat_send(&self, p: Json) -> Result<Json> {
        let gid_hex = jstr(&p, "group_id")?.to_string();
        let text = jstr(&p, "text")?.to_string();
        if text.trim().is_empty() || text.len() > 32 * 1024 {
            return Err(CoreError::Invalid("empty or too long text".into()));
        }
        let (identity, profile_name) = self.identity_snapshot();
        let gid = hex20(&gid_hex)?;
        let now = crate::now_ms();
        let parts = plan_text(&text);

        let mut created = Vec::new();
        let swarm_ih;
        {
            let mut guard = self.inner.state.lock().unwrap();
            let st = &mut *guard;
            let rt = st
                .groups
                .get_mut(&gid_hex)
                .ok_or_else(|| CoreError::NotFound("group".into()))?;
            swarm_ih = rt.sync.swarm_ih.clone();
            let channel_key = self.dm_channel_key(&rt.sync.manifest);
            let mut parents = rt.sync.dag.heads();
            for (i, (kind, payload)) in parts.into_iter().enumerate() {
                rt.own_seq += 1;
                let sm = create_message_opts(
                    &gid,
                    &parents,
                    rt.own_seq,
                    now + i as i64,
                    &identity,
                    &profile_name,
                    kind,
                    &payload,
                    &crate::chat::message::MsgOpts { channel_key },
                )?;
                rt.sync.pending_puts.insert(sm.id);
                rt.sync.ingest(&st.store, sm.clone(), 0)?;
                st.store.outbox_add(&gid, &sm.id)?;
                parents = vec![sm.id];
                created.push(sm);
            }
            rt.sync.dirty_heads = true;
        }

        // network side effects outside the state lock
        let mut ids = Vec::new();
        for sm in &created {
            let _ = self.inner.engine.dht_put_immutable(&sm.bytes, &sm.id);
            let payload = ExtPayload::Msg(sm.bytes.clone()).encode();
            let _ = self.inner.engine.ext_send(&swarm_ih, &payload);
            ids.push(sm.msg.id.clone());
            self.emit_event(
                "chat.message_new",
                json!({"group": gid_hex, "message": sm.msg}),
            );
        }
        {
            let mut guard = self.inner.state.lock().unwrap();
            let st = &mut *guard;
            if let Some(rt) = st.groups.get_mut(&gid_hex) {
                if rt.sync.publish_heads(&st.store, &*self.inner.engine, now) {
                    rt.last_publish = now;
                }
                rt.sync.ext_announce_heads(&*self.inner.engine);
            }
        }
        self.emit_event("chat.group_updated", json!({"group": gid_hex}));
        Ok(json!({"ids": ids}))
    }

    pub fn chat_send_file(&self, p: Json) -> Result<Json> {
        let gid_hex = jstr(&p, "group_id")?.to_string();
        let path = jstr(&p, "path")?.to_string();
        let display_name = p
            .get("name")
            .and_then(|v| v.as_str())
            .map(String::from)
            .unwrap_or_else(|| {
                std::path::Path::new(&path)
                    .file_name()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_else(|| "file".into())
            });
        let mime = p
            .get("mime")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let src = std::path::Path::new(&path);
        if !src.exists() {
            return Err(CoreError::NotFound(format!("file {path}")));
        }
        let size = std::fs::metadata(src)?.len() as i64;
        if size <= 0 || size > 4 * 1024 * 1024 * 1024 {
            return Err(CoreError::Invalid(
                "file size out of range (1B..4GB)".into(),
            ));
        }

        let (identity, profile_name) = {
            let id = self.inner.identity.read().unwrap().clone();
            let pn = self.inner.profile.read().unwrap().name.clone();
            (id, pn)
        };
        let gid = hex20(&gid_hex)?;
        let now = crate::now_ms();

        if !src.is_file() {
            return Err(CoreError::Invalid("only single files are supported".into()));
        }
        {
            let st = self.inner.state.lock().unwrap();
            if !st.groups.contains_key(&gid_hex) {
                return Err(CoreError::NotFound("group".into()));
            }
        }
        // create the torrent from the source file (content-addressed), then
        // copy it into the canonical downloads/<ih>/<original name> layout so
        // we seed exactly what recipients will download
        let created = self
            .inner
            .engine
            .create_torrent(&path, "BitteChat attachment")?;
        let ih_hex = hex::encode(created.infohash);
        let orig_name = src
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| display_name.clone());
        let dest_dir = self.downloads_dir().join(&ih_hex);
        std::fs::create_dir_all(&dest_dir)?;
        let dest = dest_dir.join(&orig_name);
        std::fs::copy(src, &dest)?;
        self.inner
            .engine
            .add_torrent_bytes(&created.torrent_bytes, &dest_dir.to_string_lossy())?;

        let att = Payload::Attachment(AttachmentInfo {
            infohash: ih_hex.clone(),
            name: display_name.clone(),
            size,
            mime,
        });
        let sm = {
            let mut guard = self.inner.state.lock().unwrap();
            let st = &mut *guard;
            st.store.torrent_upsert(&TorrentRow {
                infohash: ih_hex.clone(),
                name: display_name.clone(),
                magnet: created.magnet.clone(),
                save_path: dest_dir.to_string_lossy().to_string(),
                kind: 2,
                group_id: Some(gid),
                added: now,
            })?;
            let rt = st
                .groups
                .get_mut(&gid_hex)
                .ok_or_else(|| CoreError::NotFound("group".into()))?;
            let parents = rt.sync.dag.heads();
            let channel_key = self.dm_channel_key(&rt.sync.manifest);
            rt.own_seq += 1;
            let sm = create_message_opts(
                &gid,
                &parents,
                rt.own_seq,
                now,
                &identity,
                &profile_name,
                MsgKind::Attachment,
                &att,
                &MsgOpts { channel_key },
            )?;
            rt.sync.pending_puts.insert(sm.id);
            rt.sync.ingest(&st.store, sm.clone(), 0)?;
            st.store.outbox_add(&gid, &sm.id)?;
            rt.sync.dirty_heads = true;
            sm
        };
        let _ = self.inner.engine.dht_put_immutable(&sm.bytes, &sm.id);
        {
            let mut guard = self.inner.state.lock().unwrap();
            let st = &mut *guard;
            if let Some(rt) = st.groups.get_mut(&gid_hex) {
                let payload = ExtPayload::Msg(sm.bytes.clone()).encode();
                let _ = self.inner.engine.ext_send(&rt.sync.swarm_ih, &payload);
                if rt.sync.publish_heads(&st.store, &*self.inner.engine, now) {
                    rt.last_publish = now;
                }
                rt.sync.ext_announce_heads(&*self.inner.engine);
            }
        }
        self.emit_event(
            "chat.message_new",
            json!({"group": gid_hex, "message": sm.msg}),
        );
        self.emit_event("chat.group_updated", json!({"group": gid_hex}));
        Ok(json!({
            "id": sm.msg.id,
            "infohash": ih_hex,
            "magnet": created.magnet,
        }))
    }

    pub fn chat_rename_group(&self, p: Json) -> Result<Json> {
        let gid_hex = jstr(&p, "group_id")?.to_string();
        let name = jstr(&p, "name")?.trim().to_string();
        if name.is_empty() || name.len() > crate::chat::group::MAX_GROUP_NAME_LEN {
            return Err(CoreError::Invalid("群名长度需在 1..96 字节".into()));
        }
        // local immediate update; peers converge via the signed system msg
        {
            let mut st = self.inner.state.lock().unwrap();
            let gid = hex20(&gid_hex)?;
            st.store.group_set_name(&gid, &name)?;
            if let Some(rt) = st.groups.get_mut(&gid_hex) {
                rt.row.name = name.clone();
            }
        }
        self.send_system_message(&gid_hex, "rename", &name);
        self.emit_event("chat.group_updated", json!({"group": gid_hex}));
        Ok(json!({"ok": true, "name": name}))
    }

    /// Download a chat attachment through the internal (hidden) torrent
    /// registry so chat traffic never pollutes the BT page.
    pub fn chat_download_attachment(&self, p: Json) -> Result<Json> {
        let gid_hex = jstr(&p, "group_id")?.to_string();
        let msg_id_hex = jstr(&p, "msg_id")?;
        let gid = hex20(&gid_hex)?;
        let msg_id = hex20(msg_id_hex)?;
        let own_pk = self.own_pk_hex();
        let (ih_hex, name) = {
            let st = self.inner.state.lock().unwrap();
            let raw = st
                .store
                .message_get_raw(&msg_id)?
                .ok_or_else(|| CoreError::NotFound("message".into()))?;
            let sm = crate::chat::message::parse_message_unverified(&raw, &own_pk)?;
            match sm.msg.payload {
                crate::chat::message::Payload::Attachment(a) => (a.infohash, a.name),
                _ => return Err(CoreError::Invalid("message has no attachment".into())),
            }
        };
        // already known to the engine?
        let existing = self
            .inner
            .engine
            .torrent_states()?
            .into_iter()
            .any(|s| s.infohash == ih_hex);
        if !existing {
            let save_dir = self.downloads_dir().join(&ih_hex);
            std::fs::create_dir_all(&save_dir)?;
            let magnet = format!("magnet:?xt=urn:btih:{ih_hex}&dn={}", urlquery(&name));
            self.inner
                .engine
                .add_magnet(&magnet, &save_dir.to_string_lossy(), Some(&name))?;
        }
        {
            let st = self.inner.state.lock().unwrap();
            st.store.torrent_upsert(&crate::store::TorrentRow {
                infohash: ih_hex.clone(),
                name: name.clone(),
                magnet: format!("magnet:?xt=urn:btih:{ih_hex}"),
                save_path: self
                    .downloads_dir()
                    .join(&ih_hex)
                    .to_string_lossy()
                    .to_string(),
                kind: 2,
                group_id: Some(gid),
                added: crate::now_ms(),
            })?;
        }
        self.emit_event("chat.group_updated", json!({"group": gid_hex}));
        Ok(json!({"infohash": ih_hex, "name": name}))
    }

    pub fn chat_mark_read(&self, p: Json) -> Result<Json> {
        let gid_hex = jstr(&p, "group_id")?.to_string();
        let gid = hex20(&gid_hex)?;
        let now = crate::now_ms();
        let mut st = self.inner.state.lock().unwrap();
        st.store.group_set_last_read(&gid, now)?;
        if let Some(rt) = st.groups.get_mut(&gid_hex) {
            rt.row.last_read_ts = now;
        }
        Ok(json!({"ok": true}))
    }

    pub fn chat_sync(&self, p: Json) -> Result<Json> {
        let gid_hex = jstr(&p, "group_id")?.to_string();
        self.kick_group_sync(&gid_hex);
        let st = self.inner.state.lock().unwrap();
        let rt = st
            .groups
            .get(&gid_hex)
            .ok_or_else(|| CoreError::NotFound("group".into()))?;
        Ok(serde_json::to_value(rt.sync.progress()).unwrap_or(json!({})))
    }

    pub fn chat_group_detail(&self, p: Json) -> Result<Json> {
        let gid_hex = jstr(&p, "group_id")?.to_string();
        let st = self.inner.state.lock().unwrap();
        let rt = st
            .groups
            .get(&gid_hex)
            .ok_or_else(|| CoreError::NotFound("group".into()))?;
        let peers = self
            .inner
            .engine
            .torrent_peers(&rt.sync.swarm_ih)
            .unwrap_or_default();
        let m = &rt.sync.manifest;
        Ok(json!({
            "group": group_summary_from_row(&rt.row),
            "creator": {
                "pk": hex::encode(m.creator_pk),
                "name": m.creator_name,
            },
            "created": m.created,
            "manifest_infohash": rt.sync.swarm_ih,
            "head_seq": rt.sync.head_seq,
            "heads": rt.sync.dag.heads().iter().map(hex::encode).collect::<Vec<_>>(),
            "messages": rt.sync.dag.len(),
            "missing": rt.sync.dag.missing_count(),
            "peers": peers,
        }))
    }
}

fn message_preview(m: &crate::chat::ChatMessage) -> String {
    match &m.payload {
        Payload::Text { text } => text.chars().take(80).collect(),
        Payload::Attachment(a) => format!("[文件] {}", a.name),
        Payload::System { code, detail } => match code.as_str() {
            "create" => format!("创建了群聊「{detail}」"),
            "dm_invite" => "发来了私聊邀请（自动加入）".into(),
            "join" => "加入了群聊".into(),
            "leave" => "退出了群聊".into(),
            _ => format!("[系统] {code}"),
        },
        Payload::Chunk { .. } => "[消息片段]".into(),
        Payload::Sealed { .. } => "[端到端加密消息]".into(),
    }
}

/// Helper used by the event loop: attach group name to a raw ChatMessage json.
pub fn message_json(m: &crate::chat::ChatMessage) -> Json {
    serde_json::to_value(m).unwrap_or(json!({}))
}
