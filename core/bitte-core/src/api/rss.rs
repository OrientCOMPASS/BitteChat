//! rss.* JSON methods — feed management, refresh workers and the RSS→BT
//! pipeline (magnet / .torrent / direct-file enclosures become downloads).

use std::sync::Arc;

use serde_json::{json, Value as Json};

use crate::api::{ji64, jstr, Api, Inner};
use crate::{CoreError, Result};

impl Api {
    pub fn rss_feeds(&self) -> Result<Json> {
        let st = self.inner.state.lock().unwrap();
        let mut out = Vec::new();
        for (id, url, title, last_fetch, error) in st.store.feeds_all()? {
            let unread = st.store.feed_unread_count(id).unwrap_or(0);
            out.push(json!({
                "id": id,
                "url": url,
                "title": title,
                "last_fetch": last_fetch,
                "error": error,
                "unread": unread,
            }));
        }
        Ok(json!({"feeds": out}))
    }

    pub fn rss_add(&self, p: Json) -> Result<Json> {
        let url = jstr(&p, "url")?.trim().to_string();
        if !(url.starts_with("http://") || url.starts_with("https://")) {
            return Err(CoreError::Invalid("URL 必须以 http(s):// 开头".into()));
        }
        let id = {
            let st = self.inner.state.lock().unwrap();
            st.store.feed_add(&url)?
        };
        // refresh immediately in background
        self.spawn_feed_refresh(id, url.clone());
        Ok(json!({"id": id, "url": url}))
    }

    pub fn rss_remove(&self, p: Json) -> Result<Json> {
        let id = ji64(&p, "id", 0);
        if id <= 0 {
            return Err(CoreError::Invalid("missing id".into()));
        }
        let st = self.inner.state.lock().unwrap();
        st.store.feed_remove(id)?;
        Ok(json!({"ok": true}))
    }

    pub fn rss_refresh(&self, p: Json) -> Result<Json> {
        let id = ji64(&p, "id", 0);
        let st = self.inner.state.lock().unwrap();
        let feeds = st.store.feeds_all()?;
        drop(st);
        if id > 0 {
            let Some((_, url, _, _, _)) = feeds.into_iter().find(|(fid, _, _, _, _)| *fid == id)
            else {
                return Err(CoreError::NotFound("feed".into()));
            };
            self.spawn_feed_refresh(id, url);
        } else {
            for (fid, url, _, _, _) in feeds {
                self.spawn_feed_refresh(fid, url);
            }
        }
        Ok(json!({"ok": true}))
    }

    pub fn rss_items(&self, p: Json) -> Result<Json> {
        let feed_id = ji64(&p, "feed_id", 0);
        let limit = ji64(&p, "limit", 50).clamp(1, 500);
        let offset = ji64(&p, "offset", 0).max(0);
        let unread_only = p
            .get("unread_only")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let st = self.inner.state.lock().unwrap();
        let items = st
            .store
            .items_of_feed(feed_id, limit, offset, unread_only)?;
        let unread = st.store.feed_unread_count(feed_id).unwrap_or(0);
        let out: Vec<Json> = items
            .iter()
            .map(|i| {
                json!({
                    "id": i.id,
                    "feed_id": i.feed_id,
                    "title": i.title,
                    "link": i.link,
                    "author": i.author,
                    "ts": i.ts,
                    "read": i.read,
                    "has_torrent": !i.magnet.is_empty()
                        || i.enclosure_type.contains("torrent")
                        || (!i.enclosure_url.is_empty() && i.enclosure_url.ends_with(".torrent")),
                    "has_download": !i.magnet.is_empty() || !i.enclosure_url.is_empty(),
                    "snippet": truncate_chars(&i.content, 160),
                })
            })
            .collect();
        Ok(json!({"items": out, "unread": unread}))
    }

