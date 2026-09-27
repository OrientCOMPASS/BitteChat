//! Group manifest: the small bencoded document inside every group's manifest
//! torrent. Possession of the manifest torrent's magnet link is the group
//! membership capability — it contains the shared head-signing seed that lets
//! every member publish new DAG heads to the DHT.

use serde::{Deserialize, Serialize};

use crate::bencode::{self, Value};
use crate::crypto::{Identity, PubKey, Seed, Sha1Hash};
use crate::{CoreError, Result, HEAD_SALT_PREFIX, MANIFEST_FILE};

pub const MANIFEST_VERSION: i64 = 1;
pub const MAX_GROUP_NAME_LEN: usize = 96;
pub const MAX_AVATAR_LEN: usize = 8 * 1024;

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
        })
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
        Ok(GroupManifest {
            gid,
            name,
            avatar,
            created,
            creator_pk,
            creator_name,
            head_pk,
            head_seed,
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
}
