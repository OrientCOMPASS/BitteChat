//! Cryptographic primitives: user identity (Ed25519) and BEP44 (DHT mutable
//! items) signing/verification.
//!
//! BEP44 compatibility notes (verified against libtorrent 2.1.2
//! `lt::dht::sign_mutable_item` / `verify_mutable_item`):
//!   * keys are Ed25519 (libtorrent uses orlp/ed25519, whose signatures are
//!     RFC 8032 compatible, so ed25519-dalek interops byte-for-byte)
//!   * libtorrent's 64-byte "secret key" is `seed(32) || public_key(32)`;
//!     we only ever store/pass the 32-byte seed and derive the rest
//!   * target of a mutable item = SHA-1(public_key || salt)
//!   * signed payload = bencode({"seq": <i64>, "v": <value bytes>}) || salt,
//!     where the dict is canonical (keys sorted: "seq" < "v") and the value
//!     is embedded as a raw bencoded string

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use rand::rngs::OsRng;
use sha1::{Digest, Sha1};

use crate::bencode::Value;

pub type Sha1Hash = [u8; 20];
pub type PubKey = [u8; 32];
pub type Seed = [u8; 32];
pub type Sig64 = [u8; 64];

pub fn sha1(data: &[u8]) -> Sha1Hash {
    let mut h = Sha1::new();
    h.update(data);
    let out = h.finalize();
    let mut r = [0u8; 20];
    r.copy_from_slice(&out);
    r
}

// ---- identity -----------------------------------------------------------

/// A user or group Ed25519 identity.
#[derive(Clone)]
pub struct Identity {
    pub seed: Seed,
    pub signing: SigningKey,
}

impl Identity {
    pub fn generate() -> Identity {
        Identity::from_seed(new_seed())
    }

    pub fn from_seed(seed: Seed) -> Identity {
        let signing = SigningKey::from_bytes(&seed);
        Identity { seed, signing }
    }

    pub fn public_key(&self) -> PubKey {
        self.signing.verifying_key().to_bytes()
    }

    pub fn sign(&self, msg: &[u8]) -> Sig64 {
        self.signing.sign(msg).to_bytes()
    }
}

pub fn new_seed() -> Seed {
    let mut s = [0u8; 32];
    rand::RngCore::fill_bytes(&mut OsRng, &mut s);
    s
}

pub fn verifying_key(pk: &PubKey) -> Option<VerifyingKey> {
    VerifyingKey::from_bytes(pk).ok()
}

pub fn verify(pk: &PubKey, msg: &[u8], sig: &Sig64) -> bool {
    let Some(vk) = verifying_key(pk) else {
        return false;
    };
    vk.verify(msg, &Signature::from_bytes(sig)).is_ok()
}

// ---- BEP44 ---------------------------------------------------------------

/// target = SHA1(public_key || salt) for mutable items.
pub fn bep44_mutable_target(pk: &PubKey, salt: &[u8]) -> Sha1Hash {
    let mut buf = Vec::with_capacity(32 + salt.len());
    buf.extend_from_slice(pk);
    buf.extend_from_slice(salt);
    sha1(&buf)
}

/// target = SHA1(value) for immutable items.
pub fn bep44_immutable_target(value: &[u8]) -> Sha1Hash {
    sha1(value)
}

/// Build the exact byte buffer BEP44 signs:
/// `bencode({"seq": seq, "v": value}) || salt`
pub fn bep44_sign_buffer(seq: i64, value: &[u8], salt: &[u8]) -> Vec<u8> {
    let mut d = Value::dict();
    d.insert("seq", Value::Int(seq));
    d.insert("v", Value::Str(value.to_vec()));
    let mut buf = crate::bencode::encode(&d);
    buf.extend_from_slice(salt);
    buf
}

pub fn bep44_sign(identity: &Identity, seq: i64, value: &[u8], salt: &[u8]) -> Sig64 {
    identity.sign(&bep44_sign_buffer(seq, value, salt))
}

pub fn bep44_verify(pk: &PubKey, seq: i64, value: &[u8], salt: &[u8], sig: &Sig64) -> bool {
    verify(pk, &bep44_sign_buffer(seq, value, salt), sig)
}

/// Max size (bytes) of a BEP44 item value accepted by most DHT implementations.
pub const BEP44_VALUE_LIMIT: usize = 1000;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sign_verify_roundtrip() {
        let id = Identity::generate();
        let pk = id.public_key();
        let msg = b"hello bitte";
        let sig = id.sign(msg);
        assert!(verify(&pk, msg, &sig));
        assert!(!verify(&pk, b"tampered", &sig));
    }

    #[test]
    fn bep44_roundtrip() {
        let id = Identity::generate();
        let pk = id.public_key();
        let salt = b"bc1:abcd";
        let value = crate::bencode::encode(&Value::Int(7));
        let seq = 42i64;
        let sig = bep44_sign(&id, seq, &value, salt);
        assert!(bep44_verify(&pk, seq, &value, salt, &sig));
        assert!(!bep44_verify(&pk, seq + 1, &value, salt, &sig));
        assert!(!bep44_verify(&pk, seq, b"other", salt, &sig));
    }

    #[test]
    fn bep44_sign_buffer_layout() {
        // exactly: d 3:seq i<seq> e 1:v <len>:<value> e <salt>
        let buf = bep44_sign_buffer(5, b"ab", b"SLT");
        assert_eq!(buf, b"d3:seqi5e1:v2:abeSLT");
    }

    #[test]
    fn seed_determinism() {
        let seed = [9u8; 32];
        let a = Identity::from_seed(seed);
        let b = Identity::from_seed(seed);
        assert_eq!(a.public_key(), b.public_key());
        let sig = a.sign(b"x");
        assert!(verify(&b.public_key(), b"x", &sig));
    }

    #[test]
    fn known_sha1_vector() {
        // sha1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d
        assert_eq!(
            hex::encode(sha1(b"abc")),
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        );
    }
}
