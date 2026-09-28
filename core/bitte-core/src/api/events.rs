//! Engine event loop and periodic scheduler.

use std::sync::mpsc::Receiver;
use std::time::Duration;

use serde_json::json;

use crate::api::{hex20, Api};
use crate::chat::message::verify_message;
use crate::crypto::{bep44_verify, Sha1Hash};
use crate::engine::EngineEvent;

const HEAD_POLL_ACTIVE_MS: i64 = 15_000;
const HEAD_POLL_IDLE_MS: i64 = 90_000;
const BT_PUSH_INTERVAL: u64 = 3;
const GROUP_TICK_INTERVAL: u64 = 5;
const OUTBOX_TICK_INTERVAL: u64 = 10;
const RSS_TICK_INTERVAL: u64 = 60;
const RSS_REFRESH_AGE_MS: i64 = 30 * 60 * 1000;

impl Api {
    pub fn spawn_event_loop(self: &Api, rx: Receiver<EngineEvent>) {
        let api = Api {
            inner: self.inner.clone(),
        };
        std::thread::Builder::new()
            .name("bitte-events".into())
            .spawn(move || {
                while let Ok(ev) = rx.recv() {
                    if *api.inner.shutdown.read().unwrap() {
                        break;
                    }
                    api.handle_engine_event(ev);
                }
            })
            .expect("spawn event loop");
    }

    pub fn spawn_scheduler(self: &Api) {
        let api = Api {
            inner: self.inner.clone(),
        };
        std::thread::Builder::new()
            .name("bitte-sched".into())
            .spawn(move || {
                let mut tick: u64 = 0;
                loop {
                    std::thread::sleep(Duration::from_secs(1));
                    if *api.inner.shutdown.read().unwrap() {
                        break;
                    }
                    tick += 1;
                    if tick.is_multiple_of(BT_PUSH_INTERVAL) {
                        api.push_bt_updates();
                    }
                    if tick.is_multiple_of(GROUP_TICK_INTERVAL) {
                        api.group_tick();
                    }
                    if tick.is_multiple_of(OUTBOX_TICK_INTERVAL) {
                        api.outbox_tick();
                    }
                    if tick.is_multiple_of(RSS_TICK_INTERVAL) {
                        api.rss_tick();
                    }
                }
            })
            .expect("spawn scheduler");
    }

    fn group_tick(&self) {
        let now = crate::now_ms();
        let active = self.inner.active_group.read().unwrap().clone();
        let mut guard = self.inner.state.lock().unwrap();
        let st = &mut *guard;
        for (gid_hex, rt) in st.groups.iter_mut() {
            let interval = if active.as_deref() == Some(gid_hex.as_str()) {
                HEAD_POLL_ACTIVE_MS
            } else {
                HEAD_POLL_IDLE_MS
            };
            if now - rt.sync.last_head_poll > interval {
                rt.sync.poll_heads(&*self.inner.engine, now);
            }
            if rt.sync.dirty_heads
                && now - rt.last_publish > 5_000
                && rt.sync.publish_heads(&st.store, &*self.inner.engine, now)
            {
                rt.last_publish = now;
                rt.sync.ext_announce_heads(&*self.inner.engine);
            }
            let backoff = rt.sync.fetch_backoff_table().clone();
            rt.sync
                .pump_fetches_filtered(&*self.inner.engine, &backoff, now);
        }
    }

    fn outbox_tick(&self) {
        let now = crate::now_ms();
        let mut guard = self.inner.state.lock().unwrap();
        let st = &mut *guard;
        let entries = match st.store.outbox_list() {
            Ok(e) => e,
            Err(_) => return,
        };
        for (row_id, _gid, msg_id, attempts, next_try) in entries {
            if next_try > now {
                continue;
            }
            if attempts > 60 {
                let _ = st.store.outbox_remove(row_id);
                continue;
            }
            let Some(raw) = st.store.message_get_raw(&msg_id).ok().flatten() else {
                let _ = st.store.outbox_remove(row_id);
                continue;
            };
            let _ = self.inner.engine.dht_put_immutable(&raw, &msg_id);
            let _ = st.store.outbox_bump(row_id, now + backoff_ms(attempts));
        }
    }

