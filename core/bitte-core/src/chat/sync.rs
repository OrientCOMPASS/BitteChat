//! Per-group sync engine: keeps the local DAG converged with the DHT and with
//! directly connected peers (bc_chat extension messages).
//!
//! Transport recap:
//!   * every message is a BEP44 *immutable* DHT item (target = message id)
//!   * each group publishes its current head set as a BEP44 *mutable* item
//!     (pk = group head key, salt = "bc1:" + gid), signed, seq-monotonic
//!   * connected peers of the group's manifest swarm exchange `bc_chat`
//!     extension messages for instant push and direct blob transfer
//!   * the DAG (git-like, multi-head, merge by referencing all heads) makes
//!     concurrent posts and even malicious head rollbacks self-healing: any
//!     honest member re-publishes the union of all heads it knows

use std::collections::HashSet;

use serde::Serialize;

use crate::bencode::{self, Value};
use crate::chat::dag::Dag;
use crate::chat::group::{GroupManifest, HeadItem};
use crate::chat::message::{verify_message, SignedMessage};
use crate::crypto::Sha1Hash;
use crate::engine::BtEngine;
use crate::store::Store;

/// Max outstanding immutable-item fetches per group.
const MAX_FETCH_INFLIGHT: usize = 8;
/// Max messages per blob reply.
const MAX_BLOBS_PER_REPLY: usize = 8;
/// Max ext frame we accept (bytes).
const MAX_EXT_PAYLOAD: usize = 64 * 1024;

#[derive(Debug, Clone, Serialize)]
pub struct SyncProgress {
    pub group: String,
    pub total: usize,
    pub missing: usize,
    pub inflight: usize,
    pub heads: usize,
}

/// Wire format of bc_chat extension payloads (bencoded dicts):
///   {m:1, h:[<20B ids>]}          heads announcement
///   {m:2, msg:<raw message>}      direct message push
///   {m:3, w:[<20B ids>]}          request blobs
///   {m:4, b:[<raw message>,..]}   blob reply
#[derive(Debug, Clone)]
pub enum ExtPayload {
    Heads(Vec<Sha1Hash>),
    Msg(Vec<u8>),
    Want(Vec<Sha1Hash>),
    Blobs(Vec<Vec<u8>>),
    /// v2 DM handshake — a signed request carrying the initiator's identity
    /// pubkey, display name and X25519 exchange key. Delivered DIRECTLY to
    /// the addressed peer over a shared group's swarm (never broadcast into
    /// a group DAG, never put to the DHT).
    DmReq {
        gid: Sha1Hash,
        from_pk: String,
        from_name: String,
        from_x: String,
        ts: i64,
        sig: [u8; 64],
    },
    /// Recipient accepted; carries the acceptor's X25519 key (signed).
    DmAccept {
        gid: Sha1Hash,
        x: String,
        ts: i64,
        sig: [u8; 64],
    },
    /// Recipient declined (informational; no signature needed).
    DmReject {
        gid: Sha1Hash,
    },
    /// One signed+encrypted DM ChatMessage (raw canonical bytes).
    DmMsg {
        gid: Sha1Hash,
        msg: Vec<u8>,
    },
    /// Delivery receipt for a DM message id, signed by the RECEIVER — lets
    /// the sender clear its outbox entry.
    DmAck {
        gid: Sha1Hash,
        id: Sha1Hash,
        sig: [u8; 64],
    },
    /// Ask the peer for OUR messages with author_seq > after_seq (gap fill
    /// after offline periods; the reply is a burst of DmMsg frames).
    DmFetch {
        gid: Sha1Hash,
        after_seq: i64,
    },
}

/// Canonical signable body of a DmReq (the "s" field itself excluded).
pub fn dm_req_sig_body(
    gid: &Sha1Hash,
    from_pk: &str,
    from_name: &str,
    from_x: &str,
    ts: i64,
) -> Vec<u8> {
    let mut d = Value::dict();
    d.insert("m", Value::Int(5));
    d.insert("g", Value::Str(gid.to_vec()));
    d.insert("p", Value::Str(from_pk.as_bytes().to_vec()));
    d.insert("n", Value::Str(from_name.as_bytes().to_vec()));
    d.insert("x", Value::Str(from_x.as_bytes().to_vec()));
    d.insert("t", Value::Int(ts));
    bencode::encode(&d)
}