    pub fn rss_item_detail(&self, p: Json) -> Result<Json> {
        let id = ji64(&p, "id", 0);
        let st = self.inner.state.lock().unwrap();
        let item = st
            .store
            .item_get(id)?
            .ok_or_else(|| CoreError::NotFound("item".into()))?;
        if !item.read {
            st.store.item_set_read(id, true)?;
        }
        Ok(json!({
            "id": item.id,
            "feed_id": item.feed_id,
            "title": item.title,
            "link": item.link,
            "author": item.author,
            "ts": item.ts,
            "content": item.content,
            "read": true,
            "magnet": item.magnet,
            "enclosure_url": item.enclosure_url,
            "enclosure_type": item.enclosure_type,
        }))
    }

    pub fn rss_mark_read(&self, p: Json) -> Result<Json> {
        let id = ji64(&p, "id", 0);
        let read = p.get("read").and_then(|v| v.as_bool()).unwrap_or(true);
        let st = self.inner.state.lock().unwrap();
        st.store.item_set_read(id, read)?;
        Ok(json!({"ok": true}))
    }

    pub fn rss_mark_feed_read(&self, p: Json) -> Result<Json> {
        let feed_id = ji64(&p, "feed_id", 0);
        let st = self.inner.state.lock().unwrap();
        st.store.feed_set_all_read(feed_id)?;
        Ok(json!({"ok": true}))
    }

    /// Turn an RSS item into a BT download: magnet link directly, .torrent
    /// enclosure fetched then imported, or a generic file downloaded over
    /// HTTP and re-seeded as a new torrent.
    pub fn rss_download(&self, p: Json) -> Result<Json> {
        let id = ji64(&p, "id", 0);
        let item = {
            let st = self.inner.state.lock().unwrap();
            st.store
                .item_get(id)?
                .ok_or_else(|| CoreError::NotFound("item".into()))?
        };
        if !item.magnet.is_empty() {
            return self.bt_add(json!({"magnet": item.magnet, "name": item.title}));
        }
        let url = item.enclosure_url.clone();
        if url.is_empty() {
            return Err(CoreError::Invalid("该条目没有可下载的资源".into()));
        }
        let title = item.title.clone();
        let inner = self.inner.clone();
        let url_bg = url.clone();
        std::thread::spawn(move || {
            let inner2 = inner.clone();
            if let Err(e) = download_enclosure(inner, &url_bg, &title) {
                Api::emit_from(
                    &inner2,
                    "rss.error",
                    json!({"item_id": id, "error": e.to_string()}),
                );
            }
        });
        Ok(json!({"started": true, "url": url}))
    }

    pub fn spawn_feed_refresh(&self, feed_id: i64, url: String) {
        let inner = self.inner.clone();
        std::thread::spawn(move || {
            refresh_feed(&inner, feed_id, &url);
        });
    }
}

fn refresh_feed(inner: &Inner, feed_id: i64, url: &str) {
    let now = crate::now_ms();
    let fetched = crate::rss::fetch_url(url).and_then(|bytes| crate::rss::parse_feed(&bytes));
    let mut new_count = 0i64;
    match fetched {
        Ok(feed) => {
            {
                let st = inner.state.lock().unwrap();
                let cur_title = st
                    .store
                    .feeds_all()
                    .ok()
                    .and_then(|fs| fs.into_iter().find(|(id, _, _, _, _)| *id == feed_id))
                    .map(|(_, _, t, _, _)| t)
                    .unwrap_or_default();
                let title = if cur_title.is_empty() {
                    feed.title.clone()
                } else {
                    cur_title
                };
                let _ = st.store.feed_set_meta(feed_id, &title, now, "");
                for it in &feed.items {
                    let inserted = st
                        .store
                        .item_insert(
                            feed_id,
                            &it.guid,
                            &it.title,
                            &it.link,
                            &it.author,
                            &it.content,
                            it.ts,
                            &it.magnet,
                            &it.enclosure_url,
                            &it.enclosure_type,
                        )
                        .unwrap_or(false);
                    if inserted {
                        new_count += 1;
                    }
                }
            }
            Api::emit_from(
                inner,
                "rss.updated",
                json!({"feed_id": feed_id, "new_items": new_count}),
            );
        }
        Err(e) => {
            {
                let st = inner.state.lock().unwrap();
                let cur = st
                    .store
                    .feeds_all()
                    .ok()
                    .and_then(|fs| fs.into_iter().find(|(id, _, _, _, _)| *id == feed_id))
                    .map(|(_, _, t, _, _)| t)
                    .unwrap_or_default();
                let _ = st.store.feed_set_meta(feed_id, &cur, now, &e.to_string());
            }
            Api::emit_from(
                inner,
                "rss.error",
                json!({"feed_id": feed_id, "error": e.to_string()}),
            );
        }
    }
}

