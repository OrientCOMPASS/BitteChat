//! Chat message model: canonical bencode representation, signing and
//! verification, chunking of long texts, and payload types.
//!
//! Wire format (bencoded dict, keys sorted by the canonical encoder):
//! ```text
//! {
//!   "v":   1                     protocol version
//!   "g":   <20B group id>
//!   "p":   [ <20B parent id>, .. ]   (<= 8, git-like DAG links)
//!   "s":   <i64 author sequence>     (per author, per group, increasing)
//!   "t":   <i64 unix millis>
//!   "k":   <32B author ed25519 pubkey>
//!   "n":   <utf8 author display name, <= 64B>
//!   "y":   <int kind>  1=text 2=attachment 3=system 5=chunk-part
//!   "b":   <payload bytes>
//!   "sig": <64B ed25519 over canonical bencode of the dict WITHOUT "sig">
//! }
//! ```
//! The message id is `SHA-1` over the full canonical encoding (including sig).
//! Whole encoded messages must stay <= 1000 bytes so they fit into BEP44
//! immutable DHT items; longer texts are split into chained `y=5` parts.

use serde::{Deserialize, Serialize};

use crate::bencode::{self, Value};
use crate::crypto::{self, Identity, PubKey, Sha1Hash, Sig64};
use crate::{CoreError, Result};

pub const PROTOCOL_VERSION: i64 = 1;
pub const MAX_ENCODED_SIZE: usize = 950; // keep under the 1000B BEP44 limit
pub const MAX_PARENTS: usize = 8;
pub const MAX_NAME_LEN: usize = 64;
/// max bytes of user text per (chunk) message payload
pub const MAX_TEXT_BYTES: usize = 600;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(i64)]
pub enum MsgKind {
    Text = 1,
    Attachment = 2,
    System = 3,
    Chunk = 5,
}