/// Canonical signable body of a DmAccept.
pub fn dm_accept_sig_body(gid: &Sha1Hash, x: &str, ts: i64) -> Vec<u8> {
    let mut d = Value::dict();
    d.insert("m", Value::Int(6));
    d.insert("g", Value::Str(gid.to_vec()));
    d.insert("x", Value::Str(x.as_bytes().to_vec()));
    d.insert("t", Value::Int(ts));
    bencode::encode(&d)
}

/// Canonical signable body of a DmAck.
pub fn dm_ack_sig_body(gid: &Sha1Hash, id: &Sha1Hash) -> Vec<u8> {
    let mut d = Value::dict();
    d.insert("m", Value::Int(8));
    d.insert("g", Value::Str(gid.to_vec()));
    d.insert("i", Value::Str(id.to_vec()));
    bencode::encode(&d)
}

impl ExtPayload {
    pub fn encode(&self) -> Vec<u8> {
        let mut d = Value::dict();
        match self {
            ExtPayload::Heads(h) => {
                d.insert("m", Value::Int(1));
                d.insert(
                    "h",
                    Value::List(h.iter().map(|x| Value::Str(x.to_vec())).collect()),
                );
            }
            ExtPayload::Msg(raw) => {
                d.insert("m", Value::Int(2));
                d.insert("msg", Value::Str(raw.clone()));
            }
            ExtPayload::Want(w) => {
                d.insert("m", Value::Int(3));
                d.insert(
                    "w",
                    Value::List(w.iter().map(|x| Value::Str(x.to_vec())).collect()),
                );
            }
            ExtPayload::Blobs(b) => {
                d.insert("m", Value::Int(4));
                d.insert(
                    "b",
                    Value::List(b.iter().map(|x| Value::Str(x.clone())).collect()),
                );
            }
            ExtPayload::DmReq {
                gid,
                from_pk,
                from_name,
                from_x,
                ts,
                sig,
            } => {
                d.insert("m", Value::Int(5));
                d.insert("g", Value::Str(gid.to_vec()));
                d.insert("p", Value::Str(from_pk.as_bytes().to_vec()));
                d.insert("n", Value::Str(from_name.as_bytes().to_vec()));
                d.insert("x", Value::Str(from_x.as_bytes().to_vec()));
                d.insert("t", Value::Int(*ts));
                d.insert("s", Value::Str(sig.to_vec()));
            }
            ExtPayload::DmAccept { gid, x, ts, sig } => {
                d.insert("m", Value::Int(6));
                d.insert("g", Value::Str(gid.to_vec()));
                d.insert("x", Value::Str(x.as_bytes().to_vec()));
                d.insert("t", Value::Int(*ts));
                d.insert("s", Value::Str(sig.to_vec()));
            }
            ExtPayload::DmReject { gid } => {
                d.insert("m", Value::Int(9));
                d.insert("g", Value::Str(gid.to_vec()));
            }
            ExtPayload::DmMsg { gid, msg } => {
                d.insert("m", Value::Int(7));
                d.insert("g", Value::Str(gid.to_vec()));
                d.insert("msg", Value::Str(msg.clone()));
            }
            ExtPayload::DmAck { gid, id, sig } => {
                d.insert("m", Value::Int(8));
                d.insert("g", Value::Str(gid.to_vec()));
                d.insert("i", Value::Str(id.to_vec()));
                d.insert("s", Value::Str(sig.to_vec()));
            }
            ExtPayload::DmFetch { gid, after_seq } => {
                d.insert("m", Value::Int(10));
                d.insert("g", Value::Str(gid.to_vec()));
                d.insert("q", Value::Int(*after_seq));
            }
        }
        bencode::encode(&d)
    }

