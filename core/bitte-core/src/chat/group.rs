//! Group manifests.
//!
//! Two kinds of channels exist:
//!   * **torrent rooms** (the normal case): ANY BitTorrent torrent is a chat
//!     room. The room id is the torrent infohash and the head-signing key is
//!     derived deterministically from it ([`GroupManifest::for_torrent`]) —
//!     no manifest file is exchanged at all; the synthesized manifest only
//!     exists in-memory / in the local store to reuse the sync machinery.
//!   * **DM channels**: a small `bitte-group.benc` manifest torrent carrying
//!     both parties' identity + X25519 keys ([`GroupManifest::new`] with the
//!     `dm` field set). Possession of its magnet link is the membership
//!     capability; message bodies are E2E encrypted.

use serde::{Deserialize, Serialize};

use crate::bencode::{self, Value};
use crate::crypto::{Identity, PubKey, Seed, Sha1Hash};
use crate::{CoreError, Result, HEAD_SALT_PREFIX, MANIFEST_FILE};

pub const MANIFEST_VERSION: i64 = 1;
pub const MAX_GROUP_NAME_LEN: usize = 96;
pub const MAX_AVATAR_LEN: usize = 8 * 1024;

/// Truncate a display name to at most MAX_GROUP_NAME_LEN bytes on a char
/// boundary (torrent names can be arbitrarily long).
pub fn clamp_name(name: &str) -> String {
    let trimmed = name.trim();
    if trimmed.len() <= MAX_GROUP_NAME_LEN {
        return trimmed.to_string();
    }
    let mut end = MAX_GROUP_NAME_LEN;
    while end > 0 && !trimmed.is_char_boundary(end) {
        end -= 1;
    }
    trimmed[..end].to_string()
}

/// One side of a DM channel: ed25519 identity + x25519 exchange key.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DmParty {
    pub k: PubKey,
    pub x: [u8; 32],
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GroupManifest {
    pub gid: Sha1Hash,
    pub name: String,
    #[serde(default, with = "serde_bytes_b64")]
    pub avatar: Vec<u8>,
    pub created: i64,
    pub creator_pk: PubKey,
    pub creator_name: String,
    pub head_pk: PubKey,
    pub head_seed: Seed,
    /// present for private (DM) channels: both parties' identity+exchange keys
    #[serde(default)]
    pub dm: Option<(DmParty, DmParty)>,
}

mod serde_bytes_b64 {
    use base64::Engine as _;
    use serde::{Deserialize, Deserializer, Serializer};
    pub fn serialize<S: Serializer>(v: &Vec<u8>, s: S) -> std::result::Result<S::Ok, S::Error> {
        s.serialize_str(&base64::engine::general_purpose::STANDARD.encode(v))
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<Vec<u8>, D::Error> {
        let s = String::deserialize(d)?;
        if s.is_empty() {
            return Ok(Vec::new());
        }
        base64::engine::general_purpose::STANDARD
            .decode(s.as_bytes())
            .map_err(serde::de::Error::custom)
    }
}

impl GroupManifest {
    pub fn new(
        name: &str,
        creator_name: &str,
        creator: &Identity,
        head: &Identity,
        avatar: Vec<u8>,
    ) -> Result<GroupManifest> {
        let trimmed = name.trim();
        if trimmed.is_empty() || trimmed.len() > MAX_GROUP_NAME_LEN {
            return Err(CoreError::Invalid("group name empty or too long".into()));
        }
        if avatar.len() > MAX_AVATAR_LEN {
            return Err(CoreError::Invalid("avatar too large".into()));
        }
        let mut gid = [0u8; 20];
        rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut gid);
        Ok(GroupManifest {
            gid,
            name: trimmed.to_string(),
            avatar,
            created: crate::now_ms(),
            creator_pk: creator.public_key(),
            creator_name: creator_name.chars().take(32).collect(),
            head_pk: head.public_key(),
            head_seed: head.seed,
            dm: None,
        })
    }

    pub fn is_dm(&self) -> bool {
        self.dm.is_some()
    }

