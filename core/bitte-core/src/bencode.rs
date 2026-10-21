//! Canonical bencode encoder/decoder.
//!
//! Canonicality rules (must match libtorrent's `bencode()` output byte-for-byte,
//! because DHT BEP44 item targets are SHA-1 hashes of bencoded data):
//!   * dictionary keys are unique and sorted by raw byte order (BTreeMap does this)
//!   * integers use the shortest representation (no leading zeros, no `-0`)
//!   * strings are raw bytes with a decimal length prefix
//!   * no extra whitespace anywhere

use std::collections::BTreeMap;
use std::fmt;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum BencodeError {
    #[error("unexpected end of input")]
    UnexpectedEnd,
    #[error("invalid byte {0:#04x} at position {1}")]
    InvalidByte(u8, usize),
    #[error("invalid integer encoding at position {0}")]
    InvalidInteger(usize),
    #[error("non-canonical integer encoding at position {0}")]
    NonCanonicalInteger(usize),
    #[error("duplicate dictionary key at position {0}")]
    DuplicateKey(usize),
    #[error("dictionary keys not sorted at position {0}")]
    UnsortedKeys(usize),
    #[error("trailing data after value")]
    TrailingData,
    #[error("value nested too deep")]
    TooDeep,
    #[error("value too large")]
    TooLarge,
}

#[derive(Clone, PartialEq, Eq)]
pub enum Value {
    Int(i64),
    Str(Vec<u8>),
    List(Vec<Value>),
    Dict(BTreeMap<Vec<u8>, Value>),
}

impl fmt::Debug for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Value::Int(i) => write!(f, "Int({i})"),
            Value::Str(s) => match std::str::from_utf8(s) {
                Ok(t) => write!(f, "Str({t:?})"),
                Err(_) => write!(f, "Str(<{} bytes> {})", s.len(), hex::encode(s)),
            },
            Value::List(l) => f.debug_list().entries(l).finish(),
            Value::Dict(d) => {
                let mut m = f.debug_map();
                for (k, v) in d {
                    m.key(&String::from_utf8_lossy(k));
                    m.value(v);
                }
                m.finish()
            }
        }
    }
}

impl Value {
    // ---- constructors / accessors -------------------------------------

    pub fn dict() -> Value {
        Value::Dict(BTreeMap::new())
    }

    pub fn as_int(&self) -> Option<i64> {
        match self {
            Value::Int(i) => Some(*i),
            _ => None,
        }
    }

    pub fn as_bytes(&self) -> Option<&[u8]> {
        match self {
            Value::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        self.as_bytes().and_then(|b| std::str::from_utf8(b).ok())
    }

    pub fn as_list(&self) -> Option<&[Value]> {
        match self {
            Value::List(l) => Some(l),
            _ => None,
        }
    }

    pub fn as_dict(&self) -> Option<&BTreeMap<Vec<u8>, Value>> {
        match self {
            Value::Dict(d) => Some(d),
            _ => None,
        }
    }

    /// Dict field access by string key.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.as_dict()?.get(key.as_bytes())
    }

    pub fn get_int(&self, key: &str) -> Option<i64> {
        self.get(key)?.as_int()
    }

    pub fn get_bytes(&self, key: &str) -> Option<&[u8]> {
        self.get(key)?.as_bytes()
    }

    pub fn get_str(&self, key: &str) -> Option<&str> {
        self.get(key)?.as_str()
    }

    /// Insert into a dict value; panics if self is not a Dict.
    pub fn insert<K: AsRef<[u8]>>(&mut self, key: K, val: Value) {
        match self {
            Value::Dict(d) => {
                d.insert(key.as_ref().to_vec(), val);
            }
            _ => panic!("insert into non-dict bencode value"),
        }
    }

    /// Total serialized size in bytes (cheap to compute without encoding).
    pub fn encoded_len(&self) -> usize {
        match self {
            Value::Int(i) => int_len(*i),
            Value::Str(s) => digits(s.len()) + 1 + s.len(),
            Value::List(l) => 1 + l.iter().map(|v| v.encoded_len()).sum::<usize>() + 1,
            Value::Dict(d) => {
                1 + d
                    .iter()
                    .map(|(k, v)| digits(k.len()) + 1 + k.len() + v.encoded_len())
                    .sum::<usize>()
                    + 1
            }
        }
    }
}

fn digits(mut n: usize) -> usize {
    let mut c = 1;
    while n >= 10 {
        n /= 10;
        c += 1;
    }
    c
}

fn int_len(i: i64) -> usize {
    // "i" + digits + "e"
    let n: u64 = if i < 0 {
        (i as i128).unsigned_abs() as u64
    } else {
        i as u64
    };
    let mut d = 1u64;
    let mut c = 1;
    while d.saturating_mul(10) <= n {
        d *= 10;
        c += 1;
    }
    c + if i < 0 { 3 } else { 2 }
}