    pub fn decode(bytes: &[u8]) -> Option<ExtPayload> {
        if bytes.len() > MAX_EXT_PAYLOAD {
            return None;
        }
        let v = bencode::decode(bytes).ok()?;
        let ids = |key: &str| -> Option<Vec<Sha1Hash>> {
            let l = v.get(key)?.as_list()?;
            let mut out = Vec::with_capacity(l.len());
            for e in l {
                let b = e.as_bytes()?;
                if b.len() != 20 {
                    return None;
                }
                let mut h = [0u8; 20];
                h.copy_from_slice(b);
                out.push(h);
            }
            Some(out)
        };
        match v.get_int("m")? {
            1 => Some(ExtPayload::Heads(ids("h")?)),
            2 => Some(ExtPayload::Msg(v.get_bytes("msg")?.to_vec())),
            3 => Some(ExtPayload::Want(ids("w")?)),
            4 => {
                let l = v.get("b")?.as_list()?;
                if l.len() > MAX_BLOBS_PER_REPLY {
                    return None;
                }
                let mut out = Vec::with_capacity(l.len());
                for e in l {
                    out.push(e.as_bytes()?.to_vec());
                }
                Some(ExtPayload::Blobs(out))
            }
            5 => {
                let sig = fixed64(v.get_bytes("s")?)?;
                Some(ExtPayload::DmReq {
                    gid: hash_field(&v, "g")?,
                    from_pk: hex_field(&v, "p", 64)?,
                    from_name: String::from_utf8_lossy(v.get_bytes("n")?).into_owned(),
                    from_x: hex_field(&v, "x", 64)?,
                    ts: v.get_int("t").unwrap_or(0),
                    sig,
                })
            }
            6 => {
                let sig = fixed64(v.get_bytes("s")?)?;
                Some(ExtPayload::DmAccept {
                    gid: hash_field(&v, "g")?,
                    x: hex_field(&v, "x", 64)?,
                    ts: v.get_int("t").unwrap_or(0),
                    sig,
                })
            }
            7 => Some(ExtPayload::DmMsg {
                gid: hash_field(&v, "g")?,
                msg: v.get_bytes("msg")?.to_vec(),
            }),
            8 => {
                let sig = fixed64(v.get_bytes("s")?)?;
                Some(ExtPayload::DmAck {
                    gid: hash_field(&v, "g")?,
                    id: hash_field(&v, "i")?,
                    sig,
                })
            }
            9 => Some(ExtPayload::DmReject {
                gid: hash_field(&v, "g")?,
            }),
            10 => Some(ExtPayload::DmFetch {
                gid: hash_field(&v, "g")?,
                after_seq: v.get_int("q").unwrap_or(0),
            }),
            _ => None,
        }
    }
}

fn hash_field(v: &Value, key: &str) -> Option<Sha1Hash> {
    let b = v.get_bytes(key)?;
    if b.len() != 20 {
        return None;
    }
    let mut h = [0u8; 20];
    h.copy_from_slice(b);
    Some(h)
}

fn hex_field(v: &Value, key: &str, len: usize) -> Option<String> {
    let b = v.get_bytes(key)?;
    if b.len() != len {
        return None;
    }
    let s = std::str::from_utf8(b).ok()?.to_string();
    if s.chars().all(|c| c.is_ascii_hexdigit()) {
        Some(s)
    } else {
        None
    }
}

fn fixed64(b: &[u8]) -> Option<[u8; 64]> {
    if b.len() != 64 {
        return None;
    }
    let mut a = [0u8; 64];
    a.copy_from_slice(b);
    Some(a)
}

pub struct GroupSync {
    pub gid: Sha1Hash,
    pub manifest: GroupManifest,
    pub dag: Dag,
    /// seq of the head item we last saw or published
    pub head_seq: i64,
    /// immutable gets in flight
    fetching: HashSet<Sha1Hash>,
    /// failed immutable lookups: id -> retry after (unix ms)
    fetch_backoff_ts: std::collections::HashMap<Sha1Hash, i64>,
    /// message ids whose immutable put we still await confirmation for
    pub pending_puts: HashSet<Sha1Hash>,
    /// local heads not yet published to DHT/peers
    pub dirty_heads: bool,
    pub last_head_poll: i64,
    /// recently re-broadcast message ids (gossip loop guard)
    rebroadcast_seen: HashSet<Sha1Hash>,
    /// manifest torrent infohash (hex) of this group's swarm
    pub swarm_ih: String,
}