    fn rss_tick(&self) {
        let now = crate::now_ms();
        let due: Vec<(i64, String)> = {
            let st = self.inner.state.lock().unwrap();
            st.store
                .feeds_all()
                .unwrap_or_default()
                .into_iter()
                .filter(|(_, _, _, last, _)| now - last > RSS_REFRESH_AGE_MS)
                .map(|(id, url, _, _, _)| (id, url))
                .collect()
        };
        for (id, url) in due {
            self.spawn_feed_refresh(id, url);
        }
    }

    // ---- engine event handling -------------------------------------------

    fn handle_engine_event(&self, ev: EngineEvent) {
        match ev {
            EngineEvent::MetadataReceived { infohash } => {
                self.try_complete_join(&infohash);
                self.refresh_torrent_group_name(&infohash);
            }
            EngineEvent::TorrentFinished { infohash } => {
                self.try_complete_join(&infohash);
                self.refresh_torrent_group_name(&infohash);
            }
            EngineEvent::TorrentError { infohash, error } => {
                self.emit_event(
                    "sys.log",
                    json!({"level": "warn", "msg": format!("torrent {infohash}: {error}")}),
                );
            }
            EngineEvent::TorrentRemoved { infohash } => {
                self.emit_event("bt.removed", json!({"infohash": infohash}));
            }
            EngineEvent::TorrentUpdate { .. } => {} // batched by scheduler
            EngineEvent::DhtImmutableItem {
                target,
                found,
                value,
            } => self.on_immutable_item(target, found, value),
            EngineEvent::DhtMutableItem {
                pk,
                salt,
                seq,
                sig,
                value,
                found,
                authoritative: _,
            } => self.on_mutable_item(pk, salt, seq, sig, value, found),
            EngineEvent::DhtPutDone {
                mutable,
                key,
                num_success,
            } => self.on_put_done(mutable, key, num_success),
            EngineEvent::ExtMessage {
                infohash,
                peer,
                payload,
            } => self.on_ext_message(infohash, peer, payload),
            EngineEvent::ChatPeer {
                infohash,
                connected,
                ..
            } => {
                if connected {
                    // greet the new peer with our head set
                    let st = self.inner.state.lock().unwrap();
                    if let Some(gid) = st.by_ih.get(&infohash).cloned() {
                        if let Some(rt) = st.groups.get(&gid) {
                            rt.sync.ext_announce_heads(&*self.inner.engine);
                        }
                    }
                }
            }
            EngineEvent::SessionStats { stats } => {
                self.emit_event(
                    "sys.stats",
                    serde_json::to_value(stats).unwrap_or(json!({})),
                );
            }
            EngineEvent::Log { level, msg } => {
                self.emit_event("sys.log", json!({"level": level, "msg": msg}));
            }
        }
    }

