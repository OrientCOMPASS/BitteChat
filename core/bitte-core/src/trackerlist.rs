//! Global tracker list URL — qBittorrent's "Automatically append trackers
//! from URL to new downloads" design, adapted:
//!
//! * a user-configured URL plus an enable switch;
//! * fetched at startup, on URL/enabled change, on manual refresh and on a
//!   24 h timer (qBit uses a 24 h QTimer);
//! * the last good list is cached on disk (`additional_trackers_from_url.txt`,
//!   same file name as qBit) so restarts work offline;
//! * a failed fetch NEVER clears the previous list — it only records an
//!   error message (qBit logs a warning and keeps the old entries);
//! * fetched entries are appended (de-duplicated) to the user's default
//!   tracker list and applied to newly added torrents.

use crate::mock::valid_tracker_url;
use crate::store::Store;
use crate::Result;

pub const KV_URL: &str = "tracker_list_url";
pub const KV_ENABLED: &str = "tracker_list_enabled";
pub const KV_FETCHED: &str = "tracker_list_fetched";
pub const KV_LAST_FETCH: &str = "tracker_list_last_fetch";
pub const KV_ERROR: &str = "tracker_list_error";
pub const CACHE_FILE: &str = "additional_trackers_from_url.txt";
pub const REFRESH_INTERVAL_MS: i64 = 24 * 3600 * 1000;
pub const MAX_TRACKERS: usize = 300;

/// Parse a tracker-list document: whitespace/comma separated URLs, `#`/`;`
/// comments and invalid schemes ignored, de-duplicated, capped.
pub fn parse_tracker_list(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for tok in text.split(|c: char| c.is_whitespace() || c == ',') {
        let t = tok.trim();
        if t.is_empty() || t.starts_with('#') || t.starts_with(';') {
            continue;
        }
        if !valid_tracker_url(t) {
            continue;
        }
        if !out.iter().any(|u| u == t) {
            out.push(t.to_string());
        }
        if out.len() >= MAX_TRACKERS {
            break;
        }
    }
    out
}

/// User list + fetched list merged (user entries first), de-duplicated.
pub fn merge(user: &[String], fetched: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for u in user.iter().chain(fetched.iter()) {
        if !out.iter().any(|x| x == u) {
            out.push(u.clone());
        }
    }
    out
}

pub fn config(store: &Store) -> (bool, String) {
    let enabled = store
        .kv_get(KV_ENABLED)
        .ok()
        .flatten()
        .map(|b| b == b"1"[..])
        .unwrap_or(false);
    let url = store
        .kv_get(KV_URL)
        .ok()
        .flatten()
        .and_then(|b| String::from_utf8(b).ok())
        .unwrap_or_default();
    (enabled, url)
}

pub fn set_config(store: &Store, enabled: bool, url: &str) -> Result<()> {
    store.kv_set(KV_ENABLED, if enabled { b"1" } else { b"0" })?;
    store.kv_set(KV_URL, url.as_bytes())?;
    Ok(())
}

pub fn fetched(store: &Store) -> Vec<String> {
    store
        .kv_get(KV_FETCHED)
        .ok()
        .flatten()
        .and_then(|b| String::from_utf8(b).ok())
        .map(|text| parse_tracker_list(&text))
        .unwrap_or_default()
}

/// (last_fetch_ms, last_error, fetched list)
pub fn status(store: &Store) -> (i64, String, Vec<String>) {
    let last = store
        .kv_get(KV_LAST_FETCH)
        .ok()
        .flatten()
        .and_then(|b| String::from_utf8(b).ok())
        .and_then(|s| s.parse::<i64>().ok())
        .unwrap_or(0);
    let error = store
        .kv_get(KV_ERROR)
        .ok()
        .flatten()
        .and_then(|b| String::from_utf8(b).ok())
        .unwrap_or_default();
    (last, error, fetched(store))
}

pub fn record_success(store: &Store, list: &[String], now: i64) -> Result<()> {
    store.kv_set(KV_FETCHED, list.join("\n").as_bytes())?;
    store.kv_set(KV_LAST_FETCH, now.to_string().as_bytes())?;
    store.kv_set(KV_ERROR, b"")?;
    Ok(())
}

pub fn record_error(store: &Store, error: &str) -> Result<()> {
    store.kv_set(KV_ERROR, error.as_bytes())?;
    Ok(())
}

/// Effective auto-append list for NEW torrents: user defaults + fetched
/// (only while enabled), de-duplicated.
pub fn effective(store: &Store, user: &[String]) -> Vec<String> {
    let (enabled, _) = config(store);
    if !enabled {
        return user.to_vec();
    }
    merge(user, &fetched(store))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_filters_comments_and_invalid() {
        let text = "# comment\nudp://a.example:1337/announce\n\n; another\n\
                    http://b.example/announce\nudp://a.example:1337/announce\n\
                    ftp://nope/x\nnot a url\nudp://c.example:1/announce";
        let v = parse_tracker_list(text);
        assert_eq!(
            v,
            vec![
                "udp://a.example:1337/announce",
                "http://b.example/announce",
                "udp://c.example:1/announce",
            ]
        );
    }

    #[test]
    fn parse_caps_at_max() {
        let text = (0..(MAX_TRACKERS + 50))
            .map(|i| format!("udp://t{i}.example:1337/announce"))
            .collect::<Vec<_>>()
            .join("\n");
        assert_eq!(parse_tracker_list(&text).len(), MAX_TRACKERS);
    }

    #[test]
    fn merge_keeps_user_order_then_fetched() {
        let user = vec!["udp://u.example:1/a".to_string()];
        let fetched = vec![
            "udp://u.example:1/a".to_string(),
            "udp://f.example:1/b".to_string(),
        ];
        assert_eq!(
            merge(&user, &fetched),
            vec![
                "udp://u.example:1/a".to_string(),
                "udp://f.example:1/b".to_string(),
            ]
        );
    }
}