impl GroupSync {
    pub fn new(
        gid: Sha1Hash,
        manifest: GroupManifest,
        head_seq: i64,
        swarm_ih: String,
    ) -> GroupSync {
        GroupSync {
            gid,
            manifest,
            dag: Dag::new(),
            head_seq,
            fetching: HashSet::new(),
            fetch_backoff_ts: std::collections::HashMap::new(),
            pending_puts: HashSet::new(),
            dirty_heads: false,
            last_head_poll: 0,
            rebroadcast_seen: HashSet::new(),
            swarm_ih,
        }
    }

    pub fn manifest_ih_hex(&self) -> &str {
        &self.swarm_ih
    }

    pub fn progress(&self) -> SyncProgress {
        SyncProgress {
            group: hex::encode(self.gid),
            total: self.dag.len(),
            missing: self.dag.missing_count(),
            inflight: self.fetching.len(),
            heads: self.dag.heads().len(),
        }
    }

    /// Queue immutable gets for everything missing (bounded inflight).
    pub fn pump_fetches(&mut self, engine: &dyn BtEngine) {
        self.pump_fetches_filtered(engine, &std::collections::HashMap::new(), 0);
    }

    /// Like `pump_fetches` but skips hashes in recent-failure backoff
    /// (`id -> retry-after unix ms`).
    pub fn pump_fetches_filtered(
        &mut self,
        engine: &dyn BtEngine,
        backoff: &std::collections::HashMap<Sha1Hash, i64>,
        now_ms: i64,
    ) {
        let missing = self.dag.missing();
        for id in missing {
            if self.fetching.len() >= MAX_FETCH_INFLIGHT {
                break;
            }
            if self.fetching.contains(&id) {
                continue;
            }
            if let Some(until) = backoff.get(&id) {
                if *until > now_ms {
                    continue;
                }
            }
            if engine.dht_get_immutable(&id).is_ok() {
                self.fetching.insert(id);
            }
        }
    }

    /// Record a failed lookup so we don't hammer the DHT.
    pub fn note_fetch_failure(&mut self, id: &Sha1Hash, now_ms: i64) {
        self.fetching.remove(id);
        // exponential backoff: 15s doubling up to 5 minutes
        let prev = self.fetch_backoff_ts.get(id).copied().unwrap_or(0);
        let wait = if prev <= now_ms {
            now_ms + 15_000
        } else {
            (prev + (prev - now_ms)).min(now_ms + 300_000)
        };
        self.fetch_backoff_ts.insert(*id, wait);
    }

    /// Forget a backoff entry after a successful fetch.
    pub fn clear_fetch_backoff(&mut self, id: &Sha1Hash) {
        self.fetch_backoff_ts.remove(id);
    }

    /// Whether an immutable get for this id is in flight.
    pub fn is_fetching(&self, id: &Sha1Hash) -> bool {
        self.fetching.contains(id)
    }

    /// Backoff table accessor for the scheduler.
    pub fn fetch_backoff_table(&self) -> &std::collections::HashMap<Sha1Hash, i64> {
        &self.fetch_backoff_ts
    }

    /// Ask the DHT for the group's head item.
    pub fn poll_heads(&mut self, engine: &dyn BtEngine, now_ms: i64) {
        self.last_head_poll = now_ms;
        let _ = engine.dht_get_mutable(&self.manifest.head_pk, &self.manifest.head_salt());
    }

    /// Announce our heads to connected peers (cheap, no DHT write).
    pub fn ext_announce_heads(&self, engine: &dyn BtEngine) {
        let heads = self.dag.heads();
        if heads.is_empty() {
            return;
        }
        let payload = ExtPayload::Heads(heads).encode();
        let _ = engine.ext_send(&self.swarm_ih, &payload);
    }

    /// Publish the local head set to the DHT mutable item.
    pub fn publish_heads(&mut self, store: &Store, engine: &dyn BtEngine, now_ms: i64) -> bool {
        let heads = self.dag.heads();
        if heads.is_empty() {
            return false;
        }
        let item = HeadItem { heads, ts: now_ms };
        let value = item.encode();
        let seq = self.head_seq + 1;
        let head_id = self.manifest.head_identity();
        let salt = self.manifest.head_salt();
        let sig = crate::crypto::bep44_sign(&head_id, seq, &value, salt.as_bytes());
        match engine.dht_put_mutable(&self.manifest.head_pk, &salt, seq, &sig, &value) {
            Ok(()) => {
                self.head_seq = seq;
                self.dirty_heads = false;
                let _ = store.group_update_head_seq(&self.gid, seq);
                let _ = store.heads_replace(&self.gid, &self.dag.heads());
                true
            }
            Err(e) => {
                log::warn!("publish_heads failed: {e}");
                false
            }
        }
    }