    fn on_immutable_item(&self, target: Sha1Hash, found: bool, value: Vec<u8>) {
        let now = crate::now_ms();
        let own_pk = self.own_pk_hex();
        let mut guard = self.inner.state.lock().unwrap();
        let st = &mut *guard;
        // which group is waiting for this?
        let gid_hex = st
            .groups
            .iter()
            .find(|(_, rt)| rt.sync.is_fetching(&target))
            .map(|(g, _)| g.clone());
        let Some(gid_hex) = gid_hex else {
            return;
        };
        let rt = match st.groups.get_mut(&gid_hex) {
            Some(rt) => rt,
            None => return,
        };
        if !found || value.is_empty() {
            rt.sync.note_fetch_failure(&target, now);
            return;
        }
        rt.sync.clear_fetch_backoff(&target);
        let sm = match verify_message(&value, now) {
            Ok(sm) => sm,
            Err(e) => {
                log::warn!("DHT item failed verification: {e}");
                rt.sync.note_fetch_failure(&target, now);
                return;
            }
        };
        if sm.msg.group != gid_hex {
            log::warn!("DHT item belongs to another group; dropped");
            return;
        }
        let is_own = sm.msg.author_pk == own_pk;
        match rt.sync.ingest(&st.store, sm.clone(), 1) {
            Ok(Some(_)) => {
                rt.sync.dirty_heads = true;
                // publish merged heads + tell peers + continue fetching
                if rt.sync.publish_heads(&st.store, &*self.inner.engine, now) {
                    rt.last_publish = now;
                }
                rt.sync.ext_announce_heads(&*self.inner.engine);
                let backoff = rt.sync.fetch_backoff_table().clone();
                rt.sync
                    .pump_fetches_filtered(&*self.inner.engine, &backoff, now);
                let progress = rt.sync.progress();
                // rt borrow ends here (NLL); release the lock before emitting
                drop(guard);
                if !is_own {
                    self.emit_event(
                        "chat.message_new",
                        json!({"group": gid_hex, "message": sm.msg}),
                    );
                }
                self.emit_event(
                    "chat.sync",
                    serde_json::to_value(progress).unwrap_or(json!({})),
                );
                self.emit_event("chat.group_updated", json!({"group": gid_hex}));
            }
            Ok(None) => {
                // duplicate: still counts as resolved fetch
                let backoff = rt.sync.fetch_backoff_table().clone();
                rt.sync
                    .pump_fetches_filtered(&*self.inner.engine, &backoff, now);
            }
            Err(e) => log::warn!("ingest failed: {e}"),
        }
    }

    fn on_mutable_item(
        &self,
        pk: [u8; 32],
        salt: String,
        seq: i64,
        sig: [u8; 64],
        value: Vec<u8>,
        found: bool,
    ) {
        if !found || value.is_empty() {
            return;
        }
        if !bep44_verify(&pk, seq, &value, salt.as_bytes(), &sig) {
            self.emit_event(
                "sys.log",
                json!({"level": "warn", "msg": "拒绝了签名无效的头指针项"}),
            );
            return;
        }
        let now = crate::now_ms();
        let mut guard = self.inner.state.lock().unwrap();
        let st = &mut *guard;
        let gid_hex = st
            .groups
            .iter()
            .find(|(_, rt)| rt.sync.manifest.head_pk == pk)
            .map(|(g, _)| g.clone());
        let Some(gid_hex) = gid_hex else { return };
        let rt = match st.groups.get_mut(&gid_hex) {
            Some(rt) => rt,
            None => return,
        };
        if seq > rt.sync.head_seq {
            rt.sync.head_seq = seq;
            let _ = st.store.group_update_head_seq(&rt.sync.gid, seq);
        }
        let grew = rt.sync.handle_head_item(seq, &value, &*self.inner.engine);
        // if our view extends the published heads, publish the merge
        let heads = rt.sync.dag.heads();
        let remote: std::collections::HashSet<Sha1Hash> = crate::chat::HeadItem::decode(&value)
            .map(|h| h.heads.into_iter().collect())
            .unwrap_or_default();
        let we_have_more = heads.iter().any(|h| !remote.contains(h));
        rt.sync.dirty_heads |= we_have_more;
        if grew || we_have_more {
            if we_have_more && rt.sync.publish_heads(&st.store, &*self.inner.engine, now) {
                rt.last_publish = now;
                rt.sync.dirty_heads = false;
            }
            rt.sync.ext_announce_heads(&*self.inner.engine);
            let backoff = rt.sync.fetch_backoff_table().clone();
            rt.sync
                .pump_fetches_filtered(&*self.inner.engine, &backoff, now);
        }
    }

