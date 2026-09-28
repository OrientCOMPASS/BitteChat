//! End-to-end tests of the full chat stack on the mock engine bus:
//! two independent `Api` instances behave like two users' phones.

use std::sync::mpsc::Receiver;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{json, Value as Json};

use bitte_core::api::Api;
use bitte_core::mock::{MockBus, MockEngine};

struct Node {
    api: Api,
    events: Receiver<String>,
    path: std::path::PathBuf,
    _engine: Arc<MockEngine>,
}

/// Returns the node plus the tempdir guard (keep the guard alive as long as
/// you need the node's data directory).
fn spawn_node(bus: &MockBus) -> (Node, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let (engine, rx) = MockEngine::new(bus.clone());
    let engine = Arc::new(engine);
    let (api, events) = Api::new(
        dir.path().to_path_buf(),
        engine.clone() as Arc<dyn bitte_core::engine::BtEngine>,
        rx,
    )
    .unwrap();
    (
        Node {
            api,
            events,
            path: dir.path().to_path_buf(),
            _engine: engine,
        },
        dir,
    )
}

fn spawn_node_at(bus: &MockBus, path: &std::path::Path) -> Node {
    let (engine, rx) = MockEngine::new(bus.clone());
    let engine = Arc::new(engine);
    let (api, events) = Api::new(
        path.to_path_buf(),
        engine.clone() as Arc<dyn bitte_core::engine::BtEngine>,
        rx,
    )
    .unwrap();
    Node {
        api,
        events,
        path: path.to_path_buf(),
        _engine: engine,
    }
}

fn call(node: &Node, method: &str, params: Json) -> Json {
    node.api
        .dispatch(method, params)
        .unwrap_or_else(|e| panic!("call {method} failed: {e}"))
}

fn try_call(node: &Node, method: &str, params: Json) -> Result<Json, String> {
    node.api.dispatch(method, params).map_err(|e| e.to_string())
}

/// Drain pending events (non-blocking) as JSON values.
fn drain(node: &Node) -> Vec<Json> {
    let mut out = Vec::new();
    while let Ok(s) = node.events.try_recv() {
        if let Ok(v) = serde_json::from_str::<Json>(&s) {
            out.push(v);
        }
    }
    out
}