pub fn truncate_chars(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        s.to_string()
    } else {
        let t: String = s.chars().take(max_chars).collect();
        format!("{t}…")
    }
}

fn download_enclosure(inner: Arc<Inner>, url: &str, title: &str) -> Result<()> {
    let tmp = inner.data_dir.join("tmp");
    std::fs::create_dir_all(&tmp)?;
    if url.ends_with(".torrent") || url.contains(".torrent?") {
        let bytes = crate::rss::fetch_url(url)?;
        // reuse the bt.add_file pipeline through a temporary Api-less path:
        // parse via engine by adding into a staging dir
        let staging = tmp.join(format!("rss-{}", crate::now_ms()));
        std::fs::create_dir_all(&staging)?;
        let ih = inner
            .engine
            .add_torrent_bytes(&bytes, &staging.to_string_lossy())?;
        let _ = inner.engine.remove_torrent(&ih, false);
        let save_dir = inner.data_dir.join("downloads").join(&ih);
        std::fs::create_dir_all(&save_dir)?;
        if let Ok(entries) = std::fs::read_dir(&staging) {
            for e in entries.flatten() {
                let _ = std::fs::rename(e.path(), save_dir.join(e.file_name()));
            }
        }
        let _ = std::fs::remove_dir_all(&staging);
        inner
            .engine
            .add_torrent_bytes(&bytes, &save_dir.to_string_lossy())?;
        {
            let st = inner.state.lock().unwrap();
            st.store.torrent_upsert(&crate::store::TorrentRow {
                infohash: ih.clone(),
                name: title.to_string(),
                magnet: format!("magnet:?xt=urn:btih:{ih}"),
                save_path: save_dir.to_string_lossy().to_string(),
                kind: 3,
                group_id: None,
                added: crate::now_ms(),
            })?;
        }
        Api::emit_from(&inner, "bt.added", json!({"infohash": ih, "name": title}));
        Ok(())
    } else {
        // generic file: download fully, then create+seed a torrent for it
        let bytes = crate::rss::fetch_url(url)?;
        let file_name = url
            .split('/')
            .next_back()
            .unwrap_or("download.bin")
            .split('?')
            .next()
            .unwrap_or("download.bin")
            .to_string();
        let stage = tmp.join(format!("dl-{}", crate::now_ms()));
        std::fs::create_dir_all(&stage)?;
        let fpath = stage.join(&file_name);
        std::fs::write(&fpath, &bytes)?;
        let created = inner
            .engine
            .create_torrent(&fpath.to_string_lossy(), "BitteChat RSS download")?;
        let ih_hex = hex::encode(created.infohash);
        let save_dir = inner.data_dir.join("downloads").join(&ih_hex);
        std::fs::create_dir_all(&save_dir)?;
        let dest = save_dir.join(&file_name);
        let _ = std::fs::rename(&fpath, &dest);
        let _ = std::fs::remove_dir_all(&stage);
        inner
            .engine
            .add_torrent_bytes(&created.torrent_bytes, &save_dir.to_string_lossy())?;
        {
            let st = inner.state.lock().unwrap();
            st.store.torrent_upsert(&crate::store::TorrentRow {
                infohash: ih_hex.clone(),
                name: file_name.clone(),
                magnet: created.magnet.clone(),
                save_path: save_dir.to_string_lossy().to_string(),
                kind: 3,
                group_id: None,
                added: crate::now_ms(),
            })?;
        }
        Api::emit_from(
            &inner,
            "bt.added",
            json!({"infohash": ih_hex, "name": file_name, "magnet": created.magnet}),
        );
        Ok(())
    }
}