    fn on_put_done(&self, mutable: bool, key: String, num_success: i32) {
        let now = crate::now_ms();
        let mut guard = self.inner.state.lock().unwrap();
        let st = &mut *guard;
        if !mutable {
            let Ok(target) = hex20(&key) else { return };
            // the immutable target IS the message id: confirm purely from the
            // store so restarts (empty pending_puts) still converge
            let gid_hex = st
                .store
                .message_group(&target)
                .ok()
                .flatten()
                .map(hex::encode);
            let Some(gid_hex) = gid_hex else { return };
            if num_success > 0 {
                if let Some(rt) = st.groups.get_mut(&gid_hex) {
                    rt.sync.pending_puts.remove(&target);
                }
                st.store.message_state_set(&target, 1).ok();
                st.store.outbox_remove_msg(&target).ok();
                drop(guard);
                self.emit_event(
                    "chat.message_state",
                    json!({"group": gid_hex, "id": key, "state": 1}),
                );
            } else if let Some(rt) = st.groups.get_mut(&gid_hex) {
                rt.sync.dirty_heads = true; // will retry via outbox
                rt.last_publish = now - 3_000;
            }
        } else {
            // mutable head put
            let gid_hex = st
                .groups
                .iter()
                .find(|(_, rt)| hex::encode(rt.sync.manifest.head_pk) == key)
                .map(|(g, _)| g.clone());
            let Some(gid_hex) = gid_hex else { return };
            if num_success == 0 {
                // seq conflict: re-read the authoritative head item; the
                // scheduler republishes once we know the current seq
                if let Some(rt) = st.groups.get_mut(&gid_hex) {
                    rt.sync.dirty_heads = true;
                    rt.sync.poll_heads(&*self.inner.engine, now);
                }
            } else if let Some(rt) = st.groups.get_mut(&gid_hex) {
                rt.sync.dirty_heads = false;
                let progress = rt.sync.progress();
                // rt borrow ends here (NLL); release the lock before emitting
                drop(guard);
                self.emit_event(
                    "chat.sync",
                    serde_json::to_value(progress).unwrap_or(json!({})),
                );
            }
        }
    }

    fn on_ext_message(&self, infohash: String, _peer: String, payload: Vec<u8>) {
        let now = crate::now_ms();
        let gid_hex = {
            let guard = self.inner.state.lock().unwrap();
            guard.by_ih.get(&infohash).cloned()
        };
        let Some(gid_hex) = gid_hex else { return };
        let mut replies: Vec<Vec<u8>> = Vec::new();
        let mut new_msgs = Vec::new();
        {
            let mut guard = self.inner.state.lock().unwrap();
            let st = &mut *guard;
            let Some(rt) = st.groups.get_mut(&gid_hex) else {
                return;
            };
            let engine = &*self.inner.engine;
            rt.sync.handle_ext(
                &st.store,
                engine,
                &payload,
                now,
                &mut replies,
                &mut |_id: &Sha1Hash, m: &crate::chat::ChatMessage| {
                    new_msgs.push(m.clone());
                },
            );
            if rt.sync.dirty_heads {
                if rt.sync.publish_heads(&st.store, &*self.inner.engine, now) {
                    rt.last_publish = now;
                }
                rt.sync.ext_announce_heads(&*self.inner.engine);
                let backoff = rt.sync.fetch_backoff_table().clone();
                rt.sync
                    .pump_fetches_filtered(&*self.inner.engine, &backoff, now);
            }
        }
        for r in replies {
            let _ = self.inner.engine.ext_send(&infohash, &r);
        }
        let had_new = !new_msgs.is_empty();
        let own_pk = self.own_pk_hex();
        let mut invites = Vec::new();
        for m in &new_msgs {
            if let Some(magnet) = dm_invite_for_me(m, &own_pk) {
                invites.push(magnet);
            }
        }
        for m in new_msgs {
            self.emit_event("chat.message_new", json!({"group": gid_hex, "message": m}));
        }
        if had_new {
            self.emit_event("chat.group_updated", json!({"group": gid_hex}));
        }
        for magnet in invites {
            let _ = self.chat_join_dm(json!({"magnet": magnet}));
        }
    }
}

/// If `m` is a DM invite addressed to `own_pk`, extract the magnet.
fn dm_invite_for_me(m: &crate::chat::ChatMessage, own_pk: &str) -> Option<String> {
    match &m.payload {
        crate::chat::message::Payload::System { code, detail } if code == "dm_invite" => {
            let (recipient, magnet) = detail.split_once(' ')?;
            if recipient == own_pk && !m.own {
                Some(magnet.to_string())
            } else {
                None
            }
        }
        _ => None,
    }
}

fn backoff_ms(attempts: i64) -> i64 {
    let exp = attempts.clamp(0, 6) as u32;
    (5_000 * (1 << exp)).min(300_000)
}