    /// Synthesize the channel descriptor of a **torrent room**: any torrent
    /// is a chat room, its infohash is the room id (`gid`) and the BEP44
    /// head-signing keypair is derived from it, so every peer of the swarm
    /// can independently reconstruct the same manifest. `name` is the
    /// torrent's display name (updated when metadata arrives).
    pub fn for_torrent(ih: &Sha1Hash, name: &str) -> GroupManifest {
        let head_seed = crate::crypto::torrent_head_seed(ih);
        let head = Identity::from_seed(head_seed);
        let display = clamp_name(name);
        let ih_hex = hex::encode(ih);
        let display = if display.is_empty() {
            format!("种子 {}", &ih_hex[..8])
        } else {
            display
        };
        GroupManifest {
            gid: *ih,
            name: display,
            avatar: Vec::new(),
            created: crate::now_ms(),
            creator_pk: [0u8; 32],
            creator_name: String::new(),
            head_pk: head.public_key(),
            head_seed,
            dm: None,
        }
    }

    /// True for torrent rooms (gid == the swarm torrent's infohash, no DM).
    /// For DM channels the gid is derived from both parties' keys and never
    /// equals the manifest torrent's infohash.
    pub fn is_torrent_room(&self) -> bool {
        !self.is_dm() && self.creator_pk == [0u8; 32]
    }

    /// The DM peer that is not `me`.
    pub fn dm_peer(&self, me: &PubKey) -> Option<&DmParty> {
        let (a, b) = self.dm.as_ref()?;
        if &a.k == me {
            Some(b)
        } else if &b.k == me {
            Some(a)
        } else {
            None
        }
    }

    /// Deterministic channel id for a DM between two ed25519 identities.
    pub fn dm_gid(a: &PubKey, b: &PubKey) -> Sha1Hash {
        let (lo, hi) = if a <= b { (a, b) } else { (b, a) };
        let mut buf = Vec::with_capacity(64 + 8);
        buf.extend_from_slice(lo);
        buf.extend_from_slice(hi);
        buf.extend_from_slice(b"bc-dm-1");
        crate::crypto::sha1(&buf)
    }

    pub fn head_identity(&self) -> Identity {
        Identity::from_seed(self.head_seed)
    }

    pub fn gid_hex(&self) -> String {
        hex::encode(self.gid)
    }

    /// BEP44 salt for this group's head item.
    pub fn head_salt(&self) -> String {
        format!("{}{}", HEAD_SALT_PREFIX, self.gid_hex())
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut d = Value::dict();
        d.insert("v", Value::Int(MANIFEST_VERSION));
        d.insert("gid", Value::Str(self.gid.to_vec()));
        d.insert("name", Value::Str(self.name.as_bytes().to_vec()));
        if !self.avatar.is_empty() {
            d.insert("avatar", Value::Str(self.avatar.clone()));
        }
        d.insert("created", Value::Int(self.created));
        let mut creator = Value::dict();
        creator.insert("k", Value::Str(self.creator_pk.to_vec()));
        creator.insert("n", Value::Str(self.creator_name.as_bytes().to_vec()));
        d.insert("creator", creator);
        let mut head = Value::dict();
        head.insert("k", Value::Str(self.head_pk.to_vec()));
        head.insert("s", Value::Str(self.head_seed.to_vec()));
        d.insert("head", head);
        if let Some((a, b)) = &self.dm {
            let mut dm = Value::dict();
            let mut pa = Value::dict();
            pa.insert("k", Value::Str(a.k.to_vec()));
            pa.insert("x", Value::Str(a.x.to_vec()));
            let mut pb = Value::dict();
            pb.insert("k", Value::Str(b.k.to_vec()));
            pb.insert("x", Value::Str(b.x.to_vec()));
            dm.insert("a", pa);
            dm.insert("b", pb);
            d.insert("dm", dm);
        }
        bencode::encode(&d)
    }

