//! SQLite persistence: identity, groups, the chat object store (git-like),
//! torrent registry and RSS feeds/items.

use rusqlite::{params, Connection, OptionalExtension};

use crate::chat::message::{ChatMessage, MsgKind, Payload, SignedMessage};
use crate::chat::GroupManifest;
use crate::crypto::Sha1Hash;
use crate::{CoreError, Result};

pub struct Store {
    conn: Connection,
}

#[derive(Debug, Clone)]
pub struct GroupRow {
    pub gid: Sha1Hash,
    pub name: String,
    pub avatar: Vec<u8>,
    pub magnet: String,
    pub manifest: GroupManifest,
    pub head_seq: i64,
    pub created: i64,
    pub joined: i64,
    pub last_read_ts: i64,
    pub left: bool,
}

#[derive(Debug, Clone)]
pub struct TorrentRow {
    pub infohash: String,
    pub name: String,
    pub magnet: String,
    pub save_path: String,
    /// 0 normal, 1 group manifest, 2 chat attachment, 3 rss download
    pub kind: i32,
    pub group_id: Option<Sha1Hash>,
    pub added: i64,
}

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS groups (
  id BLOB PRIMARY KEY,
  name TEXT NOT NULL,
  avatar BLOB NOT NULL DEFAULT x'',
  magnet TEXT NOT NULL,
  manifest BLOB NOT NULL,
  head_seq INTEGER NOT NULL DEFAULT 0,
  created INTEGER NOT NULL,
  joined INTEGER NOT NULL,
  last_read_ts INTEGER NOT NULL DEFAULT 0,
  left_flag INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS messages (
  id BLOB PRIMARY KEY,
  group_id BLOB NOT NULL,
  author_pk BLOB NOT NULL,
  author_name TEXT NOT NULL DEFAULT '',
  ts INTEGER NOT NULL,
  seq INTEGER NOT NULL DEFAULT 0,
  kind INTEGER NOT NULL,
  body BLOB NOT NULL,
  parents TEXT NOT NULL DEFAULT '',
  state INTEGER NOT NULL DEFAULT 1,
  chunk_cid BLOB,
  chunk_idx INTEGER,
  chunk_total INTEGER
);
CREATE INDEX IF NOT EXISTS idx_msg_group ON messages(group_id, ts, id);
CREATE INDEX IF NOT EXISTS idx_msg_chunk ON messages(group_id, chunk_cid);
CREATE TABLE IF NOT EXISTS heads (
  group_id BLOB NOT NULL,
  id BLOB NOT NULL,
  PRIMARY KEY (group_id, id)
);
CREATE TABLE IF NOT EXISTS missing (
  group_id BLOB NOT NULL,
  id BLOB NOT NULL,
  PRIMARY KEY (group_id, id)
);
CREATE TABLE IF NOT EXISTS outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  group_id BLOB NOT NULL,
  msg_id BLOB NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_try INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS torrents (
  infohash TEXT PRIMARY KEY,
  name TEXT NOT NULL DEFAULT '',
  magnet TEXT NOT NULL DEFAULT '',
  save_path TEXT NOT NULL DEFAULT '',
  kind INTEGER NOT NULL DEFAULT 0,
  group_id BLOB,
  added INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS feeds (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  url TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL DEFAULT '',
  last_fetch INTEGER NOT NULL DEFAULT 0,
  error TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  feed_id INTEGER NOT NULL,
  guid TEXT NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  link TEXT NOT NULL DEFAULT '',
  author TEXT NOT NULL DEFAULT '',
  content TEXT NOT NULL DEFAULT '',
  ts INTEGER NOT NULL DEFAULT 0,
  read_flag INTEGER NOT NULL DEFAULT 0,
  magnet TEXT NOT NULL DEFAULT '',
  enclosure_url TEXT NOT NULL DEFAULT '',
  enclosure_type TEXT NOT NULL DEFAULT '',
  UNIQUE(feed_id, guid)
);
CREATE INDEX IF NOT EXISTS idx_items_feed ON items(feed_id, ts DESC);
"#;

fn hash_from_blob(b: &[u8]) -> Result<Sha1Hash> {
    if b.len() != 20 {
        return Err(CoreError::Internal("bad hash blob in store".into()));
    }
    let mut h = [0u8; 20];
    h.copy_from_slice(b);
    Ok(h)
}

impl Store {
    pub fn open(path: &std::path::Path) -> Result<Store> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.execute_batch(SCHEMA)?;
        Ok(Store { conn })
    }

    pub fn open_in_memory() -> Result<Store> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch(SCHEMA)?;
        Ok(Store { conn })
    }

    // ---- kv ------------------------------------------------------------

    pub fn kv_get(&self, k: &str) -> Result<Option<Vec<u8>>> {
        Ok(self
            .conn
            .query_row("SELECT v FROM kv WHERE k=?1", params![k], |r| r.get(0))
            .optional()?)
    }

    pub fn kv_set(&self, k: &str, v: &[u8]) -> Result<()> {
        self.conn.execute(
            "INSERT INTO kv(k,v) VALUES(?1,?2) ON CONFLICT(k) DO UPDATE SET v=?2",
            params![k, v],
        )?;
        Ok(())
    }

    // ---- groups ----------------------------------------------------------

    pub fn group_upsert(&self, g: &GroupRow) -> Result<()> {
        self.conn.execute(
            "INSERT INTO groups(id,name,avatar,magnet,manifest,head_seq,created,joined,last_read_ts,left_flag)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)
             ON CONFLICT(id) DO UPDATE SET name=?2, avatar=?3, magnet=?4, manifest=?5",
            params![
                g.gid.to_vec(),
                g.name,
                g.avatar,
                g.magnet,
                g.manifest.encode(),
                g.head_seq,
                g.created,
                g.joined,
                g.last_read_ts,
                g.left as i64
            ],
        )?;
        Ok(())
    }

    pub fn group_update_head_seq(&self, gid: &Sha1Hash, seq: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE groups SET head_seq=?2 WHERE id=?1",
            params![gid.to_vec(), seq],
        )?;
        Ok(())
    }

    pub fn group_set_last_read(&self, gid: &Sha1Hash, ts: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE groups SET last_read_ts=?2 WHERE id=?1",
            params![gid.to_vec(), ts],
        )?;
        Ok(())
    }

    /// Delete all chat data of a group (history purge on leave).
    pub fn group_purge(&self, gid: &Sha1Hash) -> Result<()> {
        let g = gid.to_vec();
        self.conn
            .execute("DELETE FROM messages WHERE group_id=?1", params![g])?;
        self.conn
            .execute("DELETE FROM heads WHERE group_id=?1", params![g])?;
        self.conn
            .execute("DELETE FROM missing WHERE group_id=?1", params![g])?;
        self.conn
            .execute("DELETE FROM outbox WHERE group_id=?1", params![g])?;
        Ok(())
    }

    pub fn group_set_name(&self, gid: &Sha1Hash, name: &str) -> Result<()> {
        self.conn.execute(
            "UPDATE groups SET name=?2 WHERE id=?1",
            params![gid.to_vec(), name],
        )?;
        Ok(())
    }

    pub fn group_set_left(&self, gid: &Sha1Hash, left: bool) -> Result<()> {
        self.conn.execute(
            "UPDATE groups SET left_flag=?2 WHERE id=?1",
            params![gid.to_vec(), left as i64],
        )?;
        Ok(())
    }

    pub fn group_get(&self, gid: &Sha1Hash) -> Result<Option<GroupRow>> {
        self.group_row(
            "SELECT id,name,avatar,magnet,manifest,head_seq,created,joined,last_read_ts,left_flag
             FROM groups WHERE id=?1",
            params![gid.to_vec()],
        )
    }

    pub fn group_by_magnet_ih(&self, infohash_hex: &str) -> Result<Option<GroupRow>> {
        self.group_row(
            "SELECT id,name,avatar,magnet,manifest,head_seq,created,joined,last_read_ts,left_flag
             FROM groups WHERE magnet LIKE '%' || ?1 || '%'",
            params![infohash_hex.to_lowercase()],
        )
    }

    pub fn groups_all(&self) -> Result<Vec<GroupRow>> {
        let mut st = self.conn.prepare(
            "SELECT id,name,avatar,magnet,manifest,head_seq,created,joined,last_read_ts,left_flag
                     FROM groups ORDER BY joined ASC",
        )?;
        let rows = st.query_map([], Self::map_group)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    fn group_row(&self, sql: &str, p: impl rusqlite::Params) -> Result<Option<GroupRow>> {
        let mut st = self.conn.prepare(sql)?;
        let mut rows = st.query_map(p, Self::map_group)?;
        match rows.next() {
            Some(r) => Ok(Some(r?)),
            None => Ok(None),
        }
    }

    fn map_group(r: &rusqlite::Row<'_>) -> rusqlite::Result<GroupRow> {
        let idb: Vec<u8> = r.get(0)?;
        let manifest_b: Vec<u8> = r.get(4)?;
        Ok(GroupRow {
            gid: hash_from_blob(&idb)
                .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?,
            name: r.get(1)?,
            avatar: r.get(2)?,
            magnet: r.get(3)?,
            manifest: GroupManifest::decode(&manifest_b)
                .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?,
            head_seq: r.get(5)?,
            created: r.get(6)?,
            joined: r.get(7)?,
            last_read_ts: r.get(8)?,
            left: r.get::<_, i64>(9)? != 0,
        })
    }

    // ---- messages --------------------------------------------------------

    /// Insert a verified message; returns true if newly stored.
    pub fn insert_message(&self, gid: &Sha1Hash, sm: &SignedMessage, state: i64) -> Result<bool> {
        let m = &sm.msg;
        let (chunk_cid, chunk_idx, chunk_total) = match &m.payload {
            Payload::Chunk { chunk, .. } => (
                Some(hex::decode(&chunk.cid).unwrap_or_default()),
                Some(chunk.index),
                Some(chunk.total),
            ),
            _ => (None, None, None),
        };
        let pk = hex::decode(&m.author_pk).unwrap_or_default();
        let n = self.conn.execute(
            "INSERT OR IGNORE INTO messages(id,group_id,author_pk,author_name,ts,seq,kind,body,parents,state,chunk_cid,chunk_idx,chunk_total)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)",
            params![
                sm.id.to_vec(),
                gid.to_vec(),
                pk,
                m.author_name,
                m.ts,
                m.author_seq,
                m.kind,
                sm.bytes,
                m.parents.join(","),
                state,
                chunk_cid,
                chunk_idx,
                chunk_total
            ],
        )?;
        Ok(n > 0)
    }

    /// Which group a stored message belongs to (used to route put
    /// confirmations without in-memory state).
    pub fn message_group(&self, id: &Sha1Hash) -> Result<Option<Sha1Hash>> {
        Ok(self
            .conn
            .query_row(
                "SELECT group_id FROM messages WHERE id=?1",
                params![id.to_vec()],
                |r| r.get::<_, Vec<u8>>(0),
            )
            .optional()?
            .and_then(|b| hash_from_blob(&b).ok()))
    }

    pub fn message_state_set(&self, id: &Sha1Hash, state: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE messages SET state=?2 WHERE id=?1",
            params![id.to_vec(), state],
        )?;
        Ok(())
    }

    pub fn message_get_raw(&self, id: &Sha1Hash) -> Result<Option<Vec<u8>>> {
        Ok(self
            .conn
            .query_row(
                "SELECT body FROM messages WHERE id=?1",
                params![id.to_vec()],
                |r| r.get(0),
            )
            .optional()?)
    }

    /// All messages of a group (parsed, without re-verifying signatures —
    /// they were verified at ingest; the local store is trusted).
    pub fn messages_of_group(
        &self,
        gid: &Sha1Hash,
        own_pk_hex: &str,
    ) -> Result<Vec<SignedMessage>> {
        let mut st = self
            .conn
            .prepare("SELECT body, state FROM messages WHERE group_id=?1")?;
        let rows = st.query_map(params![gid.to_vec()], |r| {
            Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, i64>(1)?))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (body, state) = row?;
            match crate::chat::message::parse_message_unverified(&body, own_pk_hex) {
                Ok(mut sm) => {
                    sm.msg.state = state;
                    out.push(sm);
                }
                Err(e) => {
                    log::warn!("dropping locally stored invalid message: {e}");
                }
            }
        }
        Ok(out)
    }

    /// Flatten display messages: reassembles chunk groups into single logical
    /// messages; returns in causal order as provided.
    pub fn display_messages(ordered: Vec<ChatMessage>) -> Vec<ChatMessage> {
        use std::collections::BTreeMap;
        let mut chunks: BTreeMap<String, BTreeMap<i64, ChatMessage>> = BTreeMap::new();
        let mut out: Vec<ChatMessage> = Vec::new();
        for m in ordered {
            match &m.payload {
                Payload::Chunk { chunk, .. } => {
                    chunks
                        .entry(chunk.cid.clone())
                        .or_default()
                        .insert(chunk.index, m);
                }
                _ => out.push(m),
            }
        }
        // reassemble complete chunk groups at the position of their first part
        for (_cid, parts) in chunks {
            let total = parts
                .values()
                .next()
                .map(|m| match &m.payload {
                    Payload::Chunk { chunk, .. } => chunk.total,
                    _ => 0,
                })
                .unwrap_or(0);
            let have_all = parts.len() as i64 == total && total > 0;
            if have_all {
                let mut text = Vec::new();
                for i in 1..=total {
                    if let Some(m) = parts.get(&i) {
                        if let Payload::Chunk { data, .. } = &m.payload {
                            text.extend_from_slice(data);
                        }
                    }
                }
                let first = parts.get(&1).cloned();
                if let Some(mut f) = first {
                    f.payload = Payload::Text {
                        text: String::from_utf8_lossy(&text).to_string(),
                    };
                    f.kind = MsgKind::Text as i64;
                    // id/parents/ts remain those of the first part
                    out.push(f);
                }
            } else {
                // incomplete: show placeholder parts individually
                for (_i, m) in parts {
                    out.push(m);
                }
            }
        }
        out.sort_by_key(|m| (m.ts, m.author_seq, m.id.clone()));
        out
    }

    pub fn unread_count(&self, gid: &Sha1Hash, last_read_ts: i64, own_pk_hex: &str) -> Result<i64> {
        let pk = hex::decode(own_pk_hex).unwrap_or_default();
        Ok(self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM messages WHERE group_id=?1 AND ts>?2 AND author_pk<>?3 AND kind IN (1,2,5)",
                params![gid.to_vec(), last_read_ts, pk],
                |r| r.get(0),
            )
            .unwrap_or(0))
    }

    pub fn last_message_ts(&self, gid: &Sha1Hash) -> Result<i64> {
        Ok(self
            .conn
            .query_row(
                "SELECT COALESCE(MAX(ts),0) FROM messages WHERE group_id=?1",
                params![gid.to_vec()],
                |r| r.get(0),
            )
            .unwrap_or(0))
    }

    // ---- heads & missing -------------------------------------------------

    pub fn heads_replace(&self, gid: &Sha1Hash, heads: &[Sha1Hash]) -> Result<()> {
        self.conn
            .execute("DELETE FROM heads WHERE group_id=?1", params![gid.to_vec()])?;
        for h in heads {
            self.conn.execute(
                "INSERT OR IGNORE INTO heads(group_id,id) VALUES(?1,?2)",
                params![gid.to_vec(), h.to_vec()],
            )?;
        }
        Ok(())
    }

    pub fn heads_get(&self, gid: &Sha1Hash) -> Result<Vec<Sha1Hash>> {
        let mut st = self
            .conn
            .prepare("SELECT id FROM heads WHERE group_id=?1")?;
        let rows = st.query_map(params![gid.to_vec()], |r| r.get::<_, Vec<u8>>(0))?;
        let mut out = Vec::new();
        for row in rows {
            out.push(hash_from_blob(&row?)?);
        }
        Ok(out)
    }

    pub fn missing_replace(&self, gid: &Sha1Hash, ids: &[Sha1Hash]) -> Result<()> {
        self.conn.execute(
            "DELETE FROM missing WHERE group_id=?1",
            params![gid.to_vec()],
        )?;
        for h in ids {
            self.conn.execute(
                "INSERT OR IGNORE INTO missing(group_id,id) VALUES(?1,?2)",
                params![gid.to_vec(), h.to_vec()],
            )?;
        }
        Ok(())
    }

    pub fn missing_get(&self, gid: &Sha1Hash) -> Result<Vec<Sha1Hash>> {
        let mut st = self
            .conn
            .prepare("SELECT id FROM missing WHERE group_id=?1")?;
        let rows = st.query_map(params![gid.to_vec()], |r| r.get::<_, Vec<u8>>(0))?;
        let mut out = Vec::new();
        for row in rows {
            out.push(hash_from_blob(&row?)?);
        }
        Ok(out)
    }

    // ---- outbox ----------------------------------------------------------

    pub fn outbox_add(&self, gid: &Sha1Hash, msg_id: &Sha1Hash) -> Result<()> {
        self.conn.execute(
            "INSERT INTO outbox(group_id,msg_id,attempts,next_try) VALUES(?1,?2,0,0)",
            params![gid.to_vec(), msg_id.to_vec()],
        )?;
        Ok(())
    }

    #[allow(clippy::type_complexity)]
    pub fn outbox_list(&self) -> Result<Vec<(i64, Sha1Hash, Sha1Hash, i64, i64)>> {
        let mut st = self
            .conn
            .prepare("SELECT id,group_id,msg_id,attempts,next_try FROM outbox ORDER BY id ASC")?;
        let rows = st.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, Vec<u8>>(1)?,
                r.get::<_, Vec<u8>>(2)?,
                r.get::<_, i64>(3)?,
                r.get::<_, i64>(4)?,
            ))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (id, g, m, att, nt) = row?;
            out.push((id, hash_from_blob(&g)?, hash_from_blob(&m)?, att, nt));
        }
        Ok(out)
    }

    pub fn outbox_bump(&self, row_id: i64, next_try: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE outbox SET attempts=attempts+1, next_try=?2 WHERE id=?1",
            params![row_id, next_try],
        )?;
        Ok(())
    }

    pub fn outbox_remove(&self, row_id: i64) -> Result<()> {
        self.conn
            .execute("DELETE FROM outbox WHERE id=?1", params![row_id])?;
        Ok(())
    }

    pub fn outbox_remove_msg(&self, msg_id: &Sha1Hash) -> Result<()> {
        self.conn.execute(
            "DELETE FROM outbox WHERE msg_id=?1",
            params![msg_id.to_vec()],
        )?;
        Ok(())
    }

    // ---- torrents --------------------------------------------------------

    pub fn torrent_upsert(&self, t: &TorrentRow) -> Result<()> {
        self.conn.execute(
            "INSERT INTO torrents(infohash,name,magnet,save_path,kind,group_id,added)
             VALUES(?1,?2,?3,?4,?5,?6,?7)
             ON CONFLICT(infohash) DO UPDATE SET name=?2",
            params![
                t.infohash,
                t.name,
                t.magnet,
                t.save_path,
                t.kind,
                t.group_id.map(|g| g.to_vec()),
                t.added
            ],
        )?;
        Ok(())
    }

    pub fn torrent_remove(&self, infohash: &str) -> Result<()> {
        self.conn
            .execute("DELETE FROM torrents WHERE infohash=?1", params![infohash])?;
        Ok(())
    }

    pub fn torrents_all(&self) -> Result<Vec<TorrentRow>> {
        let mut st = self.conn.prepare(
            "SELECT infohash,name,magnet,save_path,kind,group_id,added FROM torrents ORDER BY added ASC",
        )?;
        let rows = st.query_map([], |r| {
            let gb: Option<Vec<u8>> = r.get(5)?;
            Ok(TorrentRow {
                infohash: r.get(0)?,
                name: r.get(1)?,
                magnet: r.get(2)?,
                save_path: r.get(3)?,
                kind: r.get(4)?,
                group_id: gb.as_deref().and_then(|b| hash_from_blob(b).ok()),
                added: r.get(6)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    // ---- rss -------------------------------------------------------------

    pub fn feed_add(&self, url: &str) -> Result<i64> {
        self.conn.execute(
            "INSERT INTO feeds(url) VALUES(?1) ON CONFLICT(url) DO NOTHING",
            params![url],
        )?;
        Ok(self
            .conn
            .query_row("SELECT id FROM feeds WHERE url=?1", params![url], |r| {
                r.get(0)
            })
            .optional()?
            .unwrap_or(0))
    }

    pub fn feed_remove(&self, feed_id: i64) -> Result<()> {
        self.conn
            .execute("DELETE FROM items WHERE feed_id=?1", params![feed_id])?;
        self.conn
            .execute("DELETE FROM feeds WHERE id=?1", params![feed_id])?;
        Ok(())
    }

    #[allow(clippy::type_complexity)]
    pub fn feeds_all(&self) -> Result<Vec<(i64, String, String, i64, String)>> {
        let mut st = self
            .conn
            .prepare("SELECT id,url,title,last_fetch,error FROM feeds ORDER BY id ASC")?;
        let rows = st.query_map([], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn feed_set_meta(
        &self,
        feed_id: i64,
        title: &str,
        last_fetch: i64,
        error: &str,
    ) -> Result<()> {
        self.conn.execute(
            "UPDATE feeds SET title=?2, last_fetch=?3, error=?4 WHERE id=?1",
            params![feed_id, title, last_fetch, error],
        )?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn item_insert(
        &self,
        feed_id: i64,
        guid: &str,
        title: &str,
        link: &str,
        author: &str,
        content: &str,
        ts: i64,
        magnet: &str,
        enclosure_url: &str,
        enclosure_type: &str,
    ) -> Result<bool> {
        let n = self.conn.execute(
            "INSERT OR IGNORE INTO items(feed_id,guid,title,link,author,content,ts,magnet,enclosure_url,enclosure_type)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
            params![feed_id, guid, title, link, author, content, ts, magnet, enclosure_url, enclosure_type],
        )?;
        Ok(n > 0)
    }

    pub fn items_of_feed(
        &self,
        feed_id: i64,
        limit: i64,
        offset: i64,
        unread_only: bool,
    ) -> Result<Vec<RssItemRow>> {
        let sql = if unread_only {
            "SELECT id,feed_id,guid,title,link,author,content,ts,read_flag,magnet,enclosure_url,enclosure_type
             FROM items WHERE feed_id=?1 AND read_flag=0 ORDER BY ts DESC, id DESC LIMIT ?2 OFFSET ?3"
        } else {
            "SELECT id,feed_id,guid,title,link,author,content,ts,read_flag,magnet,enclosure_url,enclosure_type
             FROM items WHERE feed_id=?1 ORDER BY ts DESC, id DESC LIMIT ?2 OFFSET ?3"
        };
        let mut st = self.conn.prepare(sql)?;
        let rows = st.query_map(params![feed_id, limit, offset], |r| {
            Ok(RssItemRow {
                id: r.get(0)?,
                feed_id: r.get(1)?,
                guid: r.get(2)?,
                title: r.get(3)?,
                link: r.get(4)?,
                author: r.get(5)?,
                content: r.get(6)?,
                ts: r.get(7)?,
                read: r.get::<_, i64>(8)? != 0,
                magnet: r.get(9)?,
                enclosure_url: r.get(10)?,
                enclosure_type: r.get(11)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn item_set_read(&self, item_id: i64, read: bool) -> Result<()> {
        self.conn.execute(
            "UPDATE items SET read_flag=?2 WHERE id=?1",
            params![item_id, read as i64],
        )?;
        Ok(())
    }

    pub fn feed_set_all_read(&self, feed_id: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE items SET read_flag=1 WHERE feed_id=?1",
            params![feed_id],
        )?;
        Ok(())
    }

    pub fn feed_unread_count(&self, feed_id: i64) -> Result<i64> {
        Ok(self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM items WHERE feed_id=?1 AND read_flag=0",
                params![feed_id],
                |r| r.get(0),
            )
            .unwrap_or(0))
    }

    pub fn item_get(&self, item_id: i64) -> Result<Option<RssItemRow>> {
        let mut st = self.conn.prepare(
            "SELECT id,feed_id,guid,title,link,author,content,ts,read_flag,magnet,enclosure_url,enclosure_type
             FROM items WHERE id=?1",
        )?;
        let mut rows = st.query_map(params![item_id], |r| {
            Ok(RssItemRow {
                id: r.get(0)?,
                feed_id: r.get(1)?,
                guid: r.get(2)?,
                title: r.get(3)?,
                link: r.get(4)?,
                author: r.get(5)?,
                content: r.get(6)?,
                ts: r.get(7)?,
                read: r.get::<_, i64>(8)? != 0,
                magnet: r.get(9)?,
                enclosure_url: r.get(10)?,
                enclosure_type: r.get(11)?,
            })
        })?;
        match rows.next() {
            Some(r) => Ok(Some(r?)),
            None => Ok(None),
        }
    }
}

#[derive(Debug, Clone)]
pub struct RssItemRow {
    pub id: i64,
    pub feed_id: i64,
    pub guid: String,
    pub title: String,
    pub link: String,
    pub author: String,
    pub content: String,
    pub ts: i64,
    pub read: bool,
    pub magnet: String,
    pub enclosure_url: String,
    pub enclosure_type: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chat::message::{create_message, MsgKind, Payload};
    use crate::crypto::Identity;

    #[test]
    fn kv_roundtrip() {
        let s = Store::open_in_memory().unwrap();
        assert!(s.kv_get("x").unwrap().is_none());
        s.kv_set("x", b"1").unwrap();
        assert_eq!(s.kv_get("x").unwrap().unwrap(), b"1");
        s.kv_set("x", b"2").unwrap();
        assert_eq!(s.kv_get("x").unwrap().unwrap(), b"2");
    }

    #[test]
    fn message_insert_and_query() {
        let s = Store::open_in_memory().unwrap();
        let gid = [3u8; 20];
        let id = Identity::generate();
        let now = crate::now_ms();
        let sm = create_message(
            &gid,
            &[],
            1,
            now,
            &id,
            "alice",
            MsgKind::Text,
            &Payload::Text { text: "hi".into() },
        )
        .unwrap();
        assert!(s.insert_message(&gid, &sm, 1).unwrap());
        assert!(!s.insert_message(&gid, &sm, 1).unwrap()); // dup
        let msgs = s
            .messages_of_group(&gid, &hex::encode(id.public_key()))
            .unwrap();
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].id, sm.id);
        assert!(msgs[0].msg.own);
        assert_eq!(s.last_message_ts(&gid).unwrap(), now);
    }

    #[test]
    fn heads_and_missing() {
        let s = Store::open_in_memory().unwrap();
        let gid = [4u8; 20];
        let h1 = [1u8; 20];
        let h2 = [2u8; 20];
        s.heads_replace(&gid, &[h1, h2]).unwrap();
        assert_eq!(s.heads_get(&gid).unwrap(), vec![h1, h2]);
        s.heads_replace(&gid, &[h2]).unwrap();
        assert_eq!(s.heads_get(&gid).unwrap(), vec![h2]);
        s.missing_replace(&gid, &[h1]).unwrap();
        assert_eq!(s.missing_get(&gid).unwrap(), vec![h1]);
    }

    #[test]
    fn display_messages_reassembles_chunks() {
        let a = Identity::generate();
        let gid = [5u8; 20];
        let now = crate::now_ms();
        let mut msgs = Vec::new();
        // one plain text
        let sm = create_message(
            &gid,
            &[],
            1,
            now,
            &a,
            "alice",
            MsgKind::Text,
            &Payload::Text {
                text: "plain".into(),
            },
        )
        .unwrap();
        msgs.push(sm.msg.clone());
        // a 3-part chunk group
        let cid = "aabbccddeeff0011".to_string();
        for i in 1..=3 {
            let sm = create_message(
                &gid,
                &[],
                1 + i,
                now + i,
                &a,
                "alice",
                MsgKind::Chunk,
                &Payload::Chunk {
                    chunk: crate::chat::message::ChunkInfo {
                        cid: cid.clone(),
                        index: i,
                        total: 3,
                    },
                    data: format!("part{i}").into_bytes(),
                },
            )
            .unwrap();
            msgs.push(sm.msg.clone());
        }
        let display = Store::display_messages(msgs);
        assert_eq!(display.len(), 2);
        let chunk_msg = display
            .iter()
            .find(|m| matches!(m.payload, Payload::Text { .. }) && m.ts == now + 1)
            .unwrap();
        match &chunk_msg.payload {
            Payload::Text { text } => assert_eq!(text, "part1part2part3"),
            _ => unreachable!(),
        }
    }
}
