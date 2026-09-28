//! chat.* JSON methods.

use base64::Engine as _;
use serde_json::{json, Value as Json};

use crate::api::{hex20, jbool, ji64, jstr, Api, CoreState, GroupRuntime};
use crate::chat::group::{DmParty, GroupManifest};
use crate::chat::message::{create_message_opts, plan_text, AttachmentInfo, MsgKind, Payload};
use crate::chat::sync::{ExtPayload, GroupSync};
use crate::crypto::Identity;
use crate::crypto::{PubKey, Sha1Hash};
use crate::store::{GroupRow, TorrentRow};
use crate::{CoreError, Result};

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
        let a = self.inner.active.read().unwrap();
        (a.identity.clone(), a.name.clone())
    }

    /// Symmetric channel key for a DM manifest (None for plain groups).
    pub fn dm_channel_key(&self, manifest: &GroupManifest) -> Option<[u8; 32]> {
        let (a, b) = manifest.dm.as_ref()?;
        let identity = self.inner.active.read().unwrap().identity.clone();
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
                Some(rt) if rt.sync.manifest.is_dm() => {
                    // DM "online" = the counterparty currently holds a
                    // bc_chat connection to us in ANY shared swarm
                    let peer = self.dm_peer_pk_hex(&rt.sync.manifest);
                    let on = peer
                        .as_ref()
                        .map(|pk| st.presence.get(pk).map(|s| !s.is_empty()).unwrap_or(false))
                        .unwrap_or(false);
                    (if on { 1 } else { 0 }, false, 0, 0)
                }
                Some(rt) => {
                    // connected bc_chat peers of the room's swarm — stable
                    // now that seeder↔seeder links are kept alive
                    let peers = self
                        .inner
                        .engine
                        .ext_peers(&rt.sync.swarm_ih)
                        .unwrap_or_default();
                    let p = rt.sync.progress();
                    (
                        peers.len() as i64,
                        p.missing > 0 || p.inflight > 0,
                        p.total,
                        p.missing,
                    )
                }
                None => (0, false, 0, 0),
            };
            let channel_key = st
                .groups
                .get(&gid_hex)
                .and_then(|rt| self.dm_channel_key(&rt.sync.manifest));
            let preview = self.last_display_message(&st.store, &row.gid, &own_pk, channel_key);
            let mut j = group_summary_from_row(row);
            if row.manifest.is_dm() {
                // UI: "waiting for the peer to accept" chip
                j["awaiting_accept"] = json!(st.dm_awaiting_accept.contains(&gid_hex));
            }
            j["unread"] = json!(unread);
            j["last_ts"] = json!(last);
            j["online"] = json!(online);
            j["syncing"] = json!(syncing);
            j["messages"] = json!(total);
            j["missing"] = json!(missing);
            j["preview"] = preview;
            out.push(j);
        }
        // pending DM requests surface as conversation-list entries with a
        // dm_request flag — the UI renders inline accept/decline/block
        {
            let mut reqs: Vec<Json> = Vec::new();
            for (gid_hex, r) in st.dm_pending.iter() {
                if st.groups.contains_key(gid_hex) {
                    continue; // already established (accept in flight)
                }
                reqs.push(json!({
                    "group_id": gid_hex,
                    "name": r.from_name,
                    "avatar_b64": "",
                    "invite_magnet": "",
                    "created": r.ts,
                    "joined": r.ts,
                    "left": false,
                    "dm": true,
                    "dm_request": true,
                    "peer_pk": r.from_pk,
                    "unread": 1,
                    "last_ts": r.ts,
                    "online": 0,
                    "syncing": false,
                    "messages": 0,
                    "missing": 0,
                    "preview": Json::Null,
                }));
            }
            reqs.sort_by_key(|g| -(g["last_ts"].as_i64().unwrap_or(0)));
            // requests pinned above conversations
            reqs.extend(out);
            out = reqs;
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
        channel_key: Option<[u8; 32]>,
    ) -> Json {
        let msgs = store.messages_of_group(gid, own_pk).unwrap_or_default();
        if msgs.is_empty() {
            return Json::Null;
        }
        let mut dag = crate::chat::Dag::new();
        for sm in msgs {
            let _ = dag.insert(sm.id, sm.msg, sm.bytes);
        }
        let mut display = crate::store::Store::display_messages(dag.ordered());
        // decrypt sealed DM payloads so the conversation list shows a real
        // preview instead of "[端到端加密消息]"
        if let Some(key) = channel_key {
            for m in display.iter_mut() {
                if let Payload::Sealed { sealed_b64 } = &m.payload {
                    if let Some((kind_i, payload)) =
                        crate::chat::message::open_dm_payload(&key, m.author_seq, sealed_b64)
                    {
                        m.kind = kind_i;
                        m.payload = payload;
                    }
                }
            }
        }
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
        // v0.5: groups are torrents now — "creating a group from nothing" is
        // gone. Any torrent (magnet / infohash / .torrent file) is a chat
        // room; see `chat_join_group`. This method is kept only to return a
        // helpful error to older frontends.
        let _ = p;
        Err(CoreError::NotFound(
            "chat.create_group 已移除：一个种子就是一个群聊，请用 chat.join_group 添加种子并进入其群聊".into(),
        ))
    }

    /// Enter the chat room of a torrent (creating the binding if needed).
    ///
    /// Accepts a magnet link, a bare 40-hex infohash or a 32-char base32
    /// infohash. The room id IS the torrent infohash; the torrent stays a
    /// regular, visible BT task — chat rides on its swarm.
    pub fn chat_join_group(&self, p: Json) -> Result<Json> {
        let input = jstr(&p, "magnet")?.trim().to_string();
        let (ih_hex, dn, magnet) = crate::mock::normalize_torrent_input(&input)?;
        self.enter_torrent_room(&ih_hex, dn.as_deref(), &magnet)
    }

    /// Shared room-entry pipeline (chat page add / BT page "enter chat" /
    /// system magnet intent).
    pub fn enter_torrent_room(&self, ih_hex: &str, dn: Option<&str>, magnet: &str) -> Result<Json> {
        let gid = hex20(ih_hex)?;
        let now = crate::now_ms();

        // already an active group? (torrent rooms key by ih; DM/legacy
        // manifest channels key by their manifest torrent ih via by_ih)
        {
            let st = self.inner.state.lock().unwrap();
            if let Some(gid_hex) = st.by_ih.get(ih_hex) {
                if st.groups.contains_key(gid_hex) {
                    if let Ok(h20) = hex20(gid_hex) {
                        if let Ok(Some(row)) = st.store.group_get(&h20) {
                            return Ok(json!({
                                "group_id": gid_hex,
                                "already": true,
                                "dm": row.manifest.is_dm(),
                                "name": row.name,
                            }));
                        }
                    }
                }
            }
        }

        let in_engine = self
            .inner
            .engine
            .torrent_states()
            .map(|v| v.iter().any(|s| s.infohash == ih_hex))
            .unwrap_or(false);
        let name = self.resolve_room_name(ih_hex, dn);
        let magnet = self.stored_magnet_with_defaults(magnet);

        let (save_dir, row) = {
            let st = self.inner.state.lock().unwrap();
            let save_dir = st
                .store
                .torrent_get(ih_hex)
                .ok()
                .flatten()
                .map(|r| r.save_path)
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| self.save_dir_for(ih_hex));
            // manifest.name tracks the AUTO name (torrent metadata name);
            // row.name is the display name and survives user renames
            let manifest = crate::chat::group::GroupManifest::for_torrent(&gid, &name);
            let prev = st.store.group_get(&gid).ok().flatten();
            let display = match &prev {
                Some(old) if old.name != old.manifest.name => old.name.clone(),
                _ => manifest.name.clone(),
            };
            let row = match &prev {
                Some(old) => GroupRow {
                    gid,
                    name: display,
                    avatar: old.avatar.clone(),
                    magnet: magnet.clone(),
                    manifest,
                    head_seq: old.head_seq,
                    created: old.created,
                    joined: now,
                    last_read_ts: old.last_read_ts,
                    left: false,
                },
                None => GroupRow {
                    gid,
                    name: display,
                    avatar: Vec::new(),
                    magnet: magnet.clone(),
                    manifest,
                    head_seq: 0,
                    created: now,
                    joined: now,
                    last_read_ts: now,
                    left: false,
                },
            };
            (save_dir, row)
        };
        std::fs::create_dir_all(&save_dir)?;

        if !in_engine {
            self.inner
                .engine
                .add_magnet(&magnet, &save_dir, dn.or(Some(row.name.as_str())))?;
            self.apply_default_trackers(ih_hex);
        }

        let own_pk = self.own_pk_hex();
        {
            let mut st = self.inner.state.lock().unwrap();
            st.store.group_upsert(&row)?;
            st.store.group_set_left(&gid, false)?;
            st.store.torrent_upsert(&TorrentRow {
                infohash: ih_hex.to_string(),
                name: row.name.clone(),
                magnet: magnet.clone(),
                save_path: save_dir.clone(),
                kind: 0,
                group_id: Some(gid),
                added: now,
            })?;
            // upsert only refreshes name on conflict — bind explicitly
            st.store.torrent_set_group(ih_hex, Some(&gid))?;
            st.store.torrent_set_magnet(ih_hex, &magnet)?;
            let dag = crate::chat::sync::rebuild_dag(&st.store, &gid, &own_pk).unwrap_or_default();
            let own_seq = dag.author_seq(&own_pk);
            let mut sync = crate::chat::sync::GroupSync::new(
                gid,
                row.manifest.clone(),
                row.head_seq,
                ih_hex.to_string(),
            );
            sync.dag = dag;
            st.groups.insert(
                ih_hex.to_string(),
                GroupRuntime {
                    sync,
                    row: row.clone(),
                    own_seq,
                    last_publish: 0,
                    pending_dm_req: None,
                },
            );
            st.by_ih.insert(ih_hex.to_string(), ih_hex.to_string());
        }

        // start syncing (head pointer + missing messages) right away
        self.kick_group_sync(ih_hex);
        self.emit_event(
            "chat.group_joined",
            json!({"group": group_summary_from_row(&row)}),
        );
        Ok(json!({
            "group_id": ih_hex,
            "name": row.name,
            "magnet": magnet,
            "infohash": ih_hex,
            "dm": false,
        }))
    }

    /// Best display name for a room: engine torrent name (real metadata) >
    /// registry name > magnet `dn` > short-hash placeholder.
    fn resolve_room_name(&self, ih_hex: &str, dn: Option<&str>) -> String {
        let looks_like_hash = |n: &str| {
            n.len() == 40
                && n.chars().all(|c| c.is_ascii_hexdigit())
                && n.eq_ignore_ascii_case(ih_hex)
        };
        if let Ok(states) = self.inner.engine.torrent_states() {
            if let Some(s) = states.iter().find(|s| s.infohash == ih_hex) {
                let n = s.name.trim();
                if !n.is_empty() && !looks_like_hash(n) {
                    return crate::chat::group::clamp_name(n);
                }
            }
        }
        {
            let st = self.inner.state.lock().unwrap();
            if let Ok(Some(row)) = st.store.torrent_get(ih_hex) {
                let n = row.name.trim();
                if !n.is_empty() && !looks_like_hash(n) {
                    return crate::chat::group::clamp_name(n);
                }
            }
        }
        if let Some(dn) = dn.map(str::trim).filter(|d| !d.is_empty()) {
            return crate::chat::group::clamp_name(dn);
        }
        format!("种子 {}", &ih_hex[..8])
    }

    /// v0.5.2: manifest-torrent DM channels are gone — DMs are established by
    /// a signed request/accept exchange over a shared room's swarm and live
    /// purely in local storage (see [`Api::chat_start_dm`]).
    pub fn chat_join_dm(&self, p: Json) -> Result<Json> {
        let _ = p;
        Err(CoreError::NotFound(
            "chat.join_dm 已移除：私聊不再使用清单种子，请在共享群聊中对成员发起私聊（chat.start_dm）".into(),
        ))
    }

    /// Start (or fetch) an encrypted DM channel with the author of any
    /// message we have seen (their X25519 key travels in the `x` field of
    /// their messages).
    ///
    /// v0.5.2 flow — NO manifest torrent, NO broadcast:
    ///   1. derive the deterministic channel gid from both identity pubkeys
    ///   2. send a signed DmReq DIRECTLY to the peer over a shared room's
    ///      swarm connection (bc_chat ext frame, addressed by pubkey)
    ///   3. the peer's UI prompts; on accept both sides hold an identical
    ///      local manifest and exchange E2E-encrypted DmMsg frames
    ///
    /// If the peer is offline the request is re-sent when they reconnect.
    pub fn chat_start_dm(&self, p: Json) -> Result<Json> {
        let their_pk_hex = jstr(&p, "author_pk")?.to_string();
        let their_pk = crate::api::hex32(&their_pk_hex)?;
        let (identity, profile_name) = self.identity_snapshot();
        let own_pk = identity.public_key();
        if their_pk == own_pk {
            return Err(CoreError::Invalid("不能和自己私聊".into()));
        }
        let gid = GroupManifest::dm_gid(&own_pk, &their_pk);
        let gid_hex = hex::encode(gid);
        {
            let st = self.inner.state.lock().unwrap();
            if st.groups.contains_key(&gid_hex) {
                if let Ok(Some(row)) = st.store.group_get(&gid) {
                    return Ok(json!({
                        "group_id": gid_hex,
                        "existing": true,
                        "dm": true,
                        "name": row.name,
                    }));
                }
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
        let manifest = self.build_dm_manifest(&gid, &their_pk, &their_x, &their_name)?;

        // create the channel locally right away (pending acceptance)
        self.create_dm_channel_local(&manifest)?;

        // signed request frame, addressed to the peer only
        let own_xs = crate::crypto::x_secret_from_seed(&identity.seed);
        let own_x = crate::crypto::x_public(&own_xs);
        let now = crate::now_ms();
        let body = crate::chat::sync::dm_req_sig_body(
            &gid,
            &hex::encode(own_pk),
            &profile_name,
            &hex::encode(own_x),
            now,
        );
        let sig = identity.sign(&body);
        let frame = ExtPayload::DmReq {
            gid,
            from_pk: hex::encode(own_pk),
            from_name: profile_name.clone(),
            from_x: hex::encode(own_x),
            ts: now,
            sig,
        }
        .encode();
        let sent = self.dm_deliver_frame(&their_pk_hex, &frame);
        {
            let mut st = self.inner.state.lock().unwrap();
            // awaiting accept until DmAccept arrives; if the peer was
            // offline, keep the signed frame so presence events re-send it
            st.dm_awaiting_accept.insert(gid_hex.clone());
            if !sent {
                if let Some(rt) = st.groups.get_mut(&gid_hex) {
                    rt.pending_dm_req = Some(frame);
                }
            }
        }
        log::info!(
            "dm start: gid={gid_hex} peer={} sent={sent}",
            &their_pk_hex[..8.min(their_pk_hex.len())]
        );
        let summary = {
            let st = self.inner.state.lock().unwrap();
            st.groups
                .get(&gid_hex)
                .map(|rt| group_summary_from_row(&rt.row))
        };
        if let Some(summary) = summary {
            self.emit_event("chat.group_joined", json!({"group": summary}));
        }
        Ok(json!({
            "group_id": gid_hex,
            "dm": true,
            "pending": true,
            "sent": sent,
            "name": their_name,
        }))
    }

    /// Build the local DM manifest: both parties' identity + X25519 keys,
    /// parties sorted by pubkey so both sides derive identical bytes.
    fn build_dm_manifest(
        &self,
        gid: &Sha1Hash,
        their_pk: &PubKey,
        their_x: &[u8; 32],
        their_name: &str,
    ) -> Result<GroupManifest> {
        let (identity, profile_name) = self.identity_snapshot();
        let own_pk = identity.public_key();
        let own_xs = crate::crypto::x_secret_from_seed(&identity.seed);
        let own_x = crate::crypto::x_public(&own_xs);
        let head_seed = crate::crypto::torrent_head_seed(gid);
        let head = Identity::from_seed(head_seed);
        let (a, b) = if own_pk <= *their_pk {
            (
                DmParty {
                    k: own_pk,
                    x: own_x,
                },
                DmParty {
                    k: *their_pk,
                    x: *their_x,
                },
            )
        } else {
            (
                DmParty {
                    k: *their_pk,
                    x: *their_x,
                },
                DmParty {
                    k: own_pk,
                    x: own_x,
                },
            )
        };
        Ok(GroupManifest {
            gid: *gid,
            name: crate::chat::group::clamp_name(their_name),
            avatar: Vec::new(),
            created: crate::now_ms(),
            creator_pk: own_pk,
            creator_name: profile_name.chars().take(32).collect(),
            head_pk: head.public_key(),
            head_seed,
            dm: Some((a, b)),
        })
    }

    /// Persist + register a DM channel with NO torrent and NO DHT sync.
    fn create_dm_channel_local(&self, manifest: &GroupManifest) -> Result<()> {
        let gid_hex = hex::encode(manifest.gid);
        let now = crate::now_ms();
        let own_pk = self.own_pk_hex();
        let row = GroupRow {
            gid: manifest.gid,
            name: manifest.name.clone(),
            avatar: Vec::new(),
            magnet: String::new(),
            manifest: manifest.clone(),
            head_seq: 0,
            created: now,
            joined: now,
            last_read_ts: now,
            left: false,
        };
        let mut st = self.inner.state.lock().unwrap();
        st.store.group_upsert(&row)?;
        st.store.group_set_left(&manifest.gid, false)?;
        if !st.groups.contains_key(&gid_hex) {
            let dag = crate::chat::sync::rebuild_dag(&st.store, &manifest.gid, &own_pk)
                .unwrap_or_default();
            let own_seq = dag.author_seq(&own_pk);
            let mut sync = GroupSync::new(manifest.gid, manifest.clone(), 0, String::new());
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
        Ok(())
    }

    /// The DM counterparty's identity pubkey (hex) for a channel manifest.
    pub fn dm_peer_pk_hex(&self, manifest: &GroupManifest) -> Option<String> {
        let own_pk = self.inner.active.read().unwrap().identity.public_key();
        let (a, b) = manifest.dm.as_ref()?;
        let peer = if a.k == own_pk {
            b
        } else if b.k == own_pk {
            a
        } else {
            return None;
        };
        Some(hex::encode(peer.k))
    }

    /// Find a swarm where the peer currently holds a bc_chat connection to us
    /// (presence cache first, then a live ext_peers probe of our rooms).
    pub fn dm_route(&self, peer_pk: &str) -> Option<String> {
        let candidates = {
            let st = self.inner.state.lock().unwrap();
            let mut c: Vec<String> = st
                .presence
                .get(peer_pk)
                .map(|s| s.iter().cloned().collect())
                .unwrap_or_default();
            // presence may be stale; always allow probing every live room
            for rt in st.groups.values() {
                if !rt.sync.swarm_ih.is_empty() && !c.contains(&rt.sync.swarm_ih) {
                    c.push(rt.sync.swarm_ih.clone());
                }
            }
            c
        };
        for ih in candidates {
            if let Ok(peers) = self.inner.engine.ext_peers(&ih) {
                if peers.iter().any(|p| p.pk == peer_pk) {
                    // refresh the cache while we are here
                    let mut st = self.inner.state.lock().unwrap();
                    st.presence
                        .entry(peer_pk.to_string())
                        .or_default()
                        .insert(ih.clone());
                    return Some(ih);
                }
            }
        }
        None
    }

    /// Deliver one ext frame to the peer through any shared swarm.
    pub fn dm_deliver_frame(&self, peer_pk: &str, frame: &[u8]) -> bool {
        let Some(ih) = self.dm_route(peer_pk) else {
            return false;
        };
        self.inner
            .engine
            .ext_send_to(&ih, peer_pk, frame)
            .map(|n| n > 0)
            .unwrap_or(false)
    }

    /// Snapshot the in-memory DM request inbox into kv storage (survives
    /// restarts — a request must not force the peer to resend it).
    fn persist_dm_pending(&self, st: &CoreState) {
        let arr: Vec<Json> = st
            .dm_pending
            .iter()
            .map(|(gid, r)| {
                json!({
                    "gid": gid,
                    "from_pk": r.from_pk,
                    "from_name": r.from_name,
                    "from_x": r.from_x,
                    "ih": r.ih,
                    "ts": r.ts,
                })
            })
            .collect();
        if let Ok(bytes) = serde_json::to_vec(&arr) {
            let _ = st.store.kv_set("dm_pending_v1", &bytes);
        }
    }

    fn persist_dm_blocked(&self, st: &CoreState) {
        let mut v: Vec<&String> = st.dm_blocked.iter().collect();
        v.sort();
        if let Ok(bytes) = serde_json::to_vec(&v) {
            let _ = st.store.kv_set("dm_blocked_v1", &bytes);
        }
    }

    /// Block a peer: drop their pending request (if any) and silently ignore
    /// future DM requests from this identity pubkey.
    pub fn chat_dm_block(&self, p: Json) -> Result<Json> {
        let peer_pk = jstr(&p, "peer_pk")?.to_string();
        if peer_pk.len() != 64 {
            return Err(CoreError::Invalid("bad peer_pk".into()));
        }
        let mut removed: Vec<String> = Vec::new();
        {
            let mut st = self.inner.state.lock().unwrap();
            st.dm_blocked.insert(peer_pk.clone());
            st.dm_pending.retain(|gid, r| {
                if r.from_pk == peer_pk {
                    removed.push(gid.clone());
                    false
                } else {
                    true
                }
            });
            self.persist_dm_pending(&st);
            self.persist_dm_blocked(&st);
        }
        for gid in &removed {
            self.emit_event("chat.dm_rejected", json!({"group": gid}));
        }
        self.emit_event("chat.group_updated", json!({}));
        Ok(json!({"ok": true, "blocked": peer_pk}))
    }

    /// Pending incoming DM requests (for the UI prompt queue; requests also
    /// arrive live via the `chat.dm_request` event).
    pub fn chat_dm_requests(&self) -> Result<Json> {
        let st = self.inner.state.lock().unwrap();
        let mut reqs: Vec<Json> = st
            .dm_pending
            .iter()
            .map(|(gid, r)| {
                json!({
                    "group_id": gid,
                    "peer_pk": r.from_pk,
                    "peer_name": r.from_name,
                    "ts": r.ts,
                })
            })
            .collect();
        reqs.sort_by_key(|r| r["ts"].as_i64().unwrap_or(0));
        Ok(json!({"requests": reqs}))
    }

    /// Respond to an incoming DM request (accept → create the channel and
    /// reply with a signed DmAccept; decline → DmReject, nothing stored).
    pub fn chat_dm_respond(&self, p: Json) -> Result<Json> {
        let gid_hex = jstr(&p, "group_id")?.to_string();
        let accept = crate::api::jbool(&p, "accept", true);
        let req = {
            let mut st = self.inner.state.lock().unwrap();
            let req = st.dm_pending.remove(&gid_hex);
            self.persist_dm_pending(&st);
            req
        };
        let Some(req) = req else {
            return Err(CoreError::NotFound("dm request expired".into()));
        };
        if !accept {
            let gid = hex20(&gid_hex)?;
            let frame = ExtPayload::DmReject { gid }.encode();
            let _ = self.dm_deliver_frame(&req.from_pk, &frame);
            return Ok(json!({"ok": true, "accepted": false}));
        }
        let their_pk = crate::api::hex32(&req.from_pk)?;
        let mut their_x = [0u8; 32];
        their_x.copy_from_slice(&crate::api::hex32(&req.from_x)?);
        let gid = hex20(&gid_hex)?;
        // gid must be exactly the deterministic derivation of our pk pair —
        // otherwise a swarm peer could shove arbitrary channels at us
        let own_pk = self.inner.active.read().unwrap().identity.public_key();
        if GroupManifest::dm_gid(&own_pk, &their_pk) != gid {
            return Err(CoreError::Invalid("dm gid mismatch".into()));
        }
        let manifest = self.build_dm_manifest(&gid, &their_pk, &their_x, &req.from_name)?;
        self.create_dm_channel_local(&manifest)?;
        let (identity, _) = self.identity_snapshot();
        let own_xs = crate::crypto::x_secret_from_seed(&identity.seed);
        let own_x = crate::crypto::x_public(&own_xs);
        let now = crate::now_ms();
        let body = crate::chat::sync::dm_accept_sig_body(&gid, &hex::encode(own_x), now);
        let sig = identity.sign(&body);
        let frame = ExtPayload::DmAccept {
            gid,
            x: hex::encode(own_x),
            ts: now,
            sig,
        }
        .encode();
        // prefer the swarm the request arrived on
        let direct = self
            .inner
            .engine
            .ext_send_to(&req.ih, &req.from_pk, &frame)
            .map(|n| n > 0)
            .unwrap_or(false);
        let sent = direct || self.dm_deliver_frame(&req.from_pk, &frame);
        log::info!(
            "dm accept: gid={gid_hex} peer={} sent={sent}",
            &req.from_pk[..8.min(req.from_pk.len())]
        );
        let summary = {
            let st = self.inner.state.lock().unwrap();
            st.groups
                .get(&gid_hex)
                .map(|rt| group_summary_from_row(&rt.row))
        };
        if let Some(summary) = summary {
            self.emit_event("chat.group_joined", json!({"group": summary}));
        }
        let _ = manifest;
        Ok(json!({"ok": true, "accepted": true, "group_id": gid_hex, "sent": sent}))
    }

    /// Members of a room (connected bc_chat peers with identity pubkeys and
    /// the display names we know from their messages) or the counterparty of
    /// a DM channel. Powers "start DM" and presence display.
    pub fn chat_members(&self, p: Json) -> Result<Json> {
        let gid_hex = jstr(&p, "group_id")?.to_string();
        let own_pk = self.own_pk_hex();
        let (swarm_ih, is_dm, dm_peer) = {
            let st = self.inner.state.lock().unwrap();
            let rt = st
                .groups
                .get(&gid_hex)
                .ok_or_else(|| CoreError::NotFound("group".into()))?;
            (
                rt.sync.swarm_ih.clone(),
                rt.sync.manifest.is_dm(),
                self.dm_peer_pk_hex(&rt.sync.manifest),
            )
        };
        if is_dm {
            let Some(pk) = dm_peer else {
                return Ok(json!({"members": []}));
            };
            let online = self.peer_online(&pk);
            let name = {
                let st = self.inner.state.lock().unwrap();
                st.store
                    .message_author_x(&pk)
                    .ok()
                    .flatten()
                    .map(|(_, n)| n)
                    .unwrap_or_default()
            };
            return Ok(json!({"members": [
                {"pk": pk, "name": name, "online": online, "endpoint": ""}
            ]}));
        }
        let peers = self.inner.engine.ext_peers(&swarm_ih).unwrap_or_default();
        let mut members = Vec::new();
        {
            let st = self.inner.state.lock().unwrap();
            for p in peers {
                if p.pk.is_empty() || p.pk == own_pk {
                    continue;
                }
                let name = st
                    .store
                    .message_author_x(&p.pk)
                    .ok()
                    .flatten()
                    .map(|(_, n)| n)
                    .unwrap_or_default();
                members.push(json!({
                    "pk": p.pk,
                    "name": name,
                    "online": true,
                    "endpoint": p.endpoint,
                }));
            }
        }
        // dedupe by pk (a peer may hold several connections)
        let mut seen = std::collections::HashSet::new();
        members.retain(|m| m["pk"].as_str().map(|k| seen.insert(k.to_string())) == Some(true));
        Ok(json!({"members": members}))
    }

    /// Whether a DM counterparty currently holds a bc_chat connection to us
    /// in any shared swarm.
    pub fn peer_online(&self, peer_pk: &str) -> bool {
        {
            let st = self.inner.state.lock().unwrap();
            if st.presence.get(peer_pk).map(|s| !s.is_empty()) == Some(true) {
                return true;
            }
        }
        self.dm_route(peer_pk).is_some()
    }

    /// Deliver every pending outbox entry of a DM channel to its peer
    /// (called on reconnect and from the outbox tick). Delivery bumps the
    /// entry's next-try; the entry leaves the outbox on the peer's DmAck.
    pub fn dm_flush_outbox(&self, gid_hex: &str) {
        let Ok(gid) = hex20(gid_hex) else { return };
        let peer_pk = {
            let st = self.inner.state.lock().unwrap();
            match st.groups.get(gid_hex) {
                Some(rt) => self.dm_peer_pk_hex(&rt.sync.manifest),
                None => return,
            }
        };
        let Some(peer_pk) = peer_pk else { return };
        let todo: Vec<(i64, Sha1Hash, Vec<u8>)> = {
            let st = self.inner.state.lock().unwrap();
            let Ok(entries) = st.store.outbox_list() else {
                return;
            };
            entries
                .into_iter()
                .filter(|(_, g, _, a, _)| *g == gid && *a <= 60)
                .filter_map(|(row_id, _, msg_id, _, _)| {
                    st.store
                        .message_get_raw(&msg_id)
                        .ok()
                        .flatten()
                        .map(|raw| (row_id, msg_id, raw))
                })
                .collect()
        };
        if todo.is_empty() {
            return;
        }
        let now = crate::now_ms();
        for (row_id, _msg_id, raw) in todo {
            let frame = ExtPayload::DmMsg { gid, msg: raw }.encode();
            let delivered = self.dm_deliver_frame(&peer_pk, &frame);
            let st = self.inner.state.lock().unwrap();
            if delivered {
                // on the wire; keep retrying (idempotent) until DmAck clears it
                let _ = st.store.outbox_bump(row_id, now + 15_000);
            } else {
                let _ = st.store.outbox_bump(row_id, now + 60_000);
                break; // peer disappeared mid-flush
            }
        }
    }

    /// bc_chat peer connected/disconnected: maintain the presence map, greet
    /// room peers, and for DM channels re-send a pending request, gap-fill
    /// via DmFetch and flush the outbox.
    pub fn on_chat_peer(&self, infohash: String, pk: String, connected: bool) {
        let mut dm_work: Vec<(String, Option<Vec<u8>>, i64)> = Vec::new();
        {
            let mut st = self.inner.state.lock().unwrap();
            if !pk.is_empty() {
                if connected {
                    st.presence
                        .entry(pk.clone())
                        .or_default()
                        .insert(infohash.clone());
                } else if let Some(set) = st.presence.get_mut(&pk) {
                    set.remove(&infohash);
                    if set.is_empty() {
                        st.presence.remove(&pk);
                    }
                }
            }
            if !connected {
                return;
            }
            // greet the new room peer with our head set
            if let Some(gid) = st.by_ih.get(&infohash).cloned() {
                if let Some(rt) = st.groups.get(&gid) {
                    if !rt.sync.manifest.is_dm() {
                        rt.sync.ext_announce_heads(&*self.inner.engine);
                    }
                }
            }
            if pk.is_empty() {
                return;
            }
            // DM channels with this peer: queue flush work
            for (gid_hex, rt) in st.groups.iter() {
                if !rt.sync.manifest.is_dm() {
                    continue;
                }
                if self.dm_peer_pk_hex(&rt.sync.manifest).as_deref() != Some(pk.as_str()) {
                    continue;
                }
                let after_seq = rt.sync.dag.author_seq(&pk);
                dm_work.push((gid_hex.clone(), rt.pending_dm_req.clone(), after_seq));
            }
        }
        for (gid_hex, pending_req, after_seq) in dm_work {
            if let Some(frame) = pending_req {
                if self.dm_deliver_frame(&pk, &frame) {
                    let mut st = self.inner.state.lock().unwrap();
                    if let Some(rt) = st.groups.get_mut(&gid_hex) {
                        rt.pending_dm_req = None;
                    }
                }
            }
            if let Ok(gid) = hex20(&gid_hex) {
                let fetch = ExtPayload::DmFetch { gid, after_seq }.encode();
                let _ = self.dm_deliver_frame(&pk, &fetch);
            }
            self.dm_flush_outbox(&gid_hex);
        }
    }

    /// Handle one addressed DM ext frame (already decoded + routed here by
    /// the engine event loop). `from_pk` is the sender identity advertised in
    /// the bc_chat handshake of the connection it arrived on.
    pub fn on_dm_frame(&self, ih: &str, from_pk: &str, ext: ExtPayload) {
        use crate::chat::sync::{dm_accept_sig_body, dm_ack_sig_body, dm_req_sig_body};
        match ext {
            ExtPayload::DmReq {
                gid,
                from_pk: payload_pk,
                from_name,
                from_x,
                ts,
                sig,
            } => {
                if from_pk.is_empty() || payload_pk != from_pk {
                    log::warn!("dm req: envelope/payload pk mismatch");
                    return;
                }
                let Ok(pk_bytes) = crate::api::hex32(&payload_pk) else {
                    return;
                };
                let body = dm_req_sig_body(&gid, &payload_pk, &from_name, &from_x, ts);
                if !crate::crypto::verify(&pk_bytes, &body, &sig) {
                    log::warn!("dm req: bad signature");
                    return;
                }
                let own_pk = self.inner.active.read().unwrap().identity.public_key();
                if GroupManifest::dm_gid(&own_pk, &pk_bytes) != gid {
                    log::warn!("dm req: gid mismatch");
                    return;
                }
                let gid_hex = hex::encode(gid);
                {
                    let st = self.inner.state.lock().unwrap();
                    if st.dm_blocked.contains(&payload_pk) {
                        log::info!("dm request from blocked peer dropped");
                        return;
                    }
                }
                // channel already established? our accept may have been lost —
                // re-send it instead of prompting again (idempotent)
                let established = {
                    let st = self.inner.state.lock().unwrap();
                    st.groups.contains_key(&gid_hex)
                };
                if established {
                    let (identity, _) = self.identity_snapshot();
                    let own_xs = crate::crypto::x_secret_from_seed(&identity.seed);
                    let own_x = crate::crypto::x_public(&own_xs);
                    let now = crate::now_ms();
                    let body = dm_accept_sig_body(&gid, &hex::encode(own_x), now);
                    let sig = identity.sign(&body);
                    let frame = ExtPayload::DmAccept {
                        gid,
                        x: hex::encode(own_x),
                        ts: now,
                        sig,
                    }
                    .encode();
                    let _ = self.dm_deliver_frame(from_pk, &frame);
                    return;
                }
                {
                    let mut st = self.inner.state.lock().unwrap();
                    st.dm_pending.insert(
                        gid_hex.clone(),
                        crate::api::DmPendingReq {
                            from_pk: payload_pk.clone(),
                            from_name: from_name.clone(),
                            from_x: from_x.clone(),
                            ih: ih.to_string(),
                            ts,
                        },
                    );
                    self.persist_dm_pending(&st);
                }
                log::info!("dm request from {}", &payload_pk[..8]);
                self.emit_event(
                    "chat.dm_request",
                    json!({
                        "group_id": gid_hex,
                        "peer_pk": payload_pk,
                        "peer_name": from_name,
                    }),
                );
            }
            ExtPayload::DmAccept { gid, x, ts, sig } => {
                let gid_hex = hex::encode(gid);
                let peer_pk = {
                    let st = self.inner.state.lock().unwrap();
                    match st.groups.get(&gid_hex) {
                        Some(rt) => self.dm_peer_pk_hex(&rt.sync.manifest),
                        None => {
                            log::warn!("dm accept: no channel {gid_hex}");
                            return;
                        }
                    }
                };
                let Some(peer_pk) = peer_pk else { return };
                if from_pk != peer_pk {
                    log::warn!("dm accept: sender is not the channel peer");
                    return;
                }
                let Ok(pk_bytes) = crate::api::hex32(&peer_pk) else {
                    return;
                };
                let body = dm_accept_sig_body(&gid, &x, ts);
                if !crate::crypto::verify(&pk_bytes, &body, &sig) {
                    log::warn!("dm accept: bad signature");
                    return;
                }
                {
                    let mut st = self.inner.state.lock().unwrap();
                    st.dm_awaiting_accept.remove(&gid_hex);
                    if let Some(rt) = st.groups.get_mut(&gid_hex) {
                        rt.pending_dm_req = None;
                    }
                }
                log::info!("dm established: {gid_hex}");
                self.emit_event("chat.dm_established", json!({"group": gid_hex}));
                self.emit_event("chat.group_updated", json!({"group": gid_hex}));
                // gap-fill + flush anything queued while they were away
                self.dm_flush_outbox(&gid_hex);
            }
            ExtPayload::DmReject { gid } => {
                let gid_hex = hex::encode(gid);
                {
                    let mut st = self.inner.state.lock().unwrap();
                    st.dm_awaiting_accept.remove(&gid_hex);
                    st.groups.remove(&gid_hex);
                    let _ = st.store.group_set_left(&gid, true);
                }
                log::info!("dm rejected: {gid_hex}");
                self.emit_event("chat.dm_rejected", json!({"group": gid_hex}));
                self.emit_event("chat.group_updated", json!({"group": gid_hex}));
            }
            ExtPayload::DmMsg { gid, msg } => self.on_dm_msg(from_pk, gid, msg),
            ExtPayload::DmAck { gid, id, sig } => {
                let gid_hex = hex::encode(gid);
                let peer_pk = {
                    let st = self.inner.state.lock().unwrap();
                    match st.groups.get(&gid_hex) {
                        Some(rt) => self.dm_peer_pk_hex(&rt.sync.manifest),
                        None => return,
                    }
                };
                let Some(peer_pk) = peer_pk else { return };
                if from_pk != peer_pk {
                    return;
                }
                let Ok(pk_bytes) = crate::api::hex32(&peer_pk) else {
                    return;
                };
                let body = dm_ack_sig_body(&gid, &id);
                if !crate::crypto::verify(&pk_bytes, &body, &sig) {
                    log::warn!("dm ack: bad signature");
                    return;
                }
                {
                    let mut st = self.inner.state.lock().unwrap();
                    if let Some(rt) = st.groups.get_mut(&gid_hex) {
                        rt.sync.pending_puts.remove(&id);
                    }
                    let _ = st.store.outbox_remove_msg(&id);
                    let _ = st.store.message_state_set(&id, 1);
                }
                self.emit_event(
                    "chat.message_state",
                    json!({"group": gid_hex, "id": hex::encode(id), "state": 1}),
                );
            }
            ExtPayload::DmFetch { gid, after_seq } => {
                let gid_hex = hex::encode(gid);
                let (peer_pk, own_pk_hex) = {
                    let st = self.inner.state.lock().unwrap();
                    match st.groups.get(&gid_hex) {
                        Some(rt) => (self.dm_peer_pk_hex(&rt.sync.manifest), self.own_pk_hex()),
                        None => return,
                    }
                };
                if peer_pk.as_deref() != Some(from_pk) {
                    return;
                }
                // reply with OUR messages the peer is missing (author_seq >
                // after_seq), oldest first, capped
                let frames: Vec<Vec<u8>> = {
                    let st = self.inner.state.lock().unwrap();
                    let Ok(msgs) = st.store.messages_of_group(&gid, &own_pk_hex) else {
                        return;
                    };
                    msgs.into_iter()
                        .filter(|sm| {
                            sm.msg.author_pk == own_pk_hex && sm.msg.author_seq > after_seq
                        })
                        .take(50)
                        .map(|sm| ExtPayload::DmMsg { gid, msg: sm.bytes }.encode())
                        .collect()
                };
                for frame in frames {
                    if !self.dm_deliver_frame(from_pk, &frame) {
                        break;
                    }
                }
            }
            _ => {}
        }
    }

    /// Ingest one addressed DM message: verify, store, ack, gap-fill.
    fn on_dm_msg(&self, from_pk: &str, gid: Sha1Hash, raw: Vec<u8>) {
        let gid_hex = hex::encode(gid);
        let now = crate::now_ms();
        let Ok(sm) = crate::chat::message::verify_message(&raw, now) else {
            return;
        };
        if sm.msg.group != gid_hex {
            return;
        }
        let mut is_new = false;
        let mut fetch_after: Option<i64> = None;
        let ack_frame = {
            let mut guard = self.inner.state.lock().unwrap();
            let st = &mut *guard;
            let Some(rt) = st.groups.get_mut(&gid_hex) else {
                return;
            };
            if !rt.sync.manifest.is_dm() {
                return;
            }
            let peer = self.dm_peer_pk_hex(&rt.sync.manifest);
            if peer.as_deref() != Some(from_pk) || sm.msg.author_pk != from_pk {
                log::warn!("dm msg from non-member dropped");
                return;
            }
            let before = rt.sync.dag.author_seq(from_pk);
            if let Ok(Some(_)) = rt.sync.ingest(&st.store, sm.clone(), 1) {
                is_new = true;
                let after = rt.sync.dag.author_seq(from_pk);
                if after < sm.msg.author_seq {
                    // seq gap: ask for everything we are missing
                    fetch_after = Some(after);
                }
                let _ = before;
            }
            // ack every verified in-channel message (dupes included — the
            // peer may have missed our previous ack)
            let identity = self.inner.active.read().unwrap().identity.clone();
            let body = crate::chat::sync::dm_ack_sig_body(&gid, &sm.id);
            let sig = identity.sign(&body);
            ExtPayload::DmAck {
                gid,
                id: sm.id,
                sig,
            }
            .encode()
        };
        let _ = self.dm_deliver_frame(from_pk, &ack_frame);
        if let Some(after_seq) = fetch_after {
            let fetch = ExtPayload::DmFetch { gid, after_seq }.encode();
            let _ = self.dm_deliver_frame(from_pk, &fetch);
        }
        if is_new {
            self.emit_event(
                "chat.message_new",
                json!({"group": gid_hex, "message": sm.msg}),
            );
            self.emit_event("chat.group_updated", json!({"group": gid_hex}));
        }
    }

    pub fn chat_leave_group(&self, p: Json) -> Result<Json> {
        let gid_hex = jstr(&p, "group_id")?.to_string();
        let delete_history = jbool(&p, "delete_history", false);
        let gid = hex20(&gid_hex)?;
        let (is_torrent_room, is_dm, ih) = {
            let st = self.inner.state.lock().unwrap();
            match st.groups.get(&gid_hex) {
                Some(rt) => (
                    rt.sync.manifest.is_torrent_room(),
                    rt.sync.manifest.is_dm(),
                    rt.sync.swarm_ih.clone(),
                ),
                None => {
                    // runtime gone (restart with left flag?) — fall back to the row
                    let row = st.store.group_get(&gid).ok().flatten();
                    let room = row
                        .as_ref()
                        .map(|r| r.manifest.is_torrent_room())
                        .unwrap_or(false);
                    let dm = row.as_ref().map(|r| r.manifest.is_dm()).unwrap_or(false);
                    (room, dm, gid_hex.clone())
                }
            }
        };
        if is_dm {
            // v0.5.2 DM channels are purely local — silent removal, no
            // farewell, no torrent (legacy manifest torrents, if any, are
            // already gone from the session since restore stopped re-adding)
            let mut st = self.inner.state.lock().unwrap();
            if delete_history {
                st.store.group_purge(&gid)?;
            }
            st.store.group_set_left(&gid, true)?;
            st.groups.remove(&gid_hex);
            st.dm_awaiting_accept.remove(&gid_hex);
            st.dm_pending.remove(&gid_hex);
            return Ok(json!({"ok": true}));
        }
        if is_torrent_room {
            // torrent rooms: no farewell spam — every downloader of a public
            // torrent would see join/leave noise. The torrent itself is the
            // user's BT task and stays in the session; we only unbind the
            // chat room.
            let mut st = self.inner.state.lock().unwrap();
            if delete_history {
                st.store.group_purge(&gid)?;
            }
            st.store.group_set_left(&gid, true)?;
            st.store.torrent_set_group(&ih, None)?;
            st.groups.remove(&gid_hex);
            st.by_ih.remove(&ih);
            return Ok(json!({"ok": true, "torrent_kept": true}));
        }
        // DM / legacy manifest channels: best-effort farewell message while
        // we are still a member, then remove the (internal) manifest torrent
        self.send_system_message(&gid_hex, "leave", "");
        let mut st = self.inner.state.lock().unwrap();
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
        // NOTE: state lock is held here; read rules straight from the store
        let rules: Vec<crate::filter::FilterRule> = st
            .store
            .kv_get("filter_rules")
            .ok()
            .flatten()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        let items: Vec<Json> = display
            .iter()
            .map(|m| {
                let mut j = serde_json::to_value(m).unwrap_or(json!({}));
                j["blocked"] = json!(crate::filter::is_blocked(&rules, m));
                if let Payload::Attachment(a) = &m.payload {
                    let path = downloads.join(&a.infohash).join(&a.name);
                    j["local_path"] = json!(path.to_string_lossy());
                    // "have the file" must mean COMPLETE, not merely present:
                    // libtorrent preallocates the full-size (sparse) file when
                    // a download starts, and opening a partial mp4 fails at
                    // format probing (moov may live at EOF). Gate on the
                    // engine's verified state + exact size.
                    let size_ok = std::fs::metadata(&path)
                        .map(|md| md.len() == a.size.max(0) as u64)
                        .unwrap_or(false);
                    let complete = match states.get(&a.infohash) {
                        Some(s) => s.finished || s.progress >= 0.9999,
                        // not in the session (e.g. task removed, file kept):
                        // trust the exact-size check alone
                        None => size_ok,
                    };
                    j["have_file"] = json!(size_ok && complete);
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
        let is_dm;
        let dm_peer;
        {
            let mut guard = self.inner.state.lock().unwrap();
            let st = &mut *guard;
            let rt = st
                .groups
                .get_mut(&gid_hex)
                .ok_or_else(|| CoreError::NotFound("group".into()))?;
            swarm_ih = rt.sync.swarm_ih.clone();
            is_dm = rt.sync.manifest.is_dm();
            dm_peer = self.dm_peer_pk_hex(&rt.sync.manifest);
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
        if is_dm {
            // DM: addressed frames only — no DHT items, no swarm broadcast
            let Some(pk) = dm_peer else {
                return Err(CoreError::Invalid("dm channel without peer".into()));
            };
            for sm in &created {
                let frame = ExtPayload::DmMsg {
                    gid,
                    msg: sm.bytes.clone(),
                }
                .encode();
                let _ = self.dm_deliver_frame(&pk, &frame);
                ids.push(sm.msg.id.clone());
                self.emit_event(
                    "chat.message_new",
                    json!({"group": gid_hex, "message": sm.msg}),
                );
            }
            // undelivered frames stay in the outbox and flush on reconnect
        } else {
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

    /// Send a file as a chat attachment.
    ///
    /// The heavy work (hashing the source file, copying it into the seed
    /// layout) runs on a DEDICATED WORKER THREAD — multi-GB videos must
    /// never block the FFI caller (that froze the UI thread / ANR-killed the
    /// app on device). Returns `{job_id}` immediately; progress arrives as
    /// `chat.attachment_progress` events and the final message via the usual
    /// `chat.message_new`.
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
        if !src.is_file() {
            return Err(CoreError::Invalid("only single files are supported".into()));
        }
        let size = std::fs::metadata(src)?.len() as i64;
        if size <= 0 || size > 4i64 * 1024 * 1024 * 1024 {
            return Err(CoreError::Invalid(
                "file size out of range (1B..4GB)".into(),
            ));
        }
        {
            let st = self.inner.state.lock().unwrap();
            if !st.groups.contains_key(&gid_hex) {
                return Err(CoreError::NotFound("group".into()));
            }
        }
        static ATTACH_JOB_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let job_id = format!(
            "att-{}-{}",
            crate::now_ms(),
            ATTACH_JOB_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        );
        let api = Api {
            inner: self.inner.clone(),
        };
        let job = job_id.clone();
        std::thread::Builder::new()
            .name("bitte-attach".into())
            .spawn(move || {
                if let Err(e) =
                    api.attachment_job(&job, &gid_hex, &path, &display_name, &mime, size)
                {
                    log::warn!("attachment job {job} failed: {e}");
                    api.emit_event(
                        "chat.attachment_progress",
                        json!({"job_id": job, "phase": "error", "error": e.to_string()}),
                    );
                }
            })
            .map_err(|e| CoreError::Internal(format!("spawn failed: {e}")))?;
        Ok(json!({"job_id": job_id, "pending": true}))
    }

    /// Worker body of [`Api::chat_send_file`]. Runs off the FFI thread.
    fn attachment_job(
        &self,
        job_id: &str,
        gid_hex: &str,
        path: &str,
        display_name: &str,
        mime: &str,
        size: i64,
    ) -> Result<()> {
        let progress = |phase: &str| {
            self.emit_event(
                "chat.attachment_progress",
                json!({"job_id": job_id, "phase": phase}),
            );
        };
        progress("hash");
        // create the torrent from the source file (content-addressed)
        let created = self
            .inner
            .engine
            .create_torrent(path, "BitteChat attachment")?;
        let ih_hex = hex::encode(created.infohash);
        let gid = hex20(gid_hex)?;
        let src = std::path::Path::new(path);
        let orig_name = src
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| display_name.to_string());
        progress("copy");
        // copy into the canonical downloads/<ih>/<original name> layout so we
        // seed exactly what recipients will download
        let dest_dir = self.downloads_dir().join(&ih_hex);
        std::fs::create_dir_all(&dest_dir)?;
        let dest = dest_dir.join(&orig_name);
        std::fs::copy(src, &dest)?;
        progress("seed");
        self.inner
            .engine
            .add_torrent_bytes(&created.torrent_bytes, &dest_dir.to_string_lossy())?;
        self.apply_default_trackers(&ih_hex);
        let att_magnet = self.stored_magnet_with_defaults(&created.magnet);

        let att = Payload::Attachment(AttachmentInfo {
            infohash: ih_hex.clone(),
            name: display_name.to_string(),
            size,
            mime: mime.to_string(),
        });
        let (identity, profile_name) = self.identity_snapshot();
        let now = crate::now_ms();
        let (sm, is_dm, swarm_ih, dm_peer) = {
            let mut guard = self.inner.state.lock().unwrap();
            let st = &mut *guard;
            st.store.torrent_upsert(&TorrentRow {
                infohash: ih_hex.clone(),
                name: display_name.to_string(),
                magnet: att_magnet.clone(),
                save_path: dest_dir.to_string_lossy().to_string(),
                kind: 2,
                group_id: Some(gid),
                added: now,
            })?;
            st.store.torrent_set_magnet(&ih_hex, &att_magnet)?;
            let rt = st
                .groups
                .get_mut(gid_hex)
                .ok_or_else(|| CoreError::NotFound("group".into()))?;
            let parents = rt.sync.dag.heads();
            let channel_key = self.dm_channel_key(&rt.sync.manifest);
            let is_dm = rt.sync.manifest.is_dm();
            let dm_peer = self.dm_peer_pk_hex(&rt.sync.manifest);
            let swarm_ih = rt.sync.swarm_ih.clone();
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
                &crate::chat::message::MsgOpts { channel_key },
            )?;
            rt.sync.pending_puts.insert(sm.id);
            rt.sync.ingest(&st.store, sm.clone(), 0)?;
            st.store.outbox_add(&gid, &sm.id)?;
            rt.sync.dirty_heads = true;
            (sm, is_dm, swarm_ih, dm_peer)
        };
        if is_dm {
            if let Some(pk) = dm_peer {
                let frame = ExtPayload::DmMsg {
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
                let payload = ExtPayload::Msg(sm.bytes.clone()).encode();
                let _ = self.inner.engine.ext_send(&swarm_ih, &payload);
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
        self.emit_event(
            "chat.attachment_progress",
            json!({"job_id": job_id, "phase": "sent", "msg_id": sm.msg.id}),
        );
        Ok(())
    }

    /// Set the LOCAL display note of a room. v0.5.2: names are private —
    /// nothing is broadcast; without a note the room shows the torrent name.
    pub fn chat_rename_group(&self, p: Json) -> Result<Json> {
        let gid_hex = jstr(&p, "group_id")?.to_string();
        let name = jstr(&p, "name")?.trim().to_string();
        if name.is_empty() || name.len() > crate::chat::group::MAX_GROUP_NAME_LEN {
            return Err(CoreError::Invalid("备注长度需在 1..96 字节".into()));
        }
        {
            let mut st = self.inner.state.lock().unwrap();
            let gid = hex20(&gid_hex)?;
            st.store.group_set_name(&gid, &name)?;
            if let Some(rt) = st.groups.get_mut(&gid_hex) {
                rt.row.name = name.clone();
            }
        }
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
            // DM messages carry SEALED payloads — open with the channel key
            // before looking for the attachment inside
            let payload = match &sm.msg.payload {
                crate::chat::message::Payload::Sealed { sealed_b64 } => {
                    let key = st
                        .groups
                        .get(&gid_hex)
                        .and_then(|rt| self.dm_channel_key(&rt.sync.manifest))
                        .ok_or_else(|| CoreError::Invalid("dm channel key unavailable".into()))?;
                    crate::chat::message::open_dm_payload(&key, sm.msg.author_seq, sealed_b64)
                        .map(|(_, p)| p)
                        .ok_or_else(|| CoreError::Invalid("sealed payload decrypt failed".into()))?
                }
                p => p.clone(),
            };
            match payload {
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
        let magnet = self.stored_magnet_with_defaults(&format!(
            "magnet:?xt=urn:btih:{ih_hex}&dn={}",
            urlquery(&name)
        ));
        if !existing {
            let save_dir = self.downloads_dir().join(&ih_hex);
            std::fs::create_dir_all(&save_dir)?;
            self.inner
                .engine
                .add_magnet(&magnet, &save_dir.to_string_lossy(), Some(&name))?;
            self.apply_default_trackers(&ih_hex);
        }
        {
            let st = self.inner.state.lock().unwrap();
            st.store.torrent_upsert(&crate::store::TorrentRow {
                infohash: ih_hex.clone(),
                name: name.clone(),
                magnet: magnet.clone(),
                save_path: self
                    .downloads_dir()
                    .join(&ih_hex)
                    .to_string_lossy()
                    .to_string(),
                kind: 2,
                group_id: Some(gid),
                added: crate::now_ms(),
            })?;
            st.store.torrent_set_magnet(&ih_hex, &magnet)?;
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
        // identified bc_chat members (identity pubkey + display name we know
        // from their messages) — powers the member list and "start DM"
        let ext = self
            .inner
            .engine
            .ext_peers(&rt.sync.swarm_ih)
            .unwrap_or_default();
        let mut members: Vec<Json> = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for e in ext {
            if e.pk.is_empty() || !seen.insert(e.pk.clone()) {
                continue;
            }
            let name = st
                .store
                .message_author_x(&e.pk)
                .ok()
                .flatten()
                .map(|(_, n)| n)
                .unwrap_or_default();
            members.push(json!({"pk": e.pk, "name": name, "endpoint": e.endpoint}));
        }
        let dm_online = if m.is_dm() {
            self.dm_peer_pk_hex(m)
                .map(|pk| st.presence.get(&pk).map(|s| !s.is_empty()).unwrap_or(false))
        } else {
            None
        };
        Ok(json!({
            "group": group_summary_from_row(&rt.row),
            "kind": if m.is_dm() { "dm" } else if m.is_torrent_room() { "torrent" } else { "manifest" },
            "members": members,
            "dm_online": dm_online,
            "creator": {
                "pk": hex::encode(m.creator_pk),
                "name": m.creator_name,
            },
            "created": m.created,
            "infohash": rt.sync.swarm_ih,
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