    /// Store a verified message into DAG + persistent store. Returns Some(id)
    /// when the message was new.
    pub fn ingest(
        &mut self,
        store: &Store,
        sm: SignedMessage,
        state: i64,
    ) -> crate::Result<Option<Sha1Hash>> {
        // DM channels only accept messages from the two parties
        if let Some((a, b)) = &self.manifest.dm {
            let author = match hex::decode(&sm.msg.author_pk) {
                Ok(v) if v.len() == 32 => v,
                _ => return Ok(None),
            };
            if author != a.k.to_vec() && author != b.k.to_vec() {
                return Err(crate::CoreError::Invalid(
                    "DM message from non-member".into(),
                ));
            }
        }
        let id = sm.id;
        self.fetching.remove(&id);
        let is_new = store.insert_message(&self.gid, &sm, state)?;
        if !is_new && self.dag.contains(&id) {
            return Ok(None);
        }
        match self.dag.insert(id, sm.msg.clone(), sm.bytes.clone())? {
            crate::chat::dag::InsertOutcome::New => {
                // v0.5.2: group names are LOCAL notes — a "rename" system
                // message from a peer (legacy chain) is stored but no longer
                // applied to our display name
                let _ = store.missing_replace(&self.gid, &self.dag.missing());
                if self.pending_puts.remove(&id) {
                    // our own message confirmed round-trip
                    let _ = store.message_state_set(&id, 1);
                }
                Ok(Some(id))
            }
            crate::chat::dag::InsertOutcome::Duplicate => Ok(None),
        }
    }

    /// Handle a heads list learned from the DHT head item or an ext message.
    /// Returns true if new fetch work was queued.
    pub fn adopt_heads(&mut self, heads: &[Sha1Hash], engine: &dyn BtEngine) -> bool {
        let mut new_work = false;
        for h in heads {
            if !self.dag.contains(h)
                && !self.fetching.contains(h)
                && engine.dht_get_immutable(h).is_ok()
            {
                self.fetching.insert(*h);
                new_work = true;
            }
        }
        new_work
    }

    /// Handle an incoming ext payload from a peer. `reply` collects payloads
    /// to send back to that peer.
    pub fn handle_ext(
        &mut self,
        store: &Store,
        engine: &dyn BtEngine,
        payload: &[u8],
        now_ms: i64,
        reply: &mut Vec<Vec<u8>>,
        on_new_msg: &mut impl FnMut(&Sha1Hash, &crate::chat::message::ChatMessage),
    ) {
        let Some(ext) = ExtPayload::decode(payload) else {
            log::debug!("undecodable ext payload ({} bytes)", payload.len());
            return;
        };
        match ext {
            ExtPayload::Heads(heads) => {
                if self.adopt_heads(&heads, engine) {
                    // tell the peer what we have that it might not
                    reply.push(ExtPayload::Heads(self.dag.heads()).encode());
                }
                self.dirty_heads |= !heads_empty_or_subset(&heads, &self.dag.heads());
            }
            ExtPayload::Msg(raw) => {
                if let Ok(sm) = verify_message(&raw, now_ms) {
                    if sm.msg.group != hex::encode(self.gid) {
                        return;
                    }
                    let id = sm.id;
                    if self.rebroadcast_seen.len() > 4096 {
                        self.rebroadcast_seen.clear();
                    }
                    let already = self.rebroadcast_seen.contains(&id);
                    if let Ok(Some(_)) = self.ingest(store, sm.clone(), 1) {
                        self.dirty_heads = true;
                        on_new_msg(&id, &sm.msg);
                        // gossip one hop to other peers (loop-guarded)
                        if !already {
                            self.rebroadcast_seen.insert(id);
                            let fwd = ExtPayload::Msg(raw).encode();
                            let _ = engine.ext_send(&self.swarm_ih, &fwd);
                        }
                    }
                }
            }
            ExtPayload::Want(wants) => {
                let mut blobs = Vec::new();
                for w in wants.into_iter().take(MAX_BLOBS_PER_REPLY) {
                    if let Some(raw) = self.dag.raw(&w) {
                        blobs.push(raw.to_vec());
                    }
                }
                if !blobs.is_empty() {
                    reply.push(ExtPayload::Blobs(blobs).encode());
                }
            }
            ExtPayload::Blobs(blobs) => {
                for raw in blobs {
                    if let Ok(sm) = verify_message(&raw, now_ms) {
                        if sm.msg.group != hex::encode(self.gid) {
                            continue;
                        }
                        if let Ok(Some(id)) = self.ingest(store, sm.clone(), 1) {
                            self.dirty_heads = true;
                            on_new_msg(&id, &sm.msg);
                        }
                    }
                }
            }
            // DM frames (DmReq/DmAccept/DmMsg/DmAck/DmReject/DmFetch) are
            // routed by channel gid at the API layer, never through a room's
            // GroupSync
            ExtPayload::DmReq { .. }
            | ExtPayload::DmAccept { .. }
            | ExtPayload::DmReject { .. }
            | ExtPayload::DmMsg { .. }
            | ExtPayload::DmAck { .. }
            | ExtPayload::DmFetch { .. } => {}
        }
    }