// ---- encoding ----------------------------------------------------------

pub fn encode(v: &Value) -> Vec<u8> {
    let mut out = Vec::with_capacity(v.encoded_len());
    encode_into(v, &mut out);
    out
}

pub fn encode_into(v: &Value, out: &mut Vec<u8>) {
    match v {
        Value::Int(i) => {
            out.push(b'i');
            out.extend_from_slice(i.to_string().as_bytes());
            out.push(b'e');
        }
        Value::Str(s) => {
            out.extend_from_slice(s.len().to_string().as_bytes());
            out.push(b':');
            out.extend_from_slice(s);
        }
        Value::List(l) => {
            out.push(b'l');
            for item in l {
                encode_into(item, out);
            }
            out.push(b'e');
        }
        Value::Dict(d) => {
            out.push(b'd');
            // BTreeMap iterates in sorted byte order => canonical
            for (k, val) in d {
                out.extend_from_slice(k.len().to_string().as_bytes());
                out.push(b':');
                out.extend_from_slice(k);
                encode_into(val, out);
            }
            out.push(b'e');
        }
    }
}

// ---- decoding ----------------------------------------------------------

const MAX_DEPTH: usize = 64;
const MAX_LEN: usize = 64 * 1024 * 1024;

pub fn decode(data: &[u8]) -> Result<Value, BencodeError> {
    let (v, consumed) = decode_one(data, 0, 0)?;
    if consumed != data.len() {
        return Err(BencodeError::TrailingData);
    }
    Ok(v)
}

/// Decode the first value, returning it and the number of bytes consumed.
pub fn decode_prefix(data: &[u8]) -> Result<(Value, usize), BencodeError> {
    decode_one(data, 0, 0)
}

fn decode_one(data: &[u8], pos: usize, depth: usize) -> Result<(Value, usize), BencodeError> {
    if depth > MAX_DEPTH {
        return Err(BencodeError::TooDeep);
    }
    if pos >= data.len() {
        return Err(BencodeError::UnexpectedEnd);
    }
    match data[pos] {
        b'i' => decode_int(data, pos),
        b'l' => decode_list(data, pos, depth),
        b'd' => decode_dict(data, pos, depth),
        b'0'..=b'9' => decode_str(data, pos).map(|(s, n)| (Value::Str(s), n)),
        c => Err(BencodeError::InvalidByte(c, pos)),
    }
}

fn decode_int(data: &[u8], pos: usize) -> Result<(Value, usize), BencodeError> {
    // pos points at 'i'
    let end = data[pos + 1..]
        .iter()
        .position(|&c| c == b'e')
        .ok_or(BencodeError::UnexpectedEnd)?
        + pos
        + 1;
    let bytes = &data[pos + 1..end];
    if bytes.is_empty() {
        return Err(BencodeError::InvalidInteger(pos));
    }
    // canonical check: no leading zeros (except a bare "0"), no "-0"
    let digits = if bytes[0] == b'-' { &bytes[1..] } else { bytes };
    if digits.is_empty() {
        return Err(BencodeError::InvalidInteger(pos));
    }
    if digits.len() > 1 && digits[0] == b'0' {
        return Err(BencodeError::NonCanonicalInteger(pos));
    }
    if bytes == b"-0" {
        return Err(BencodeError::NonCanonicalInteger(pos));
    }
    if !digits.iter().all(|c| c.is_ascii_digit()) {
        return Err(BencodeError::InvalidInteger(pos));
    }
    let s = std::str::from_utf8(bytes).map_err(|_| BencodeError::InvalidInteger(pos))?;
    let n: i64 = s.parse().map_err(|_| BencodeError::InvalidInteger(pos))?;
    Ok((Value::Int(n), end + 1))
}

fn decode_len_prefix(data: &[u8], pos: usize) -> Result<(usize, usize), BencodeError> {
    // returns (length, position after ':')
    let colon = data[pos..]
        .iter()
        .position(|&c| c == b':')
        .ok_or(BencodeError::UnexpectedEnd)?
        + pos;
    let num = &data[pos..colon];
    if num.is_empty() || !num.iter().all(|c| c.is_ascii_digit()) {
        return Err(BencodeError::InvalidByte(0, pos));
    }
    if num.len() > 1 && num[0] == b'0' {
        return Err(BencodeError::NonCanonicalInteger(pos));
    }
    let len: usize = std::str::from_utf8(num)
        .map_err(|_| BencodeError::InvalidInteger(pos))?
        .parse()
        .map_err(|_| BencodeError::TooLarge)?;
    if len > MAX_LEN {
        return Err(BencodeError::TooLarge);
    }
    Ok((len, colon + 1))
}

