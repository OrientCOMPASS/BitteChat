//! End-to-end tests of the full chat stack on the mock engine bus:
//! two independent `Api` instances behave like two users' phones.

use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Value as Json};

use bitte_core::api::Api;
use bitte_core::mock::{MockBus, MockEngine};

struct Node {
    api: Api,
    events: Receiver<String>,
    path: std::path::PathBuf,
    /// sys.log events collected by `drain` for failure diagnostics
    logs: Arc<Mutex<Vec<String>>>,
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
            logs: Arc::new(Mutex::new(Vec::new())),
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
        logs: Arc::new(Mutex::new(Vec::new())),
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

/// Drain pending events (non-blocking) as JSON values; sys.log entries are
/// kept on the node for failure diagnostics.
fn drain(node: &Node) -> Vec<Json> {
    let mut out = Vec::new();
    while let Ok(s) = node.events.try_recv() {
        if let Ok(v) = serde_json::from_str::<Json>(&s) {
            if v["type"].as_str() == Some("sys.log") {
                if let Ok(mut logs) = node.logs.lock() {
                    logs.push(v["data"]["msg"].as_str().unwrap_or("?").to_string());
                }
            }
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

/// Like `wait_until` but panics with a state dump for diagnosis.
fn wait_dbg<T>(
    nodes: &[&Node],
    timeout: Duration,
    label: &str,
    dump: impl Fn() -> String,
    mut cond: impl FnMut() -> Option<T>,
) -> T {
    let start = Instant::now();
    loop {
        for n in nodes {
            drain(n);
        }
        if let Some(v) = cond() {
            return v;
        }
        if start.elapsed() > timeout {
            panic!(
                "condition not met within {timeout:?}: {label}\nDUMP:\n{}",
                dump()
            );
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Full chat/bt state of one node as a debug string.
fn dump_node(n: &Node, tag: &str) -> String {
    let groups = n
        .api
        .dispatch("chat.groups", json!({}))
        .map(|g| g["groups"].clone())
        .unwrap_or(json!("ERR"));
    let bt = n
        .api
        .dispatch("bt.list", json!({"include_chat": true}))
        .map(|b| b["torrents"].clone())
        .unwrap_or(json!("ERR"));
    let logs = n
        .logs
        .lock()
        .map(|l| l.join(" | "))
        .unwrap_or_else(|e| format!("LOG ERR {e}"));
    format!("[{tag}] groups={groups}\n[{tag}] torrents={bt}\n[{tag}] logs={logs}\n")
}

const T: Duration = Duration::from_secs(15);

fn texts(node: &Node, gid: &str) -> Vec<String> {
    let r = call(node, "chat.messages", json!({"group_id": gid}));
    r["messages"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|m| m["payload"]["Text"]["text"].as_str().map(String::from))
        .collect()
}

/// A seeds a real torrent and enters its chat room (a torrent IS a room;
/// the room id equals the infohash). Returns (gid == infohash, magnet).
fn seed_room(a: &Node, tag: &str) -> (String, String) {
    let fpath = a.path.join(format!("room-{tag}.bin"));
    std::fs::write(&fpath, format!("content of {tag}").as_bytes()).unwrap();
    let seeded = call(
        a,
        "bt.create_seed",
        json!({"path": fpath.to_string_lossy()}),
    );
    let ih = seeded["infohash"].as_str().unwrap().to_string();
    let magnet = seeded["magnet"].as_str().unwrap().to_string();
    // entering by BARE infohash exercises the hash-only input path
    let joined = call(a, "chat.join_group", json!({"magnet": &ih}));
    assert_eq!(joined["group_id"].as_str().unwrap(), ih.as_str());
    (ih, magnet)
}

/// Enter the chat room of a torrent from a magnet or bare hash.
fn join_room(n: &Node, invite: &str) -> String {
    let r = call(n, "chat.join_group", json!({"magnet": invite}));
    r["group_id"].as_str().unwrap().to_string()
}

/// Wait until `gid` shows up in the node's chat group list.
fn wait_group(n: &Node, gid: &str) {
    wait_until(&[n], T, || {
        let groups = call(n, "chat.groups", json!({}));
        groups["groups"]
            .as_array()?
            .iter()
            .find(|g| g["group_id"].as_str() == Some(gid))?;
        Some(())
    });
}

#[test]
fn e2e_torrent_room_chat() {
    let bus = MockBus::new();
    let (a, _ta) = spawn_node(&bus);
    let (b, _tb) = spawn_node(&bus);

    // A seeds a regular torrent — its infohash IS the chat room id
    let (gid, magnet) = seed_room(&a, "dev");
    assert_eq!(gid.len(), 40);
    assert!(magnet.starts_with("magnet:?xt=urn:btih:"));

    // B enters the same room via the magnet; re-entering is idempotent
    assert_eq!(join_room(&b, &magnet), gid);
    let again = call(&b, "chat.join_group", json!({"magnet": &gid}));
    assert_eq!(again["already"], json!(true));

    // the room's torrent stays a visible BT task on both nodes, bound to
    // the group
    for n in [&a, &b] {
        let list = call(n, "bt.list", json!({}));
        let t = list["torrents"]
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["infohash"].as_str() == Some(gid.as_str()))
            .expect("room torrent visible on BT page")
            .clone();
        assert_eq!(t["group_id"].as_str().unwrap(), gid.as_str());
    }

    // room name follows the torrent name
    let groups = call(&a, "chat.groups", json!({}));
    let g = groups["groups"]
        .as_array()
        .unwrap()
        .iter()
        .find(|g| g["group_id"].as_str() == Some(gid.as_str()))
        .unwrap()
        .clone();
    assert_eq!(g["name"].as_str().unwrap(), "room-dev.bin");
    assert_eq!(g["dm"], json!(false));

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

    // leaving the room keeps the torrent task (it is the user's download),
    // only the chat binding goes away
    call(&b, "chat.leave_group", json!({"group_id": gid}));
    let groups = call(&b, "chat.groups", json!({}));
    assert!(!groups["groups"]
        .as_array()
        .unwrap()
        .iter()
        .any(|g| g["group_id"].as_str() == Some(gid.as_str())));
    let list = call(&b, "bt.list", json!({}));
    let t = list["torrents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["infohash"].as_str() == Some(gid.as_str()))
        .expect("torrent survives leaving the room")
        .clone();
    assert_eq!(t["group_id"].as_str().unwrap(), "");
    // ...and B can re-enter later, history intact
    assert_eq!(join_room(&b, &gid), gid);
    wait_until(&[&b], T, || {
        if texts(&b, &gid).contains(&"大家好".to_string()) {
            Some(())
        } else {
            None
        }
    });
}

#[test]
fn e2e_offline_dht_sync() {
    let bus = MockBus::new();
    let dir_b = tempfile::tempdir().unwrap();
    let gid;
    {
        let (a, _ta) = spawn_node(&bus);
        let b = spawn_node_at(&bus, dir_b.path());

        let (gid2, magnet) = seed_room(&a, "offline");
        gid = gid2;
        join_room(&b, &magnet);
        call(
            &a,
            "chat.send",
            json!({"group_id": gid, "text": "在线时的一条"}),
        );
        wait_until(&[&a, &b], T, || {
            if texts(&b, &gid).contains(&"在线时的一条".to_string()) {
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
    wait_group(&b2, &gid);
    wait_until(&[&b2], Duration::from_secs(30), || {
        if texts(&b2, &gid).contains(&"错过了一条".to_string()) {
            Some(())
        } else {
            None
        }
    });
    // the restored room is re-bound to its torrent task
    let list = call(&b2, "bt.list", json!({}));
    assert!(list["torrents"]
        .as_array()
        .unwrap()
        .iter()
        .any(|t| t["infohash"].as_str() == Some(gid.as_str())));
}

/// Leaving a room with `delete_history` wipes the LOCAL chain (messages +
/// heads + outbox) so re-entering the same infohash starts from scratch —
/// the recovery path for "I joined the wrong hash chain".
#[test]
fn e2e_leave_group_can_reset_local_history() {
    let bus = MockBus::new();
    let (a, _ta) = spawn_node(&bus);
    let (b, _tb) = spawn_node(&bus);

    let (gid, magnet) = seed_room(&a, "reset");
    join_room(&b, &magnet);
    call(
        &a,
        "chat.send",
        json!({"group_id": gid, "text": "会被清掉的一条"}),
    );
    wait_until(&[&a, &b], T, || {
        if texts(&b, &gid).contains(&"会被清掉的一条".to_string()) {
            Some(())
        } else {
            None
        }
    });

    // leaving WITHOUT delete_history keeps the local chain (existing behavour)
    call(&b, "chat.leave_group", json!({"group_id": gid}));
    assert_eq!(join_room(&b, &gid), gid);
    assert!(
        texts(&b, &gid).contains(&"会被清掉的一条".to_string()),
        "leave without delete_history must keep the local history"
    );

    // leaving WITH delete_history drops everything local, heads included
    call(
        &b,
        "chat.leave_group",
        json!({"group_id": gid, "delete_history": true}),
    );
    assert_eq!(join_room(&b, &gid), gid);
    assert!(
        texts(&b, &gid).is_empty(),
        "delete_history must wipe the local chain: {:?}",
        texts(&b, &gid)
    );
    let detail = call(&b, "chat.group_detail", json!({"group_id": gid}));
    assert_eq!(
        detail["messages"].as_i64().unwrap_or(-1),
        0,
        "purged room must report zero stored messages: {detail}"
    );
    assert!(
        detail["heads"]
            .as_array()
            .map(|h| h.is_empty())
            .unwrap_or(false),
        "purged room must have no DAG heads left: {detail}"
    );

    // the reset is LOCAL only: the chain still lives in the swarm/DHT, so a
    // fresh sync pulls it back (i.e. we deleted our copy, not the room)
    call(&b, "chat.sync", json!({"group_id": gid}));
    wait_until(&[&a, &b], T, || {
        if texts(&b, &gid).contains(&"会被清掉的一条".to_string()) {
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

    let (gid, magnet) = seed_room(&a, "files");
    join_room(&b, &magnet);

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
    // v0.5.2: heavy work (hash + copy) runs on a worker thread — the call
    // returns a job id immediately and the message arrives via events
    assert!(sent["job_id"].as_str().is_some(), "send_file must be async");

    // B sees the attachment message; the infohash comes from the message
    let ih = wait_until(&[&a, &b], T, || {
        let r = call(&b, "chat.messages", json!({"group_id": gid}));
        r["messages"].as_array()?.iter().find_map(|m| {
            m["payload"]["Attachment"]["infohash"]
                .as_str()
                .map(|s| s.to_string())
        })
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
    let (gid, magnet) = seed_room(&a, "longtext");
    join_room(&b, &magnet);

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
    let (gid, magnet) = seed_room(&a, "tamper");
    join_room(&b, &magnet);

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
    join_room(&c, &magnet);
    // C learns the head pointers (ext announcement + DHT) but the corrupted
    // immutable item fails verification, so the text never appears
    std::thread::sleep(Duration::from_secs(3));
    drain(&c);
    let texts_c = texts(&c, &gid);
    assert!(!texts_c.contains(&"正版消息".to_string()));
    assert!(!texts_c.iter().any(|t| t.contains("正版")));
}

#[test]
fn e2e_group_rename_is_local_only() {
    let bus = MockBus::new();
    let (a, _ta) = spawn_node(&bus);
    let (b, _tb) = spawn_node(&bus);
    let (gid, magnet) = seed_room(&a, "rename");
    join_room(&b, &magnet);

    call(
        &a,
        "chat.rename_group",
        json!({"group_id": gid, "name": "A 的本地备注"}),
    );

    // A sees its local note immediately
    let groups = call(&a, "chat.groups", json!({}));
    let ga = groups["groups"]
        .as_array()
        .unwrap()
        .iter()
        .find(|g| g["group_id"].as_str() == Some(gid.as_str()))
        .unwrap()
        .clone();
    assert_eq!(ga["name"].as_str(), Some("A 的本地备注"));

    // v0.5.2: names are LOCAL — B keeps the torrent-derived name and no
    // rename system message is broadcast
    std::thread::sleep(std::time::Duration::from_secs(2));
    let groups = call(&b, "chat.groups", json!({}));
    let gb = groups["groups"]
        .as_array()
        .unwrap()
        .iter()
        .find(|g| g["group_id"].as_str() == Some(gid.as_str()))
        .unwrap()
        .clone();
    assert_ne!(gb["name"].as_str(), Some("A 的本地备注"));
    assert_eq!(gb["name"].as_str(), Some("room-rename.bin"));
    let r = call(&b, "chat.messages", json!({"group_id": gid}));
    let has_rename = r["messages"].as_array().unwrap().iter().any(|m| {
        m["payload"]
            .as_object()
            .and_then(|p| p.get("System"))
            .and_then(|s| s.get("code"))
            .and_then(|c| c.as_str())
            == Some("rename")
    });
    assert!(!has_rename, "rename must not be broadcast anymore");
}

#[test]
fn e2e_dm_encrypted_end_to_end() {
    let bus = MockBus::new();
    let (a, _ta) = spawn_node(&bus);
    let (b, _tb) = spawn_node(&bus);

    // shared torrent room first (DM keys travel in message `x` fields)
    let (gid, magnet) = seed_room(&a, "dm-shared");
    join_room(&b, &magnet);
    call(
        &b,
        "chat.send",
        json!({"group_id": gid, "text": "hi from b"}),
    );
    wait_dbg(
        &[&a, &b],
        T,
        "A must see 'hi from b' in the shared room",
        || {
            format!(
                "{}{}\nA texts={:?}\nB texts={:?}",
                dump_node(&a, "A"),
                dump_node(&b, "B"),
                texts(&a, &gid),
                texts(&b, &gid)
            )
        },
        || {
            if texts(&a, &gid).contains(&"hi from b".to_string()) {
                Some(())
            } else {
                None
            }
        },
    );

    // A learns B's identity from the shared group and requests a DM
    let r = call(&a, "chat.messages", json!({"group_id": gid}));
    let a_pk = call(&a, "sys.identity.get", json!({}));
    let a_pk = a_pk["pk"].as_str().unwrap().to_string();
    let b_pk = r["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["author_pk"].as_str().unwrap() != a_pk.as_str())
        .unwrap()["author_pk"]
        .as_str()
        .unwrap()
        .to_string();
    let dm = call(&a, "chat.start_dm", json!({"author_pk": b_pk}));
    let dgid = dm["group_id"].as_str().unwrap().to_string();
    assert_eq!(dm["dm"], json!(true));
    assert_eq!(dm["pending"], json!(true));
    assert_eq!(dm["sent"], json!(true), "B is connected — req must deliver");

    // B sees the request in its pending list (UI prompts from here)
    wait_dbg(
        &[&a, &b],
        T,
        "B must receive the DM request",
        || format!("{}{}", dump_node(&a, "A"), dump_node(&b, "B")),
        || {
            let reqs = call(&b, "chat.dm_requests", json!({}));
            reqs["requests"]
                .as_array()?
                .iter()
                .find(|q| q["group_id"].as_str() == Some(dgid.as_str()))
                .cloned()
        },
    );
    // Plan-B inbox: the request shows as an inline conversation-list entry
    // (dm_request=true), but NO established channel may exist before consent
    let groups = call(&b, "chat.groups", json!({}));
    let entry = groups["groups"]
        .as_array()
        .unwrap()
        .iter()
        .find(|g| g["group_id"].as_str() == Some(dgid.as_str()))
        .cloned()
        .expect("pending request must appear in B's conversation list");
    assert_eq!(entry["dm_request"], json!(true));
    assert_eq!(entry["dm"], json!(true));
    assert!(!entry["peer_pk"].as_str().unwrap_or("").is_empty());

    // B accepts
    let resp = call(
        &b,
        "chat.dm_respond",
        json!({"group_id": dgid, "accept": true}),
    );
    assert_eq!(resp["accepted"], json!(true));

    // A learns the channel is established (awaiting_accept clears when the
    // signed DmAccept arrives)
    wait_dbg(
        &[&a, &b],
        T,
        "A must see the DM accepted",
        || format!("{}{}", dump_node(&a, "A"), dump_node(&b, "B")),
        || {
            let groups = call(&a, "chat.groups", json!({}));
            let g = groups["groups"]
                .as_array()?
                .iter()
                .find(|g| g["group_id"].as_str() == Some(dgid.as_str()))?
                .clone();
            if g["awaiting_accept"] == json!(false) {
                Some(())
            } else {
                None
            }
        },
    );

    // A sends a secret; B reads it decrypted
    call(
        &a,
        "chat.send",
        json!({"group_id": dgid, "text": "secret hello"}),
    );
    wait_dbg(
        &[&a, &b],
        T,
        "B must see the decrypted DM text",
        || {
            format!(
                "{}{}\nA dm texts={:?}\nB dm texts={:?}",
                dump_node(&a, "A"),
                dump_node(&b, "B"),
                texts(&a, &dgid),
                texts(&b, &dgid)
            )
        },
        || {
            if texts(&b, &dgid).contains(&"secret hello".to_string()) {
                Some(())
            } else {
                None
            }
        },
    );
    // and A's own view decrypts too
    assert!(texts(&a, &dgid).contains(&"secret hello".to_string()));

    // v0.5.2 privacy: the sealed DM message must NEVER reach the DHT and the
    // channel must not have created a torrent anywhere
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
    assert!(
        bus.immutable(&target).is_none(),
        "DM messages must not be stored in the DHT"
    );
    for node in [&a, &b] {
        let list = call(node, "bt.list", json!({"include_chat": true}));
        assert!(
            !list["torrents"]
                .as_array()
                .unwrap()
                .iter()
                .any(|t| t["group_id"].as_str() == Some(dgid.as_str())),
            "DM must not create a torrent"
        );
    }

    // ack pipeline: A's message leaves the outbox once B's DmAck arrives
    wait_dbg(
        &[&a, &b],
        T,
        "A's DM message must reach confirmed state via DmAck",
        || format!("{}{}", dump_node(&a, "A"), dump_node(&b, "B")),
        || {
            let r = call(&a, "chat.messages", json!({"group_id": dgid}));
            let m = r["messages"]
                .as_array()?
                .iter()
                .find(|m| m["id"].as_str() == Some(mid.as_str()))?
                .clone();
            if m["state"].as_i64() == Some(1) {
                Some(())
            } else {
                None
            }
        },
    );

    // both parties agree on history
    let ta = texts(&a, &dgid);
    let tb = texts(&b, &dgid);
    assert_eq!(ta, tb);
    assert!(ta.contains(&"secret hello".to_string()));

    // B replies; A receives (bidirectional)
    call(
        &b,
        "chat.send",
        json!({"group_id": dgid, "text": "secret reply"}),
    );
    wait_dbg(
        &[&a, &b],
        T,
        "A must see B's reply",
        || format!("{}{}", dump_node(&a, "A"), dump_node(&b, "B")),
        || {
            if texts(&a, &dgid).contains(&"secret reply".to_string()) {
                Some(())
            } else {
                None
            }
        },
    );
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
    let (gid, magnet) = seed_room(&a, "filter");
    join_room(&b, &magnet);
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
fn e2e_identity_profiles() {
    let bus = MockBus::new();
    let (a, _ta) = spawn_node(&bus);
    let (b, _tb) = spawn_node(&bus);

    // baseline identity
    let id0 = call(&a, "sys.identity.get", json!({}));
    let pk0 = id0["pk"].as_str().unwrap().to_string();
    let list = call(&a, "sys.identity.list", json!({}));
    assert_eq!(list["identities"].as_array().unwrap().len(), 1);
    assert!(list["identities"][0]["active"].as_bool().unwrap());

    // deleting the active identity is rejected
    let err = try_call(&a, "sys.identity.delete", json!({"id": 1}));
    assert!(err.is_err());

    // create a new identity (new nickname == new keypair, per design)
    let created = call(&a, "sys.identity.create", json!({"name": "新身份"}));
    let id1 = created["id"].as_i64().unwrap();
    assert_ne!(created["pk"].as_str().unwrap(), pk0);

    // switch: subsequent messages are signed with the new key
    call(&a, "sys.identity.switch", json!({"id": id1}));
    let now_id = call(&a, "sys.identity.get", json!({}));
    assert_eq!(
        now_id["pk"].as_str().unwrap(),
        created["pk"].as_str().unwrap()
    );
    assert_eq!(now_id["name"].as_str().unwrap(), "新身份");

    let (gid, magnet) = seed_room(&a, "identity");
    call(
        &a,
        "chat.send",
        json!({"group_id": gid, "text": "signed by id1"}),
    );
    let r = call(&a, "chat.messages", json!({"group_id": gid}));
    let msg = r["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["payload"]["Text"]["text"].as_str() == Some("signed by id1"))
        .unwrap()
        .clone();
    assert_eq!(
        msg["author_pk"].as_str().unwrap(),
        created["pk"].as_str().unwrap()
    );

    // B still receives & verifies it (signature is self-contained)
    call(&b, "chat.join_group", json!({"magnet": magnet}));
    wait_until(&[&a, &b], T, || {
        if texts(&b, &gid).contains(&"signed by id1".to_string()) {
            Some(())
        } else {
            None
        }
    });

    // delete the now-inactive old identity
    call(&a, "sys.identity.delete", json!({"id": 1}));
    let list = call(&a, "sys.identity.list", json!({}));
    assert_eq!(list["identities"].as_array().unwrap().len(), 1);
}

#[test]
fn e2e_hash_input_and_default_trackers() {
    let bus = MockBus::new();
    let (a, _ta) = spawn_node(&bus);
    let (b, _tb) = spawn_node(&bus);

    // A seeds a file so the torrent exists on the bus
    let fpath = a.path.join("tracked.bin");
    std::fs::write(&fpath, b"tracker payload").unwrap();
    let seeded = call(
        &a,
        "bt.create_seed",
        json!({"path": fpath.to_string_lossy()}),
    );
    let ih = seeded["infohash"].as_str().unwrap().to_string();

    // invalid default tracker lists are rejected
    let bad = try_call(
        &a,
        "bt.set_default_trackers",
        json!({"trackers": ["file:///x", "udp://ok.example:1337/announce"]}),
    );
    assert!(bad.is_err());

    // set a valid default
    call(
        &b,
        "bt.set_default_trackers",
        json!({"trackers": ["udp://tracker.opentrackr.org:1337/announce"]}),
    );
    let got = call(&b, "bt.get_default_trackers", json!({}));
    assert_eq!(got["trackers"].as_array().unwrap().len(), 1);

    // B adds by BARE UPPERCASE HASH — no magnet needed
    let added = call(&b, "bt.add", json!({"magnet": ih.to_uppercase()}));
    assert_eq!(added["infohash"].as_str().unwrap(), ih.as_str());
    let stored = added["magnet"].as_str().unwrap().to_string();
    assert!(stored.starts_with(&format!("magnet:?xt=urn:btih:{ih}")));
    assert!(
        stored.contains("tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce"),
        "default tracker must be merged into the stored magnet: {stored}"
    );

    // the engine torrent carries the tracker too
    let tr = call(&b, "bt.trackers", json!({"infohash": ih}));
    let arr = tr["trackers"].as_array().unwrap();
    assert_eq!(arr.len(), 1);
    assert_eq!(
        arr[0]["url"].as_str().unwrap(),
        "udp://tracker.opentrackr.org:1337/announce"
    );

    // per-torrent add/remove, with URL validation
    let bad = try_call(
        &b,
        "bt.add_tracker",
        json!({"infohash": ih, "url": "ftp://x.example/announce"}),
    );
    assert!(bad.is_err());
    call(
        &b,
        "bt.add_tracker",
        json!({"infohash": ih, "url": "https://t.example/announce"}),
    );
    let tr = call(&b, "bt.trackers", json!({"infohash": ih}));
    assert_eq!(tr["trackers"].as_array().unwrap().len(), 2);
    call(
        &b,
        "bt.remove_tracker",
        json!({"infohash": ih, "url": "https://t.example/announce"}),
    );
    let tr = call(&b, "bt.trackers", json!({"infohash": ih}));
    assert_eq!(tr["trackers"].as_array().unwrap().len(), 1);
    // removal also strips it from the stored magnet
    let list = call(&b, "bt.list", json!({}));
    let t = list["torrents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["infohash"] == json!(ih))
        .unwrap()
        .clone();
    let m = t["magnet"].as_str().unwrap().to_string();
    assert!(!m.contains("t.example"), "tracker removed from magnet: {m}");

    // entering the room by bare hash reuses the same BT task
    let joined = call(&b, "chat.join_group", json!({"magnet": &ih}));
    assert_eq!(joined["group_id"].as_str().unwrap(), ih.as_str());
    let list = call(&b, "bt.list", json!({}));
    let t = list["torrents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["infohash"] == json!(ih))
        .unwrap()
        .clone();
    assert_eq!(t["group_id"].as_str().unwrap(), ih.as_str());

    // base32 infohash input works as well
    let b32 = base32_encode(&hex::decode(&ih).unwrap());
    let joined2 = call(&a, "chat.join_group", json!({"magnet": &b32}));
    assert_eq!(joined2["group_id"].as_str().unwrap(), ih.as_str());
}

/// RFC4648 base32 (no padding) — mirrors what clients emit for v1 hashes.
fn base32_encode(data: &[u8]) -> String {
    const ALPHA: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    let mut out = String::new();
    let mut buf = 0u32;
    let mut bits = 0u32;
    for &b in data {
        buf = (buf << 8) | b as u32;
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            out.push(ALPHA[((buf >> bits) & 0x1F) as usize] as char);
        }
    }
    if bits > 0 {
        out.push(ALPHA[((buf << (5 - bits)) & 0x1F) as usize] as char);
    }
    out
}

#[test]
fn dispatch_errors_are_graceful() {
    let bus = MockBus::new();
    let (a, _ta) = spawn_node(&bus);
    assert!(try_call(&a, "chat.messages", json!({"group_id": "deadbeef"})).is_err());
    assert!(try_call(&a, "no.such.method", json!({})).is_err());
    assert!(try_call(&a, "chat.send", json!({"group_id": "aa", "text": "x"})).is_err());
    // "create a group from nothing" is gone — torrents are the rooms now
    assert!(try_call(&a, "chat.create_group", json!({"name": "x"})).is_err());
    // garbage join input is rejected with a helpful error
    let err = try_call(&a, "chat.join_group", json!({"magnet": "hello world"}));
    assert!(err.is_err());
    let info = call(&a, "sys.info", json!({}));
    assert_eq!(info["engine"].as_str(), Some("mock"));
}