impl MsgKind {
    pub fn from_i64(v: i64) -> Option<MsgKind> {
        match v {
            1 => Some(MsgKind::Text),
            2 => Some(MsgKind::Attachment),
            3 => Some(MsgKind::System),
            5 => Some(MsgKind::Chunk),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AttachmentInfo {
    pub infohash: String, // hex
    pub name: String,
    pub size: i64,
    #[serde(default)]
    pub mime: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChunkInfo {
    pub cid: String, // hex, 8 random bytes shared by all parts
    pub index: i64,  // 1-based
    pub total: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Payload {
    Text { text: String },
    Attachment(AttachmentInfo),
    System { code: String, detail: String },
    Chunk { chunk: ChunkInfo, data: Vec<u8> },
}

/// A parsed and verified chat message.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    pub id: String,           // hex sha1 of canonical bytes
    pub group: String,        // hex gid
    pub parents: Vec<String>, // hex ids
    pub author_seq: i64,
    pub ts: i64,           // unix millis
    pub author_pk: String, // hex
    pub author_name: String,
    pub kind: i64,
    pub payload: Payload,
    /// whether *we* authored this message
    #[serde(default)]
    pub own: bool,
    /// 0 = pending confirmation (outbox), 1 = confirmed (stored in DHT / seen by peers)
    #[serde(default)]
    pub state: i64,
}

/// Raw message bytes + parsed view (kept together in the object store).
#[derive(Debug, Clone)]
pub struct SignedMessage {
    pub bytes: Vec<u8>, // canonical encoding including sig
    pub id: Sha1Hash,
    pub msg: ChatMessage,
}

fn payload_to_bytes(kind: MsgKind, p: &Payload) -> Result<Vec<u8>> {
    Ok(match (kind, p) {
        (MsgKind::Text, Payload::Text { text }) => text.as_bytes().to_vec(),
        (MsgKind::Attachment, Payload::Attachment(a)) => {
            let ih = hex::decode(&a.infohash)
                .map_err(|_| CoreError::Invalid("bad infohash hex".into()))?;
            if ih.len() != 20 {
                return Err(CoreError::Invalid("infohash must be 20 bytes".into()));
            }
            let mut d = Value::dict();
            d.insert("ih", Value::Str(ih));
            d.insert("name", Value::Str(a.name.as_bytes().to_vec()));
            d.insert("size", Value::Int(a.size));
            if !a.mime.is_empty() {
                d.insert("mime", Value::Str(a.mime.as_bytes().to_vec()));
            }
            bencode::encode(&d)
        }
        (MsgKind::System, Payload::System { code, detail }) => {
            let mut d = Value::dict();
            d.insert("st", Value::Str(code.as_bytes().to_vec()));
            if !detail.is_empty() {
                d.insert("d", Value::Str(detail.as_bytes().to_vec()));
            }
            bencode::encode(&d)
        }
        (MsgKind::Chunk, Payload::Chunk { chunk, data }) => {
            let cid =
                hex::decode(&chunk.cid).map_err(|_| CoreError::Invalid("bad chunk id".into()))?;
            let mut d = Value::dict();
            d.insert("cid", Value::Str(cid));
            d.insert("ci", Value::Int(chunk.index));
            d.insert("cn", Value::Int(chunk.total));
            d.insert("d", Value::Str(data.clone()));
            bencode::encode(&d)
        }
        _ => return Err(CoreError::Invalid("kind/payload mismatch".into())),
    })
}

fn payload_from_bytes(kind: MsgKind, b: &[u8]) -> Result<Payload> {
    Ok(match kind {
        MsgKind::Text => Payload::Text {
            text: String::from_utf8(b.to_vec())
                .map_err(|_| CoreError::Invalid("text not utf8".into()))?,
        },
        MsgKind::Attachment => {
            let v = bencode::decode(b)?;
            let ih = v
                .get_bytes("ih")
                .ok_or_else(|| CoreError::Invalid("attachment missing ih".into()))?;
            if ih.len() != 20 {
                return Err(CoreError::Invalid("bad ih length".into()));
            }
            Payload::Attachment(AttachmentInfo {
                infohash: hex::encode(ih),
                name: v.get_str("name").unwrap_or("").to_string(),
                size: v.get_int("size").unwrap_or(0),
                mime: v.get_str("mime").unwrap_or("").to_string(),
            })
        }
        MsgKind::System => {
            let v = bencode::decode(b)?;
            Payload::System {
                code: v.get_str("st").unwrap_or("").to_string(),
                detail: v.get_str("d").unwrap_or("").to_string(),
            }
        }
        MsgKind::Chunk => {
            let v = bencode::decode(b)?;
            let cid = v
                .get_bytes("cid")
                .ok_or_else(|| CoreError::Invalid("chunk missing cid".into()))?;
            Payload::Chunk {
                chunk: ChunkInfo {
                    cid: hex::encode(cid),
                    index: v.get_int("ci").unwrap_or(0),
                    total: v.get_int("cn").unwrap_or(0),
                },
                data: v.get_bytes("d").unwrap_or(&[]).to_vec(),
            }
        }
    })
}

/// Build the canonical dict WITHOUT the signature (the data that gets signed).
#[allow(clippy::too_many_arguments)]
fn unsigned_dict(
    group: &Sha1Hash,
    parents: &[Sha1Hash],
    author_seq: i64,
    ts: i64,
    author: &Identity,
    name: &str,
    kind: MsgKind,
    payload_bytes: &[u8],
) -> Value {
    let mut d = Value::dict();
    d.insert("v", Value::Int(PROTOCOL_VERSION));
    d.insert("g", Value::Str(group.to_vec()));
    d.insert(
        "p",
        Value::List(parents.iter().map(|p| Value::Str(p.to_vec())).collect()),
    );
    d.insert("s", Value::Int(author_seq));
    d.insert("t", Value::Int(ts));
    d.insert("k", Value::Str(author.public_key().to_vec()));
    d.insert("n", Value::Str(name.as_bytes().to_vec()));
    d.insert("y", Value::Int(kind as i64));
    d.insert("b", Value::Str(payload_bytes.to_vec()));
    d
}

/// Create and sign one message. Returns canonical bytes and parsed view.
#[allow(clippy::too_many_arguments)]
pub fn create_message(
    group: &Sha1Hash,
    parents: &[Sha1Hash],
    author_seq: i64,
    ts: i64,
    author: &Identity,
    name: &str,
    kind: MsgKind,
    payload: &Payload,
) -> Result<SignedMessage> {
    if parents.len() > MAX_PARENTS {
        return Err(CoreError::Invalid("too many parents".into()));
    }
    if name.len() > MAX_NAME_LEN {
        return Err(CoreError::Invalid("author name too long".into()));
    }
    let pb = payload_to_bytes(kind, payload)?;
    let unsigned = unsigned_dict(group, parents, author_seq, ts, author, name, kind, &pb);
    let unsigned_bytes = bencode::encode(&unsigned);
    let sig = author.sign(&unsigned_bytes);

    let mut full = unsigned.clone();
    full.insert("sig", Value::Str(sig.to_vec()));
    let bytes = bencode::encode(&full);
    if bytes.len() > MAX_ENCODED_SIZE {
        return Err(CoreError::Invalid(format!(
            "message too large: {} bytes (max {})",
            bytes.len(),
            MAX_ENCODED_SIZE
        )));
    }
    let id = crypto::sha1(&bytes);
    let msg = ChatMessage {
        id: hex::encode(id),
        group: hex::encode(group),
        parents: parents.iter().map(hex::encode).collect(),
        author_seq,
        ts,
        author_pk: hex::encode(author.public_key()),
        author_name: name.to_string(),
        kind: kind as i64,
        payload: payload.clone(),
        own: true,
        state: 0,
    };
    Ok(SignedMessage { bytes, id, msg })
}

/// Parse + fully verify a raw message (as received from DHT or a peer).
/// On success returns the parsed message with `own=false` (caller may adjust)
/// and the canonical bytes (which are guaranteed equal to the input when the
/// input was canonical; non-canonical inputs are rejected).
pub fn verify_message(raw: &[u8], now_ms: i64) -> Result<SignedMessage> {
    if raw.len() > crate::crypto::BEP44_VALUE_LIMIT {
        return Err(CoreError::Invalid("message exceeds DHT item limit".into()));
    }
    let v = bencode::decode(raw)?; // strict decoder: rejects non-canonical input
                                   // re-encoding a strictly decoded value is canonical and must be identical
    if bencode::encode(&v) != raw {
        return Err(CoreError::Invalid("message not canonically encoded".into()));
    }
    if v.get_int("v").unwrap_or(-1) != PROTOCOL_VERSION {
        return Err(CoreError::Invalid("unsupported protocol version".into()));
    }
    let gid = v
        .get_bytes("g")
        .ok_or_else(|| CoreError::Invalid("missing g".into()))?;
    if gid.len() != 20 {
        return Err(CoreError::Invalid("bad group id".into()));
    }
    let parents: Vec<Sha1Hash> = match v.get("p") {
        Some(Value::List(l)) => {
            if l.len() > MAX_PARENTS {
                return Err(CoreError::Invalid("too many parents".into()));
            }
            let mut out = Vec::with_capacity(l.len());
            for p in l {
                let b = p
                    .as_bytes()
                    .ok_or_else(|| CoreError::Invalid("bad parent".into()))?;
                if b.len() != 20 {
                    return Err(CoreError::Invalid("bad parent len".into()));
                }
                let mut h = [0u8; 20];
                h.copy_from_slice(b);
                out.push(h);
            }
            out
        }
        _ => return Err(CoreError::Invalid("missing p".into())),
    };
    let pk_b = v
        .get_bytes("k")
        .ok_or_else(|| CoreError::Invalid("missing k".into()))?;
    if pk_b.len() != 32 {
        return Err(CoreError::Invalid("bad pubkey".into()));
    }
    let mut pk: PubKey = [0u8; 32];
    pk.copy_from_slice(pk_b);
    let sig_b = v
        .get_bytes("sig")
        .ok_or_else(|| CoreError::Invalid("missing sig".into()))?;
    if sig_b.len() != 64 {
        return Err(CoreError::Invalid("bad sig len".into()));
    }
    let mut sig: Sig64 = [0u8; 64];
    sig.copy_from_slice(sig_b);

    // rebuild the unsigned dict (everything except "sig") and verify
    let unsigned = match v.clone() {
        Value::Dict(mut d) => {
            d.remove(&b"sig"[..]);
            Value::Dict(d)
        }
        _ => unreachable!(),
    };
    let unsigned_bytes = bencode::encode(&unsigned);
    if !crypto::verify(&pk, &unsigned_bytes, &sig) {
        return Err(CoreError::Invalid("signature verification failed".into()));
    }

    let ts = v.get_int("t").unwrap_or(0);
    // clock sanity: allow generous skew, reject far-future timestamps
    if ts <= 0 || ts > now_ms + 24 * 3600 * 1000 {
        return Err(CoreError::Invalid("timestamp out of range".into()));
    }
    let name = v.get_str("n").unwrap_or("").to_string();
    if name.len() > MAX_NAME_LEN {
        return Err(CoreError::Invalid("author name too long".into()));
    }
    let kind_i = v.get_int("y").unwrap_or(0);
    let kind =
        MsgKind::from_i64(kind_i).ok_or_else(|| CoreError::Invalid("unknown kind".into()))?;
    let b = v
        .get_bytes("b")
        .ok_or_else(|| CoreError::Invalid("missing b".into()))?;
    let payload = payload_from_bytes(kind, b)?;
    let seq = v.get_int("s").unwrap_or(0);
    if seq < 0 {
        return Err(CoreError::Invalid("negative seq".into()));
    }

    let id = crypto::sha1(raw);
    Ok(SignedMessage {
        bytes: raw.to_vec(),
        id,
        msg: ChatMessage {
            id: hex::encode(id),
            group: hex::encode(gid),
            parents: parents.iter().map(hex::encode).collect(),
            author_seq: seq,
            ts,
            author_pk: hex::encode(pk),
            author_name: name,
            kind: kind_i,
            payload,
            own: false,
            state: 1,
        },
    })
}

/// Parse a raw message WITHOUT signature verification. Only for reading back
/// messages from the local trusted store (they were verified at ingest).
pub fn parse_message_unverified(raw: &[u8], own_pk_hex: &str) -> Result<SignedMessage> {
    let v = bencode::decode(raw)?;
    if bencode::encode(&v) != raw {
        return Err(CoreError::Invalid("message not canonically encoded".into()));
    }
    let gid = v
        .get_bytes("g")
        .ok_or_else(|| CoreError::Invalid("missing g".into()))?;
    let parents: Vec<String> = match v.get("p") {
        Some(Value::List(l)) => l
            .iter()
            .map(|p| {
                p.as_bytes()
                    .map(hex::encode)
                    .ok_or_else(|| CoreError::Invalid("bad parent".into()))
            })
            .collect::<Result<Vec<_>>>()?,
        _ => return Err(CoreError::Invalid("missing p".into())),
    };
    let pk_b = v
        .get_bytes("k")
        .ok_or_else(|| CoreError::Invalid("missing k".into()))?;
    let kind_i = v.get_int("y").unwrap_or(0);
    let kind = MsgKind::from_i64(kind_i).ok_or_else(|| CoreError::Invalid("kind".into()))?;
    let b = v
        .get_bytes("b")
        .ok_or_else(|| CoreError::Invalid("missing b".into()))?;
    let payload = payload_from_bytes(kind, b)?;
    let author_pk = hex::encode(pk_b);
    let id = crypto::sha1(raw);
    Ok(SignedMessage {
        bytes: raw.to_vec(),
        id,
        msg: ChatMessage {
            id: hex::encode(id),
            group: hex::encode(gid),
            parents,
            author_seq: v.get_int("s").unwrap_or(0),
            ts: v.get_int("t").unwrap_or(0),
            author_name: v.get_str("n").unwrap_or("").to_string(),
            author_pk: author_pk.clone(),
            kind: kind_i,
            payload,
            own: author_pk == own_pk_hex,
            state: 1,
        },
    })
}

/// Split user text into a list of (kind, payload) message specs. Short texts
/// become a single `Text` message; long texts become a chain of `Chunk` parts
/// sharing a random chunk id.
pub fn plan_text(text: &str) -> Vec<(MsgKind, Payload)> {
    let bytes = text.as_bytes();
    if bytes.len() <= MAX_TEXT_BYTES {
        return vec![(
            MsgKind::Text,
            Payload::Text {
                text: text.to_string(),
            },
        )];
    }
    // split on UTF-8 char boundaries
    let mut parts: Vec<Vec<u8>> = Vec::new();
    let mut cur: Vec<u8> = Vec::new();
    for ch in text.chars() {
        let mut buf = [0u8; 4];
        let enc = ch.encode_utf8(&mut buf);
        if cur.len() + enc.len() > MAX_TEXT_BYTES {
            parts.push(std::mem::take(&mut cur));
        }
        cur.extend_from_slice(enc.as_bytes());
    }
    if !cur.is_empty() {
        parts.push(cur);
    }
    let cid = {
        let mut c = [0u8; 8];
        rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut c);
        hex::encode(c)
    };
    let total = parts.len() as i64;
    parts
        .into_iter()
        .enumerate()
        .map(|(i, data)| {
            (
                MsgKind::Chunk,
                Payload::Chunk {
                    chunk: ChunkInfo {
                        cid: cid.clone(),
                        index: i as i64 + 1,
                        total,
                    },
                    data,
                },
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gid() -> Sha1Hash {
        [7u8; 20]
    }

    #[test]
    fn create_and_verify_text() {
        let id = Identity::generate();
        let sm = create_message(
            &gid(),
            &[],
            1,
            1_700_000_000_000,
            &id,
            "alice",
            MsgKind::Text,
            &Payload::Text {
                text: "hello world".into(),
            },
        )
        .unwrap();
        let now = 1_700_000_000_000;
        let v = verify_message(&sm.bytes, now + 1000).unwrap();
        assert_eq!(v.id, sm.id);
        assert_eq!(v.msg.author_name, "alice");
        match &v.msg.payload {
            Payload::Text { text } => assert_eq!(text, "hello world"),
            _ => panic!("wrong payload"),
        }
    }

    #[test]
    fn tamper_detection() {
        let id = Identity::generate();
        let mut sm = create_message(
            &gid(),
            &[],
            1,
            1_700_000_000_000,
            &id,
            "alice",
            MsgKind::Text,
            &Payload::Text {
                text: "original".into(),
            },
        )
        .unwrap();
        // flip a byte inside the payload area
        let pos = sm.bytes.windows(8).position(|w| w == b"original").unwrap();
        sm.bytes[pos] = b'X';
        assert!(verify_message(&sm.bytes, 1_700_000_000_001).is_err());
    }

    #[test]
    fn wrong_key_rejected() {
        let a = Identity::generate();
        let b = Identity::generate();
        let sm = create_message(
            &gid(),
            &[],
            1,
            1_700_000_000_000,
            &a,
            "alice",
            MsgKind::Text,
            &Payload::Text { text: "hi".into() },
        )
        .unwrap();
        // re-sign with wrong key but keep original pubkey -> must fail
        let v = bencode::decode(&sm.bytes).unwrap();
        let unsigned = match v {
            Value::Dict(mut d) => {
                d.remove(&b"sig"[..]);
                Value::Dict(d)
            }
            _ => unreachable!(),
        };
        let ub = bencode::encode(&unsigned);
        let bad_sig = b.sign(&ub);
        let mut full = unsigned.as_dict().unwrap().clone();
        full.insert(b"sig".to_vec(), Value::Str(bad_sig.to_vec()));
        let forged = bencode::encode(&Value::Dict(full));
        assert!(verify_message(&forged, 1_700_000_000_001).is_err());
    }

    #[test]
    fn attachment_roundtrip() {
        let id = Identity::generate();
        let att = Payload::Attachment(AttachmentInfo {
            infohash: "aa".repeat(20),
            name: "照片.jpg".into(),
            size: 12345,
            mime: "image/jpeg".into(),
        });
        let sm = create_message(
            &gid(),
            &[[1u8; 20]],
            3,
            1_700_000_000_000,
            &id,
            "bob",
            MsgKind::Attachment,
            &att,
        )
        .unwrap();
        let v = verify_message(&sm.bytes, 1_700_000_000_001).unwrap();
        match &v.msg.payload {
            Payload::Attachment(a) => {
                assert_eq!(a.name, "照片.jpg");
                assert_eq!(a.size, 12345);
                assert_eq!(a.infohash, "aa".repeat(20));
            }
            _ => panic!("wrong payload"),
        }
        assert_eq!(v.msg.parents, vec!["01".repeat(20)]);
    }

    #[test]
    fn chunk_planning() {
        let short = plan_text("hi");
        assert_eq!(short.len(), 1);
        let long: String = "水".repeat(500); // 1500 bytes
        let parts = plan_text(&long);
        assert!(parts.len() >= 3);
        // reassembly
        let mut out = Vec::new();
        for (k, p) in &parts {
            assert_eq!(*k, MsgKind::Chunk);
            match p {
                Payload::Chunk { data, .. } => out.extend_from_slice(data),
                _ => panic!(),
            }
        }
        assert_eq!(String::from_utf8(out).unwrap(), long);
        // each part must fit a signed message
        let id = Identity::generate();
        for (i, (k, p)) in parts.iter().enumerate() {
            let sm = create_message(
                &gid(),
                &[],
                i as i64,
                1_700_000_000_000 + i as i64,
                &id,
                "alice",
                *k,
                p,
            )
            .unwrap();
            assert!(sm.bytes.len() <= MAX_ENCODED_SIZE);
        }
    }

    #[test]
    fn oversize_rejected() {
        let id = Identity::generate();
        let r = create_message(
            &gid(),
            &[],
            1,
            1_700_000_000_000,
            &id,
            "alice",
            MsgKind::Text,
            &Payload::Text {
                text: "x".repeat(900),
            },
        );
        assert!(r.is_err());
    }

    #[test]
    fn far_future_ts_rejected() {
        let id = Identity::generate();
        let sm = create_message(
            &gid(),
            &[],
            1,
            1_700_000_000_000,
            &id,
            "alice",
            MsgKind::Text,
            &Payload::Text { text: "x".into() },
        )
        .unwrap();
        // verify with now far in the past -> ts is > now + 24h -> reject
        assert!(verify_message(&sm.bytes, 1_600_000_000_000).is_err());
    }
}