    pub fn decode(bytes: &[u8]) -> Result<GroupManifest> {
        let v = bencode::decode(bytes)?;
        if v.get_int("v").unwrap_or(-1) != MANIFEST_VERSION {
            return Err(CoreError::Invalid("unsupported manifest version".into()));
        }
        let gid_b = v
            .get_bytes("gid")
            .ok_or_else(|| CoreError::Invalid("manifest missing gid".into()))?;
        if gid_b.len() != 20 {
            return Err(CoreError::Invalid("bad gid".into()));
        }
        let mut gid = [0u8; 20];
        gid.copy_from_slice(gid_b);
        let name = v
            .get_str("name")
            .ok_or_else(|| CoreError::Invalid("manifest missing name".into()))?
            .to_string();
        if name.len() > MAX_GROUP_NAME_LEN {
            return Err(CoreError::Invalid("group name too long".into()));
        }
        let avatar = v.get_bytes("avatar").unwrap_or(&[]).to_vec();
        if avatar.len() > MAX_AVATAR_LEN {
            return Err(CoreError::Invalid("avatar too large".into()));
        }
        let created = v.get_int("created").unwrap_or(0);
        let creator = v
            .get("creator")
            .ok_or_else(|| CoreError::Invalid("manifest missing creator".into()))?;
        let creator_pk = pk32(creator.get_bytes("k"), "creator.k")?;
        let creator_name = creator.get_str("n").unwrap_or("").to_string();
        let head = v
            .get("head")
            .ok_or_else(|| CoreError::Invalid("manifest missing head".into()))?;
        let head_pk = pk32(head.get_bytes("k"), "head.k")?;
        let head_seed_b = head
            .get_bytes("s")
            .ok_or_else(|| CoreError::Invalid("head missing seed".into()))?;
        if head_seed_b.len() != 32 {
            return Err(CoreError::Invalid("bad head seed".into()));
        }
        let mut head_seed = [0u8; 32];
        head_seed.copy_from_slice(head_seed_b);
        // consistency: head pubkey must match the seed
        let derived = Identity::from_seed(head_seed);
        if derived.public_key() != head_pk {
            return Err(CoreError::Invalid("head key/seed mismatch".into()));
        }
        let dm = match v.get("dm") {
            Some(dmv) => {
                let pa = dmv
                    .get("a")
                    .ok_or_else(|| CoreError::Invalid("dm missing a".into()))?;
                let pb = dmv
                    .get("b")
                    .ok_or_else(|| CoreError::Invalid("dm missing b".into()))?;
                let parse = |p: &Value, tag: &str| -> Result<DmParty> {
                    let k = pk32(p.get_bytes("k"), tag)?;
                    let xb = p
                        .get_bytes("x")
                        .ok_or_else(|| CoreError::Invalid(format!("dm {tag} missing x")))?;
                    if xb.len() != 32 {
                        return Err(CoreError::Invalid(format!("dm {tag} bad x")));
                    }
                    let mut x = [0u8; 32];
                    x.copy_from_slice(xb);
                    Ok(DmParty { k, x })
                };
                Some((parse(pa, "a")?, parse(pb, "b")?))
            }
            None => None,
        };
        Ok(GroupManifest {
            gid,
            name,
            avatar,
            created,
            creator_pk,
            creator_name,
            head_pk,
            head_seed,
            dm,
        })
    }
}

fn pk32(b: Option<&[u8]>, what: &str) -> Result<PubKey> {
    let b = b.ok_or_else(|| CoreError::Invalid(format!("manifest missing {what}")))?;
    if b.len() != 32 {
        return Err(CoreError::Invalid(format!("bad {what} length")));
    }
    let mut pk = [0u8; 32];
    pk.copy_from_slice(b);
    Ok(pk)
}

/// Head item value (BEP44 mutable): `{h: [<20B ids>], t: <ms>, v: 1}`.
#[derive(Debug, Clone)]
pub struct HeadItem {
    pub heads: Vec<Sha1Hash>,
    pub ts: i64,
}

impl HeadItem {
    pub fn encode(&self) -> Vec<u8> {
        let mut d = Value::dict();
        d.insert(
            "h",
            Value::List(self.heads.iter().map(|h| Value::Str(h.to_vec())).collect()),
        );
        d.insert("t", Value::Int(self.ts));
        d.insert("v", Value::Int(1));
        bencode::encode(&d)
    }