/// Wait until `cond` returns Some(T) by polling dispatch calls; also drains
/// events so channels never block.
fn wait_until<T>(nodes: &[&Node], timeout: Duration, mut cond: impl FnMut() -> Option<T>) -> T {
    let start = Instant::now();
    loop {
        for n in nodes {
            drain(n);
        }
        if let Some(v) = cond() {
            return v;
        }
        if start.elapsed() > timeout {
            panic!("condition not met within {timeout:?}");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

const T: Duration = Duration::from_secs(15);

fn msg_count(node: &Node, gid: &str) -> i64 {
    let r = call(node, "chat.messages", json!({"group_id": gid}));
    r["total"].as_i64().unwrap_or(-1)
}

fn texts(node: &Node, gid: &str) -> Vec<String> {
    let r = call(node, "chat.messages", json!({"group_id": gid}));
    r["messages"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|m| m["payload"]["Text"]["text"].as_str().map(String::from))
        .collect()
}

#[test]
fn e2e_create_join_chat() {
    let bus = MockBus::new();
    let (a, _ta) = spawn_node(&bus);
    let (b, _tb) = spawn_node(&bus);

    // A creates a group
    let created = call(&a, "chat.create_group", json!({"name": "开发群"}));
    let gid = created["group_id"].as_str().unwrap().to_string();
    let magnet = created["invite_magnet"].as_str().unwrap().to_string();
    assert!(magnet.starts_with("magnet:?xt=urn:btih:"));

    // B joins via the invite magnet
    let joined = call(&b, "chat.join_group", json!({"magnet": magnet}));
    assert!(
        joined["pending"].as_bool().unwrap_or(false)
            || joined["already"].as_bool().unwrap_or(false)
    );

    // B should see the group with the genesis system message
    wait_until(&[&a, &b], T, || {
        let groups = call(&b, "chat.groups", json!({}));
        let arr = groups["groups"].as_array()?;
        arr.iter()
            .find(|g| g["group_id"].as_str() == Some(gid.as_str()))?;
        if msg_count(&b, &gid) >= 1 {
            Some(())
        } else {
            None
        }
    });

    // A sends a text; B receives it via the ext channel (same swarm)
    call(&a, "chat.send", json!({"group_id": gid, "text": "大家好"}));
    wait_until(&[&a, &b], T, || {
        if texts(&b, &gid).contains(&"大家好".to_string()) {
            Some(())
        } else {
            None
        }
    });

    // B replies; A receives
    call(&b, "chat.send", json!({"group_id": gid, "text": "hello!"}));
    wait_until(&[&a, &b], T, || {
        if texts(&a, &gid).contains(&"hello!".to_string()) {
            Some(())
        } else {
            None
        }
    });

    // both histories converged and identical in order
    let ta = texts(&a, &gid);
    let tb = texts(&b, &gid);
    assert_eq!(ta, tb);
    assert!(ta.windows(2).any(|w| w == ["大家好", "hello!"]));

    // message states confirmed (DHT put done)
    wait_until(&[&a, &b], T, || {
        let r = call(&a, "chat.messages", json!({"group_id": gid}));
        let all_confirmed = r["messages"]
            .as_array()
            .unwrap()
            .iter()
            .all(|m| m["state"].as_i64() == Some(1));
        if all_confirmed {
            Some(())
        } else {
            None
        }
    });

    // unread bookkeeping on B
    let groups = call(&b, "chat.groups", json!({}));
    let g = groups["groups"]
        .as_array()
        .unwrap()
        .iter()
        .find(|g| g["group_id"].as_str() == Some(gid.as_str()))
        .unwrap()
        .clone();
    assert!(g["unread"].as_i64().unwrap() >= 1);
    call(&b, "chat.mark_read", json!({"group_id": gid}));
    let groups = call(&b, "chat.groups", json!({}));
    let g = &groups["groups"]
        .as_array()
        .unwrap()
        .iter()
        .find(|g| g["group_id"].as_str() == Some(gid.as_str()))
        .unwrap();
    assert_eq!(g["unread"].as_i64().unwrap(), 0);
}

#[test]
fn e2e_offline_dht_sync() {
    let bus = MockBus::new();
    let dir_b = tempfile::tempdir().unwrap();
    let gid;
    {
        let (a, _ta) = spawn_node(&bus);
        let b = spawn_node_at(&bus, dir_b.path());

        let created = call(&a, "chat.create_group", json!({"name": "离线测试"}));
        gid = created["group_id"].as_str().unwrap().to_string();
        let magnet = created["invite_magnet"].as_str().unwrap().to_string();
        call(&b, "chat.join_group", json!({"magnet": &magnet}));
        wait_until(&[&a, &b], T, || {
            if msg_count(&b, &gid) >= 1 {
                Some(())
            } else {
                None
            }
        });

        // B goes offline (engine + api dropped; data dir survives)
        drop(b);

        // A posts while B is away — lands in the (bus-global) DHT
        call(
            &a,
            "chat.send",
            json!({"group_id": gid, "text": "错过了一条"}),
        );
        wait_until(&[&a], T, || {
            let r = call(&a, "chat.messages", json!({"group_id": gid}));
            let confirmed = r["messages"]
                .as_array()
                .unwrap()
                .iter()
                .all(|m| m["state"].as_i64() == Some(1));
            if confirmed {
                Some(())
            } else {
                None
            }
        });
    }

    // B comes back with the same data dir: persistence + DHT head polling
    // must restore the full history including the offline message.
    let b2 = spawn_node_at(&bus, dir_b.path());
    wait_until(&[&b2], T, || {
        let groups = call(&b2, "chat.groups", json!({}));
        let arr = groups["groups"].as_array()?;
        arr.iter()
            .find(|g| g["group_id"].as_str() == Some(gid.as_str()))?;
        if msg_count(&b2, &gid) >= 1 {
            Some(())
        } else {
            None
        }
    });
    wait_until(&[&b2], Duration::from_secs(30), || {
        if texts(&b2, &gid).contains(&"错过了一条".to_string()) {
            Some(())
        } else {
            None
        }
    });
}

#[test]
fn e2e_attachment_transfer() {
    let bus = MockBus::new();
    let (a, _ta) = spawn_node(&bus);
    let (b, _tb) = spawn_node(&bus);

    let created = call(&a, "chat.create_group", json!({"name": "文件群"}));
    let gid = created["group_id"].as_str().unwrap().to_string();
    let magnet = created["invite_magnet"].as_str().unwrap().to_string();
    call(&b, "chat.join_group", json!({"magnet": magnet}));
    wait_until(&[&a, &b], T, || {
        if msg_count(&b, &gid) >= 1 {
            Some(())
        } else {
            None
        }
    });

    // A sends a file
    let fpath = a.path.join("hello.txt");
    std::fs::write(&fpath, b"attachment payload 123").unwrap();
    let sent = call(
        &a,
        "chat.send_file",
        json!({
            "group_id": gid,
            "path": fpath.to_string_lossy(),
            "name": "hello.txt",
        }),
    );
    let ih = sent["infohash"].as_str().unwrap().to_string();

    // B sees the attachment message
    wait_until(&[&a, &b], T, || {
        let r = call(&b, "chat.messages", json!({"group_id": gid}));
        let has = r["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|m| m["payload"]["Attachment"]["infohash"].as_str() == Some(ih.as_str()));
        if has {
            Some(())
        } else {
            None
        }
    });

    // chat-internal torrents must NOT pollute the default BT list (sender
    // side has the kind=2 registry row; receiver side has nothing yet)
    for node in [&a, &b] {
        let list = call(node, "bt.list", json!({}));
        assert!(
            !list["torrents"]
                .as_array()
                .unwrap()
                .iter()
                .any(|t| t["infohash"].as_str() == Some(ih.as_str())),
            "attachment torrent leaked into user BT list"
        );
    }
    // ...but the sender sees it when explicitly requesting chat torrents
    let list = call(&a, "bt.list", json!({"include_chat": true}));
    assert!(list["torrents"]
        .as_array()
        .unwrap()
        .iter()
        .any(|t| t["infohash"].as_str() == Some(ih.as_str())));

    // B downloads through the internal chat channel
    let r = call(&b, "chat.messages", json!({"group_id": gid}));
    let msg_id = r["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["payload"]["Attachment"]["infohash"].as_str() == Some(ih.as_str()))
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    call(
        &b,
        "chat.download_attachment",
        json!({"group_id": gid, "msg_id": msg_id}),
    );
    wait_until(&[&a, &b], T, || {
        let path = b.api.downloads_dir().join(&ih).join("hello.txt");
        if path.exists() {
            let content = std::fs::read(&path).unwrap();
            if content == b"attachment payload 123" {
                Some(())
            } else {
                None
            }
        } else {
            None
        }
    });
}

#[test]
fn e2e_long_text_chunking() {
    let bus = MockBus::new();
    let (a, _ta) = spawn_node(&bus);
    let (b, _tb) = spawn_node(&bus);
    let created = call(&a, "chat.create_group", json!({"name": "长文群"}));
    let gid = created["group_id"].as_str().unwrap().to_string();
    let magnet = created["invite_magnet"].as_str().unwrap().to_string();
    call(&b, "chat.join_group", json!({"magnet": magnet}));
    wait_until(&[&a, &b], T, || {
        if msg_count(&b, &gid) >= 1 {
            Some(())
        } else {
            None
        }
    });

    let long: String = "区块链防篡改消息".repeat(200); // 2000 chars, 6000 bytes
    call(&a, "chat.send", json!({"group_id": gid, "text": &long}));
    wait_until(&[&a, &b], Duration::from_secs(30), || {
        if texts(&b, &gid).contains(&long) {
            Some(())
        } else {
            None
        }
    });
}

#[test]
fn e2e_tampered_item_rejected() {
    let bus = MockBus::new();
    let (a, _ta) = spawn_node(&bus);
    let (b, _tb) = spawn_node(&bus);
    let created = call(&a, "chat.create_group", json!({"name": "防篡改"}));
    let gid = created["group_id"].as_str().unwrap().to_string();
    let magnet = created["invite_magnet"].as_str().unwrap().to_string();
    call(&b, "chat.join_group", json!({"magnet": magnet}));
    wait_until(&[&a, &b], T, || {
        if msg_count(&b, &gid) >= 1 {
            Some(())
        } else {
            None
        }
    });

    call(
        &a,
        "chat.send",
        json!({"group_id": gid, "text": "正版消息"}),
    );
    wait_until(&[&a, &b], T, || {
        if texts(&b, &gid).contains(&"正版消息".to_string()) {
            Some(())
        } else {
            None
        }
    });

    // attacker flips a byte of the stored immutable item in the "DHT"
    let r = call(&a, "chat.messages", json!({"group_id": gid}));
    let target = r["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["payload"]["Text"]["text"].as_str() == Some("正版消息"))
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    bus.corrupt_immutable(&hex::decode(&target).unwrap());

    // fresh node C joins and must NOT accept the corrupted message
    let (c, _tc) = spawn_node(&bus);
    call(&c, "chat.join_group", json!({"magnet": magnet}));
    // C gets the group (manifest fine) but the corrupted message is rejected;
    // genesis may arrive; assert the tampered text never appears
    std::thread::sleep(Duration::from_secs(3));
    drain(&c);
    let texts_c = texts(&c, &gid);
    assert!(!texts_c.contains(&"正版消息".to_string()));
    assert!(!texts_c.iter().any(|t| t.contains("正版")));
}

#[test]
fn e2e_group_rename_propagates() {
    let bus = MockBus::new();
    let (a, _ta) = spawn_node(&bus);
    let (b, _tb) = spawn_node(&bus);
    let created = call(&a, "chat.create_group", json!({"name": "旧名字"}));
    let gid = created["group_id"].as_str().unwrap().to_string();
    let magnet = created["invite_magnet"].as_str().unwrap().to_string();
    call(&b, "chat.join_group", json!({"magnet": magnet}));
    wait_until(&[&a, &b], T, || {
        if msg_count(&b, &gid) >= 1 {
            Some(())
        } else {
            None
        }
    });

    call(
        &a,
        "chat.rename_group",
        json!({"group_id": gid, "name": "新群名"}),
    );

    // B must converge on the renamed display name through the signed
    // rename system message
    wait_until(&[&a, &b], T, || {
        let groups = call(&b, "chat.groups", json!({}));
        let g = groups["groups"]
            .as_array()?
            .iter()
            .find(|g| g["group_id"].as_str() == Some(gid.as_str()))?
            .clone();
        if g["name"].as_str() == Some("新群名") {
            Some(())
        } else {
            None
        }
    });

    // rename message is visible in history as a system entry
    let r = call(&b, "chat.messages", json!({"group_id": gid}));
    let has_rename = r["messages"].as_array().unwrap().iter().any(|m| {
        m["payload"]
            .as_object()
            .and_then(|p| p.get("System"))
            .and_then(|s| s.get("code"))
            .and_then(|c| c.as_str())
            == Some("rename")
    });
    assert!(has_rename);
}

#[test]
fn e2e_dm_encrypted_end_to_end() {
    let bus = MockBus::new();
    let (a, _ta) = spawn_node(&bus);
    let (b, _tb) = spawn_node(&bus);

    // shared group first (DM keys travel in message `x` fields)
    let created = call(&a, "chat.create_group", json!({"name": "同群"}));
    let gid = created["group_id"].as_str().unwrap().to_string();
    let magnet = created["invite_magnet"].as_str().unwrap().to_string();
    call(&b, "chat.join_group", json!({"magnet": magnet}));
    wait_until(&[&a, &b], T, || {
        if msg_count(&b, &gid) >= 1 {
            Some(())
        } else {
            None
        }
    });
    call(
        &b,
        "chat.send",
        json!({"group_id": gid, "text": "hi from b"}),
    );
    wait_until(&[&a, &b], T, || {
        if texts(&a, &gid).contains(&"hi from b".to_string()) {
            Some(())
        } else {
            None
        }
    });

    // A learns B's identity from the shared group and opens a DM
    let r = call(&a, "chat.messages", json!({"group_id": gid}));
    let b_pk = r["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["author_name"].as_str() != Some("旅人-ignore"))
        .map(|m| m["author_pk"].as_str().unwrap().to_string())
        .unwrap();
    let a_pk = call(&a, "sys.identity.get", json!({}))["pk"]
        .as_str()
        .unwrap()
        .to_string();
    let b_pk = if b_pk == a_pk {
        // pick the other author explicitly
        r["messages"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["author_pk"].as_str().unwrap() != a_pk.as_str())
            .unwrap()["author_pk"]
            .as_str()
            .unwrap()
            .to_string()
    } else {
        b_pk
    };
    let dm = call(&a, "chat.start_dm", json!({"author_pk": b_pk}));
    let dgid = dm["group_id"].as_str().unwrap().to_string();
    assert_eq!(dm["dm"], json!(true));

    // B auto-joins through the dm_invite system message
    wait_until(&[&a, &b], T, || {
        let groups = call(&b, "chat.groups", json!({}));
        let g = groups["groups"]
            .as_array()?
            .iter()
            .find(|g| g["group_id"].as_str() == Some(dgid.as_str()))?;
        if g["dm"] == json!(true) {
            Some(())
        } else {
            None
        }
    });

    // A sends a secret; B reads it decrypted
    call(
        &a,
        "chat.send",
        json!({"group_id": dgid, "text": "secret hello"}),
    );
    wait_until(&[&a, &b], T, || {
        if texts(&b, &dgid).contains(&"secret hello".to_string()) {
            Some(())
        } else {
            None
        }
    });
    // and A's own view decrypts too
    assert!(texts(&a, &dgid).contains(&"secret hello".to_string()));

    // on the wire / in the DHT the payload must be sealed
    let r = call(&b, "chat.messages", json!({"group_id": dgid}));
    let mid = r["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["kind"].as_i64() == Some(1) || m["payload"].get("Sealed").is_some())
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let mut target = [0u8; 20];
    target.copy_from_slice(&hex::decode(&mid).unwrap());
    let raw = bus.immutable(&target).expect("sealed item in DHT");
    assert!(!raw.windows(12).any(|w| w == b"secret hello"));
    let raw_str = String::from_utf8_lossy(&raw);
    assert!(raw_str.contains("1:ei1e"), "message must carry e=1 flag");

    // DM shows up with lock metadata and both parties agree on history
    let ta = texts(&a, &dgid);
    let tb = texts(&b, &dgid);
    assert_eq!(ta, tb);
}

#[test]
fn e2e_bt_page_flow() {
    let bus = MockBus::new();
    let (a, _ta) = spawn_node(&bus);
    // seed a file via create_seed, then fetch through magnet on a second node
    let fpath = a.path.join("data.bin");
    std::fs::write(&fpath, vec![42u8; 1024]).unwrap();
    let seeded = call(
        &a,
        "bt.create_seed",
        json!({"path": fpath.to_string_lossy()}),
    );
    let magnet = seeded["magnet"].as_str().unwrap().to_string();

    let (b, _tb) = spawn_node(&bus);
    call(&b, "bt.add", json!({"magnet": &magnet}));
    wait_until(&[&a, &b], T, || {
        let list = call(&b, "bt.list", json!({}));
        let t = list["torrents"].as_array()?.first()?.clone();
        if t["finished"].as_bool() == Some(true) {
            Some(t)
        } else {
            None
        }
    });
    // pause/resume/remove lifecycle
    let ih = seeded["infohash"].as_str().unwrap();
    call(&b, "bt.control", json!({"infohash": ih, "op": "pause"}));
    call(&b, "bt.control", json!({"infohash": ih, "op": "resume"}));
    let list = call(&b, "bt.list", json!({}));
    assert!(list["torrents"]
        .as_array()
        .unwrap()
        .iter()
        .any(|t| t["infohash"] == json!(ih)));
    call(
        &b,
        "bt.control",
        json!({"infohash": ih, "op": "remove", "delete_files": true}),
    );
    let list = call(&b, "bt.list", json!({}));
    assert!(!list["torrents"]
        .as_array()
        .unwrap()
        .iter()
        .any(|t| t["infohash"] == json!(ih)));
}

#[test]
fn e2e_filter_rules_block_and_validate() {
    let bus = MockBus::new();
    let (a, _ta) = spawn_node(&bus);
    let (b, _tb) = spawn_node(&bus);
    let created = call(&a, "chat.create_group", json!({"name": "过滤群"}));
    let gid = created["group_id"].as_str().unwrap().to_string();
    let magnet = created["invite_magnet"].as_str().unwrap().to_string();
    call(&b, "chat.join_group", json!({"magnet": magnet}));
    wait_until(&[&a, &b], T, || {
        if msg_count(&b, &gid) >= 1 {
            Some(())
        } else {
            None
        }
    });
    call(
        &b,
        "chat.send",
        json!({"group_id": gid, "text": "spammy ad here"}),
    );
    wait_until(&[&a, &b], T, || {
        if texts(&a, &gid).iter().any(|t| t.contains("spammy")) {
            Some(())
        } else {
            None
        }
    });

    // invalid regex rejected
    let bad = try_call(
        &a,
        "filter.set_rules",
        json!({"rules": [{
            "id": 1, "enabled": true, "field": "text",
            "mode": "regex", "value": "("
        }]}),
    );
    assert!(bad.is_err());

    // block by content
    call(
        &a,
        "filter.set_rules",
        json!({"rules": [{
            "id": 1, "enabled": true, "field": "text",
            "mode": "contains", "value": "spammy", "case_sensitive": false
        }]}),
    );
    let r = call(&a, "chat.messages", json!({"group_id": gid}));
    let blocked_count = r["messages"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|m| m["blocked"] == json!(true))
        .count();
    assert_eq!(blocked_count, 1);

    // sender never blocks their own message
    let r = call(&b, "chat.messages", json!({"group_id": gid}));
    assert!(r["messages"]
        .as_array()
        .unwrap()
        .iter()
        .all(|m| m["blocked"] != json!(true)));

    // rule list round-trip
    let rules = call(&a, "filter.rules", json!({}));
    assert_eq!(rules["rules"].as_array().unwrap().len(), 1);

    // disable -> unblocked
    call(
        &a,
        "filter.set_rules",
        json!({"rules": [{
            "id": 1, "enabled": false, "field": "text",
            "mode": "contains", "value": "spammy", "case_sensitive": false
        }]}),
    );
    let r = call(&a, "chat.messages", json!({"group_id": gid}));
    assert!(r["messages"]
        .as_array()
        .unwrap()
        .iter()
        .all(|m| m["blocked"] != json!(true)));
}

#[test]
fn dispatch_errors_are_graceful() {
    let bus = MockBus::new();
    let (a, _ta) = spawn_node(&bus);
    assert!(try_call(&a, "chat.messages", json!({"group_id": "deadbeef"})).is_err());
    assert!(try_call(&a, "no.such.method", json!({})).is_err());
    assert!(try_call(&a, "chat.send", json!({"group_id": "aa", "text": "x"})).is_err());
    let info = call(&a, "sys.info", json!({}));
    assert_eq!(info["engine"].as_str(), Some("mock"));
}