    /// Handle a verified mutable head item from the DHT.
    pub fn handle_head_item(&mut self, seq: i64, value: &[u8], engine: &dyn BtEngine) -> bool {
        if seq > self.head_seq {
            self.head_seq = seq;
        }
        let Ok(item) = HeadItem::decode(value) else {
            return false;
        };
        self.adopt_heads(&item.heads, engine)
    }

    /// Called after DAG grew: request anything still missing.
    pub fn after_growth(&mut self, engine: &dyn BtEngine) {
        self.pump_fetches(engine);
    }
}

fn heads_empty_or_subset(a: &[Sha1Hash], b: &[Sha1Hash]) -> bool {
    let sb: HashSet<Sha1Hash> = b.iter().copied().collect();
    a.iter().all(|x| sb.contains(x))
}

/// Rebuild a GroupSync's DAG from the persistent store (startup path).
pub fn rebuild_dag(store: &Store, gid: &Sha1Hash, own_pk_hex: &str) -> crate::Result<Dag> {
    let mut dag = Dag::new();
    for sm in store.messages_of_group(gid, own_pk_hex)? {
        let _ = dag.insert(sm.id, sm.msg, sm.bytes);
    }
    Ok(dag)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chat::message::{create_message, MsgKind, Payload};
    use crate::crypto::Identity;

    #[test]
    fn ext_payload_roundtrip() {
        let h = vec![[1u8; 20], [2u8; 20]];
        let enc = ExtPayload::Heads(h.clone()).encode();
        match ExtPayload::decode(&enc).unwrap() {
            ExtPayload::Heads(x) => assert_eq!(x, h),
            _ => panic!(),
        }
        let raw = b"some message bytes".to_vec();
        let enc = ExtPayload::Msg(raw.clone()).encode();
        match ExtPayload::decode(&enc).unwrap() {
            ExtPayload::Msg(x) => assert_eq!(x, raw),
            _ => panic!(),
        }
        let blobs = vec![b"a".to_vec(), b"bb".to_vec()];
        let enc = ExtPayload::Blobs(blobs.clone()).encode();
        match ExtPayload::decode(&enc).unwrap() {
            ExtPayload::Blobs(x) => assert_eq!(x, blobs),
            _ => panic!(),
        }
        assert!(ExtPayload::decode(b"garbage").is_none());
    }

    #[test]
    fn head_item_via_sync() {
        let head = Identity::generate();
        let manifest = GroupManifest::new("g", "c", &Identity::generate(), &head, vec![]).unwrap();
        let mut sync = GroupSync::new(manifest.gid, manifest, 0, "ih".into());
        let item = HeadItem {
            heads: vec![[5u8; 20]],
            ts: 99,
        };
        let value = item.encode();
        // without an engine we just check decoding path via handle_head_item
        let bus = crate::mock::MockBus::new();
        let (eng, _rx) = crate::mock::MockEngine::new(bus);
        // unknown head triggers a fetch attempt (mock has no item -> will
        // answer not found asynchronously); just make sure no panic
        let _ = sync.handle_head_item(7, &value, &eng);
        assert_eq!(sync.head_seq, 7);
    }

    #[test]
    fn ingest_and_publish_cycle() {
        let bus = crate::mock::MockBus::new();
        let (eng, _rx) = crate::mock::MockEngine::new(bus.clone());
        let store = Store::open_in_memory().unwrap();
        let head = Identity::generate();
        let author = Identity::generate();
        let manifest = GroupManifest::new("g", "c", &author, &head, vec![]).unwrap();
        let mut sync = GroupSync::new(manifest.gid, manifest, 0, "ih".into());
        let now = crate::now_ms();
        let sm = create_message(
            &sync.gid,
            &[],
            1,
            now,
            &author,
            "alice",
            MsgKind::Text,
            &Payload::Text {
                text: "hello".into(),
            },
        )
        .unwrap();
        let id = sm.id;
        sync.pending_puts.insert(id);
        assert!(sync.ingest(&store, sm, 0).unwrap().is_some());
        assert!(!sync.pending_puts.contains(&id));
        assert_eq!(sync.dag.heads(), vec![id]);
        assert!(sync.publish_heads(&store, &eng, now));
        assert_eq!(sync.head_seq, 1);
        assert!(!sync.dirty_heads);
    }
}