fn decode_str(data: &[u8], pos: usize) -> Result<(Vec<u8>, usize), BencodeError> {
    let (len, start) = decode_len_prefix(data, pos)?;
    if start + len > data.len() {
        return Err(BencodeError::UnexpectedEnd);
    }
    Ok((data[start..start + len].to_vec(), start + len))
}

fn decode_list(data: &[u8], pos: usize, depth: usize) -> Result<(Value, usize), BencodeError> {
    let mut items = Vec::new();
    let mut p = pos + 1;
    loop {
        if p >= data.len() {
            return Err(BencodeError::UnexpectedEnd);
        }
        if data[p] == b'e' {
            return Ok((Value::List(items), p + 1));
        }
        let (v, n) = decode_one(data, p, depth + 1)?;
        items.push(v);
        p = n;
    }
}

fn decode_dict(data: &[u8], pos: usize, depth: usize) -> Result<(Value, usize), BencodeError> {
    let mut map: BTreeMap<Vec<u8>, Value> = BTreeMap::new();
    let mut p = pos + 1;
    let mut last_key: Option<Vec<u8>> = None;
    loop {
        if p >= data.len() {
            return Err(BencodeError::UnexpectedEnd);
        }
        if data[p] == b'e' {
            return Ok((Value::Dict(map), p + 1));
        }
        if !data[p].is_ascii_digit() {
            return Err(BencodeError::InvalidByte(data[p], p));
        }
        let (key, after_key) = decode_str(data, p)?;
        if let Some(ref lk) = last_key {
            match lk.cmp(&key) {
                std::cmp::Ordering::Equal => return Err(BencodeError::DuplicateKey(p)),
                std::cmp::Ordering::Greater => return Err(BencodeError::UnsortedKeys(p)),
                std::cmp::Ordering::Less => {}
            }
        }
        let (v, n) = decode_one(data, after_key, depth + 1)?;
        last_key = Some(key.clone());
        map.insert(key, v);
        p = n;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(x: &str) -> Value {
        Value::Str(x.as_bytes().to_vec())
    }

    #[test]
    fn encode_primitives() {
        assert_eq!(encode(&Value::Int(42)), b"i42e");
        assert_eq!(encode(&Value::Int(0)), b"i0e");
        assert_eq!(encode(&Value::Int(-7)), b"i-7e");
        assert_eq!(encode(&s("spam")), b"4:spam");
        assert_eq!(encode(&s("")), b"0:");
    }

    #[test]
    fn encode_dict_sorted() {
        let mut d = Value::dict();
        d.insert("z", Value::Int(1));
        d.insert("a", s("x"));
        d.insert("m", Value::List(vec![Value::Int(1), Value::Int(2)]));
        assert_eq!(encode(&d), b"d1:a1:x1:mli1ei2ee1:zi1ee");
    }

    #[test]
    fn roundtrip() {
        let raw = b"d3:cow3:moo4:spamli1ei2eee";
        let v = decode(raw).unwrap();
        assert_eq!(encode(&v), raw);
    }

    #[test]
    fn decode_strict_rejects() {
        assert!(matches!(
            decode(b"i03e"),
            Err(BencodeError::NonCanonicalInteger(_))
        ));
        assert!(matches!(
            decode(b"i-0e"),
            Err(BencodeError::NonCanonicalInteger(_))
        ));
        assert!(matches!(decode(b"i12"), Err(BencodeError::UnexpectedEnd)));
        assert!(matches!(
            decode(b"d1:b1:x1:a1:ye"),
            Err(BencodeError::UnsortedKeys(_))
        ));
        assert!(matches!(
            decode(b"d1:a1:x1:a1:ye"),
            Err(BencodeError::DuplicateKey(_))
        ));
        assert!(matches!(
            decode(b"4:spame"),
            Err(BencodeError::TrailingData)
        ));
        assert!(matches!(decode(b"l"), Err(BencodeError::UnexpectedEnd)));
    }

    #[test]
    fn binary_strings_survive() {
        let bytes: Vec<u8> = (0u8..=255).collect();
        let v = Value::Str(bytes.clone());
        let enc = encode(&v);
        let dec = decode(&enc).unwrap();
        assert_eq!(dec.as_bytes().unwrap(), &bytes[..]);
    }

    #[test]
    fn encoded_len_matches() {
        let mut d = Value::dict();
        d.insert("hello", Value::List(vec![s("world"), Value::Int(-12345)]));
        let enc = encode(&d);
        assert_eq!(d.encoded_len(), enc.len());
    }
}
