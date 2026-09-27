//! Real-engine smoke test: boots an actual libtorrent session through the
//! full FFI stack (bitte-bt C++ wrapper included) and exercises the JSON
//! contract between Rust and C++. Runs only with `--features native-bt`
//! (CI job `native-smoke` builds the host native stack first).

#![cfg(feature = "native-bt")]

use std::time::{Duration, Instant};

use serde_json::json;

use bitte_core::bencode::Value;
use bitte_core::engine::EngineEvent;
use bitte_core::lt::create_engine;

fn wait_event<F: Fn(&EngineEvent) -> bool>(
    rx: &std::sync::mpsc::Receiver<EngineEvent>,
    timeout: Duration,
    pred: F,
) -> Option<EngineEvent> {
    let start = Instant::now();
    while start.elapsed() < timeout {
        match rx.recv_timeout(Duration::from_millis(200)) {
            Ok(ev) => {
                if pred(&ev) {
                    return Some(ev);
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(_) => return None,
        }
    }
    None
}

#[test]
fn native_engine_smoke() {
    let dir = tempfile::tempdir().unwrap();
    let (engine, rx) = create_engine(json!({
        "data_dir": dir.path().to_string_lossy(),
        "listen_port": 18931,
        "user_agent": "BitteChatSmoke/0.1",
    }))
    .expect("libtorrent engine boots");

    assert_eq!(engine.name(), "libtorrent");

    // session stats respond
    let stats = engine.session_stats().expect("stats");
    assert!(stats.num_torrents >= 0);

    // create a torrent from a temp file (v1-only, DHT-discoverable)
    let fpath = dir.path().join("payload.bin");
    std::fs::write(&fpath, vec![7u8; 4096]).unwrap();
    let created = engine
        .create_torrent(&fpath.to_string_lossy(), "smoke")
        .expect("create_torrent");
    assert_eq!(created.infohash.len(), 20);
    assert!(created.magnet.starts_with("magnet:?xt=urn:btih:"));
    assert!(!created.torrent_bytes.is_empty());

    // add it back as a seeding torrent; metadata event must arrive
    let ih = engine
        .add_torrent_bytes(
            &created.torrent_bytes,
            &dir.path().join("seed").to_string_lossy(),
        )
        .expect("add_torrent_bytes");
    assert_eq!(ih, hex::encode(created.infohash));
    let got_meta = wait_event(
        &rx,
        Duration::from_secs(20),
        |ev| matches!(ev, EngineEvent::MetadataReceived { infohash } if *infohash == ih),
    );
    assert!(got_meta.is_some(), "metadata_received alert missing");

    // states expose the torrent
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let states = engine.torrent_states().expect("states");
        if states.iter().any(|s| s.infohash == ih) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "torrent never appeared in states"
        );
        std::thread::sleep(Duration::from_millis(300));
    }

    // file list + priorities round-trip
    let files = engine.file_list(&ih).expect("file_list");
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].path, "payload.bin");
    engine
        .set_file_priorities(&ih, vec![4])
        .expect("priorities");

    // BEP44 immutable put: C++ must agree on the SHA-1 target (canonical
    // bencode round-trip through libtorrent's entry type)
    let mut d = Value::dict();
    d.insert("probe", Value::Str(b"smoke".to_vec()));
    d.insert("n", Value::Int(42));
    let value = bitte_core::bencode::encode(&d);
    let expected = bitte_core::crypto::bep44_immutable_target(&value);
    engine
        .dht_put_immutable(&value, &expected)
        .expect("dht_put_immutable target match");

    // get of an unknown target resolves to a not-found event (DHT may be
    // empty in CI; we only assert the alert plumbing works)
    let unknown = [0xABu8; 20];
    engine
        .dht_get_immutable(&unknown)
        .expect("dht_get_immutable");
    let got = wait_event(
        &rx,
        Duration::from_secs(20),
        |ev| matches!(ev, EngineEvent::DhtImmutableItem { target, .. } if *target == unknown),
    );
    assert!(got.is_some(), "dht immutable alert plumbing broken");

    // ext broadcast with no peers reports zero sends, no crash
    let n = engine.ext_send(&ih, b"hello").expect("ext_send");
    assert_eq!(n, 0);

    // pause/resume/remove lifecycle
    engine.set_paused(&ih, true).expect("pause");
    engine.set_paused(&ih, false).expect("resume");
    engine.remove_torrent(&ih, false).expect("remove");
    let gone = wait_event(
        &rx,
        Duration::from_secs(15),
        |ev| matches!(ev, EngineEvent::TorrentRemoved { infohash } if *infohash == ih),
    );
    assert!(gone.is_some(), "torrent_removed alert missing");
}