#[cfg(test)]
mod dm_payload_tests {
    use super::*;
    use crate::crypto::Identity;

    #[test]
    fn dm_req_roundtrip_and_sig() {
        let id = Identity::generate();
        let pk = hex::encode(id.public_key());
        let xs = crate::crypto::x_secret_from_seed(&id.seed);
        let x = hex::encode(crate::crypto::x_public(&xs));
        let gid = [7u8; 20];
        let now = 1234;
        let body = dm_req_sig_body(&gid, &pk, "名字", &x, now);
        let sig = id.sign(&body);
        let p = ExtPayload::DmReq {
            gid,
            from_pk: pk.clone(),
            from_name: "名字".into(),
            from_x: x.clone(),
            ts: now,
            sig,
        };
        let enc = p.encode();
        let dec = ExtPayload::decode(&enc).expect("dm req must roundtrip");
        match dec {
            ExtPayload::DmReq {
                gid: g2,
                from_pk: p2,
                from_name: n2,
                from_x: x2,
                ts: t2,
                sig: s2,
            } => {
                assert_eq!(g2, gid);
                assert_eq!(p2, pk);
                assert_eq!(n2, "名字");
                assert_eq!(x2, x);
                assert_eq!(t2, now);
                assert_eq!(s2, sig);
                assert!(crate::crypto::verify(
                    &id.public_key(),
                    &dm_req_sig_body(&g2, &p2, &n2, &x2, t2),
                    &s2
                ));
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn dm_msg_ack_fetch_roundtrip() {
        let gid = [3u8; 20];
        let id = [9u8; 20];
        let p = ExtPayload::DmMsg {
            gid,
            msg: vec![1, 2, 3],
        };
        assert!(matches!(
            ExtPayload::decode(&p.encode()).unwrap(),
            ExtPayload::DmMsg { gid: g, msg } if g == gid && msg == vec![1, 2, 3]
        ));
        let sig = [5u8; 64];
        let p = ExtPayload::DmAck { gid, id, sig };
        assert!(matches!(
            ExtPayload::decode(&p.encode()).unwrap(),
            ExtPayload::DmAck { gid: g, id: i, sig: s } if g == gid && i == id && s == sig
        ));
        let p = ExtPayload::DmFetch { gid, after_seq: 42 };
        assert!(matches!(
            ExtPayload::decode(&p.encode()).unwrap(),
            ExtPayload::DmFetch { gid: g, after_seq } if g == gid && after_seq == 42
        ));
        let p = ExtPayload::DmReject { gid };
        assert!(matches!(
            ExtPayload::decode(&p.encode()).unwrap(),
            ExtPayload::DmReject { gid: g } if g == gid
        ));
    }
}