    pub fn decode(bytes: &[u8]) -> Result<HeadItem> {
        let v = bencode::decode(bytes)?;
        let list = v
            .get("h")
            .and_then(|h| h.as_list())
            .ok_or_else(|| CoreError::Invalid("head item missing h".into()))?;
        let mut heads = Vec::with_capacity(list.len());
        for h in list {
            let b = h
                .as_bytes()
                .ok_or_else(|| CoreError::Invalid("bad head entry".into()))?;
            if b.len() != 20 {
                return Err(CoreError::Invalid("bad head entry len".into()));
            }
            let mut arr = [0u8; 20];
            arr.copy_from_slice(b);
            heads.push(arr);
        }
        Ok(HeadItem {
            heads,
            ts: v.get_int("t").unwrap_or(0),
        })
    }
}

pub fn manifest_file_name() -> &'static str {
    MANIFEST_FILE
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_roundtrip() {
        let creator = Identity::generate();
        let head = Identity::generate();
        let m = GroupManifest::new("测试群 🚀", "alice", &creator, &head, vec![1, 2, 3]).unwrap();
        let enc = m.encode();
        let dec = GroupManifest::decode(&enc).unwrap();
        assert_eq!(dec.gid, m.gid);
        assert_eq!(dec.name, "测试群 🚀");
        assert_eq!(dec.avatar, vec![1, 2, 3]);
        assert_eq!(dec.head_pk, m.head_pk);
        assert_eq!(dec.head_seed, m.head_seed);
        assert_eq!(dec.creator_pk, creator.public_key());
    }

    #[test]
    fn manifest_rejects_key_seed_mismatch() {
        let creator = Identity::generate();
        let head = Identity::generate();
        let mut m = GroupManifest::new("g", "bob", &creator, &head, vec![]).unwrap();
        m.head_pk = [0u8; 32];
        let enc = m.encode();
        // encoding contains an invalid pubkey for the seed; decode must catch it
        // (pk [0;32] is not a valid point, so either parse or mismatch fails)
        assert!(GroupManifest::decode(&enc).is_err());
    }

    #[test]
    fn head_item_roundtrip() {
        let hi = HeadItem {
            heads: vec![[1u8; 20], [2u8; 20]],
            ts: 1234,
        };
        let enc = hi.encode();
        assert!(enc.len() < crate::crypto::BEP44_VALUE_LIMIT);
        let dec = HeadItem::decode(&enc).unwrap();
        assert_eq!(dec.heads, hi.heads);
        assert_eq!(dec.ts, 1234);
    }

    #[test]
    fn salt_format() {
        let creator = Identity::generate();
        let head = Identity::generate();
        let m = GroupManifest::new("g", "bob", &creator, &head, vec![]).unwrap();
        assert!(m.head_salt().starts_with("bc1:"));
        assert_eq!(m.head_salt().len(), 4 + 40);
    }

    #[test]
    fn torrent_room_manifest_is_deterministic() {
        let ih = [7u8; 20];
        let a = GroupManifest::for_torrent(&ih, "Ubuntu 24.04 LTS");
        let b = GroupManifest::for_torrent(&ih, "Ubuntu 24.04 LTS");
        // gid IS the infohash; head key derives from it — identical on every
        // client, which is what lets any swarm member publish head pointers
        assert_eq!(a.gid, ih);
        assert_eq!(a.head_pk, b.head_pk);
        assert_eq!(a.head_seed, b.head_seed);
        assert_eq!(a.head_salt(), format!("bc1:{}", hex::encode(ih)));
        assert!(a.is_torrent_room());
        assert!(!a.is_dm());
        // roundtrip through the persisted (bencoded) form
        let dec = GroupManifest::decode(&a.encode()).unwrap();
        assert_eq!(dec.head_pk, a.head_pk);
        assert_eq!(dec.name, a.name);
        assert!(dec.is_torrent_room());
    }

    #[test]
    fn torrent_room_name_clamped_and_fallback() {
        let ih = [3u8; 20];
        let long = "很".repeat(100); // 300 bytes > 96
        let m = GroupManifest::for_torrent(&ih, &long);
        assert!(m.name.len() <= MAX_GROUP_NAME_LEN);
        let empty = GroupManifest::for_torrent(&ih, "  ");
        assert_eq!(empty.name, format!("种子 {}", &hex::encode(ih)[..8]));
    }
}
