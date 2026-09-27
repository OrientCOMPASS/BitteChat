//! RSS/Atom fetching and parsing.

use quick_xml::events::Event;
use serde::{Deserialize, Serialize};

use crate::{CoreError, Result};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParsedItem {
    pub guid: String,
    pub title: String,
    pub link: String,
    pub author: String,
    /// plain-text content (HTML stripped)
    pub content: String,
    pub ts: i64,
    pub magnet: String,
    pub enclosure_url: String,
    pub enclosure_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParsedFeed {
    pub title: String,
    pub items: Vec<ParsedItem>,
}

const MAX_BODY: usize = 8 * 1024 * 1024;
const FETCH_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20);

pub fn fetch_url(url: &str) -> Result<Vec<u8>> {
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err(CoreError::Invalid("only http(s) urls supported".into()));
    }
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(FETCH_TIMEOUT)
        .timeout(FETCH_TIMEOUT)
        .user_agent(concat!("BitteChat/", env!("CARGO_PKG_VERSION")))
        .build();
    let resp = agent
        .get(url)
        .call()
        .map_err(|e| CoreError::Engine(format!("fetch failed: {e}")))?;
    let mut body = Vec::new();
    let mut reader = resp.into_reader();
    {
        use std::io::Read;
        let mut limited = reader.by_ref().take(MAX_BODY as u64);
        limited
            .read_to_end(&mut body)
            .map_err(|e| CoreError::Engine(format!("read failed: {e}")))?;
    }
    Ok(body)
}

pub fn parse_feed(bytes: &[u8]) -> Result<ParsedFeed> {
    let text = String::from_utf8_lossy(bytes);
    let trimmed = text.trim_start();
    if trimmed.starts_with("<rss") || trimmed.contains("<rss") {
        parse_rss2(&text)
    } else if trimmed.contains("<feed") {
        parse_atom(&text)
    } else {
        Err(CoreError::Invalid("not an RSS/Atom feed".into()))
    }
}

struct ItemBuilder {
    guid: String,
    title: String,
    link: String,
    author: String,
    content: String,
    date: String,
    magnet: String,
    enclosure_url: String,
    enclosure_type: String,
}

impl ItemBuilder {
    fn new() -> ItemBuilder {
        ItemBuilder {
            guid: String::new(),
            title: String::new(),
            link: String::new(),
            author: String::new(),
            content: String::new(),
            date: String::new(),
            magnet: String::new(),
            enclosure_url: String::new(),
            enclosure_type: String::new(),
        }
    }

    fn finish(self, idx: usize) -> ParsedItem {
        let mut guid = self.guid;
        if guid.is_empty() {
            guid = if !self.link.is_empty() {
                self.link.clone()
            } else {
                format!("{}|{}", self.title, idx)
            };
        }
        // magnet link discovery from content/link
        let mut magnet = self.magnet;
        if magnet.is_empty() {
            if let Some(m) = extract_magnet(&self.content) {
                magnet = m;
            } else if self.link.starts_with("magnet:") {
                magnet = self.link.clone();
            }
        }
        ParsedItem {
            guid,
            title: self.title,
            link: self.link,
            author: self.author,
            content: self.content,
            ts: parse_date(&self.date),
            magnet,
            enclosure_url: self.enclosure_url,
            enclosure_type: self.enclosure_type,
        }
    }
}

fn parse_rss2(text: &str) -> Result<ParsedFeed> {
    let mut reader = quick_xml::Reader::from_str(text);
    reader.config_mut().trim_text(true);
    let mut feed_title = String::new();
    let mut items: Vec<ParsedItem> = Vec::new();
    let mut in_channel = false;
    let mut cur: Option<ItemBuilder> = None;
    let mut buf = Vec::new();
    let mut tag_stack: Vec<String> = Vec::new();

    loop {
        let ev = reader.read_event_into(&mut buf);
        match ev {
            Ok(Event::Empty(e)) => {
                // self-closing: handle attributes, do NOT touch the stack
                let name = String::from_utf8_lossy(e.name().as_ref()).to_lowercase();
                if name == "enclosure" {
                    if let Some(c) = cur.as_mut() {
                        let (url, ty) = enclosure_attrs(&e);
                        if url.starts_with("magnet:") {
                            c.magnet = url.clone();
                        }
                        c.enclosure_url = url;
                        c.enclosure_type = ty;
                    }
                }
            }
            Ok(Event::Start(e)) => {
                let name = String::from_utf8_lossy(e.name().as_ref()).to_lowercase();
                match name.as_str() {
                    "channel" => in_channel = true,
                    "item" => cur = Some(ItemBuilder::new()),
                    "enclosure" => {
                        if let Some(c) = cur.as_mut() {
                            let (url, ty) = enclosure_attrs(&e);
                            if url.starts_with("magnet:") {
                                c.magnet = url.clone();
                            }
                            c.enclosure_url = url;
                            c.enclosure_type = ty;
                        }
                    }
                    _ => {}
                }
                tag_stack.push(name);
            }
            Ok(Event::End(e)) => {
                let name = String::from_utf8_lossy(e.name().as_ref()).to_lowercase();
                tag_stack.pop();
                if name == "item" {
                    if let Some(c) = cur.take() {
                        items.push(c.finish(items.len()));
                    }
                }
            }
            Ok(Event::Text(t)) => {
                let raw = t.unescape().unwrap_or_default().to_string();
                let tag = tag_stack.last().map(|s| s.as_str()).unwrap_or("");
                apply_text(cur.as_mut(), in_channel, tag, &raw, &mut feed_title);
            }
            Ok(Event::CData(t)) => {
                let raw = String::from_utf8_lossy(&t.into_inner()).to_string();
                let tag = tag_stack.last().map(|s| s.as_str()).unwrap_or("");
                apply_text(cur.as_mut(), in_channel, tag, &raw, &mut feed_title);
            }
            Ok(Event::Eof) => break,
            Err(_) => break,
            _ => {}
        }
        buf.clear();
    }
    for it in items.iter_mut() {
        it.content = html_to_text(&it.content);
        it.title = html_to_text(&it.title);
    }
    Ok(ParsedFeed {
        title: html_to_text(&feed_title),
        items,
    })
}

fn enclosure_attrs(e: &quick_xml::events::BytesStart) -> (String, String) {
    let mut url = String::new();
    let mut ty = String::new();
    for attr in e.attributes().flatten() {
        let k = String::from_utf8_lossy(attr.key.as_ref()).to_lowercase();
        let v = String::from_utf8_lossy(&attr.value).to_string();
        match k.as_str() {
            "url" => url = v,
            "type" => ty = v,
            _ => {}
        }
    }
    (url, ty)
}

fn apply_text(
    cur: Option<&mut ItemBuilder>,
    in_channel: bool,
    tag: &str,
    raw: &str,
    feed_title: &mut String,
) {
    if let Some(c) = cur {
        match tag {
            "title" => c.title.push_str(raw),
            "link" => c.link.push_str(raw),
            "description" | "content:encoded" => c.content.push_str(raw),
            "author" | "dc:creator" => c.author.push_str(raw),
            "pubdate" | "dc:date" => c.date.push_str(raw),
            "guid" => c.guid.push_str(raw),
            _ => {}
        }
    } else if in_channel && tag == "title" && feed_title.is_empty() {
        feed_title.push_str(raw);
    }
}

fn parse_atom(text: &str) -> Result<ParsedFeed> {
    let mut reader = quick_xml::Reader::from_str(text);
    reader.config_mut().trim_text(true);
    let mut feed_title = String::new();
    let mut items: Vec<ParsedItem> = Vec::new();
    let mut cur: Option<ItemBuilder> = None;
    let mut tag_stack: Vec<String> = Vec::new();
    let mut buf = Vec::new();

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Empty(e)) => {
                // self-closing (typical for <link href=.../>) — no stack push
                let name = String::from_utf8_lossy(e.name().as_ref()).to_lowercase();
                if name == "link" {
                    apply_atom_link(cur.as_mut(), &e);
                }
            }
            Ok(Event::Start(e)) => {
                let name = String::from_utf8_lossy(e.name().as_ref()).to_lowercase();
                match name.as_str() {
                    "entry" => cur = Some(ItemBuilder::new()),
                    "link" => apply_atom_link(cur.as_mut(), &e),
                    _ => {}
                }
                tag_stack.push(name);
            }
            Ok(Event::End(e)) => {
                let name = String::from_utf8_lossy(e.name().as_ref()).to_lowercase();
                tag_stack.pop();
                if name == "entry" {
                    if let Some(c) = cur.take() {
                        items.push(c.finish(items.len()));
                    }
                }
            }
            Ok(Event::Text(t)) => {
                let raw = t.unescape().unwrap_or_default().to_string();
                let tag = tag_stack.last().map(|s| s.as_str()).unwrap_or("");
                if let Some(c) = cur.as_mut() {
                    match tag {
                        "title" => c.title.push_str(&raw),
                        "summary" | "content" => c.content.push_str(&raw),
                        "updated" | "published" => {
                            if c.date.is_empty() {
                                c.date.push_str(&raw)
                            }
                        }
                        "name" if tag_stack.iter().any(|x| x == "author") => {
                            c.author.push_str(&raw)
                        }
                        "id" => c.guid.push_str(&raw),
                        _ => {}
                    }
                } else if tag == "title" && feed_title.is_empty() {
                    feed_title.push_str(&raw);
                }
            }
            Ok(Event::CData(t)) => {
                let raw = String::from_utf8_lossy(&t.into_inner()).to_string();
                let tag = tag_stack.last().map(|s| s.as_str()).unwrap_or("");
                if let Some(c) = cur.as_mut() {
                    match tag {
                        "title" => c.title.push_str(&raw),
                        "summary" | "content" => c.content.push_str(&raw),
                        _ => {}
                    }
                } else if tag == "title" && feed_title.is_empty() {
                    feed_title.push_str(&raw);
                }
            }
            Ok(Event::Eof) => break,
            Err(_) => break,
            _ => {}
        }
        buf.clear();
    }
    for it in items.iter_mut() {
        it.content = html_to_text(&it.content);
        it.title = html_to_text(&it.title);
    }
    Ok(ParsedFeed {
        title: html_to_text(&feed_title),
        items,
    })
}

fn apply_atom_link(cur: Option<&mut ItemBuilder>, e: &quick_xml::events::BytesStart) {
    let mut href = String::new();
    let mut rel = String::new();
    let mut ty = String::new();
    for attr in e.attributes().flatten() {
        let k = String::from_utf8_lossy(attr.key.as_ref()).to_lowercase();
        let v = String::from_utf8_lossy(&attr.value).to_string();
        match k.as_str() {
            "href" => href = v,
            "rel" => rel = v,
            "type" => ty = v,
            _ => {}
        }
    }
    let href = html_unescape(&href);
    if let Some(c) = cur {
        if href.starts_with("magnet:") {
            c.magnet = href.clone();
            c.enclosure_url = href;
            c.enclosure_type = ty;
        } else if (rel.is_empty() || rel == "alternate") && c.link.is_empty() {
            c.link = href;
        } else if rel == "enclosure" {
            c.enclosure_url = href;
            c.enclosure_type = ty;
        }
    }
}

/// Extract the first magnet link from text.
pub fn extract_magnet(text: &str) -> Option<String> {
    let start = text.find("magnet:?")?;
    let rest = &text[start..];
    // magnet links end at whitespace, quote, or angle bracket
    let end = rest
        .find(|c: char| c.is_whitespace() || c == '"' || c == '\'' || c == '<' || c == '>')
        .unwrap_or(rest.len());
    let m = &rest[..end];
    if m.contains("xt=urn:btih:") {
        Some(html_unescape(m))
    } else {
        None
    }
}

const BLOCK_TAGS: [&str; 14] = [
    "br", "p", "div", "li", "ul", "ol", "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6",
];

pub fn html_to_text(html: &str) -> String {
    let unescaped = html_unescape(html);
    let mut out = String::with_capacity(unescaped.len());
    let mut in_tag = false;
    let mut tag_buf = String::new();
    let bytes: Vec<char> = unescaped.chars().collect();
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        match c {
            '<' => {
                in_tag = true;
                tag_buf.clear();
                // collect tag name for block-level detection
                let mut j = i + 1;
                if j < bytes.len() && bytes[j] == '/' {
                    j += 1;
                }
                while j < bytes.len() && bytes[j].is_ascii_alphabetic() {
                    tag_buf.push(bytes[j].to_ascii_lowercase());
                    j += 1;
                }
                if BLOCK_TAGS.contains(&tag_buf.as_str()) {
                    out.push(' ');
                }
            }
            '>' => in_tag = false,
            '\n' | '\r' | '\t' if !in_tag => out.push(' '),
            c if !in_tag => out.push(c),
            _ => {}
        }
        i += 1;
    }
    // collapse whitespace runs
    let mut res = String::with_capacity(out.len());
    let mut last_space = false;
    for c in out.chars() {
        if c == ' ' {
            if !last_space {
                res.push(' ');
            }
            last_space = true;
        } else {
            res.push(c);
            last_space = false;
        }
    }
    res.trim().to_string()
}

fn html_unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&nbsp;", " ")
}

/// Parse RFC822 / RFC3339 / ISO-like dates into unix millis; 0 on failure.
pub fn parse_date(s: &str) -> i64 {
    let s = s.trim();
    if s.is_empty() {
        return 0;
    }
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(s) {
        return dt.timestamp_millis();
    }
    if let Ok(dt) = chrono::DateTime::parse_from_rfc2822(s) {
        return dt.timestamp_millis();
    }
    // feeds frequently carry a WRONG weekday name; chrono validates weekday
    // consistency and rejects those, so strip the weekday and retry
    let stripped;
    let s = {
        let bytes = s.as_bytes();
        if bytes.len() > 5 && bytes[..3].iter().all(|c| c.is_ascii_alphabetic()) && bytes[3] == b','
        {
            stripped = s[4..].trim_start().to_string();
            stripped.as_str()
        } else {
            s
        }
    };
    if let Ok(dt) = chrono::DateTime::parse_from_rfc2822(s) {
        return dt.timestamp_millis();
    }
    // RFC822 with named zone (chrono's rfc2822 parser is strict about offsets)
    for fmt in [
        "%a, %d %b %Y %H:%M:%S %Z",
        "%a, %d %b %Y %H:%M %Z",
        "%d %b %Y %H:%M:%S %Z",
    ] {
        if let Ok(nd) = chrono::NaiveDateTime::parse_from_str(s, fmt) {
            return nd.and_utc().timestamp_millis();
        }
    }
    if let Ok(dt) = chrono::DateTime::parse_from_str(s, "%a, %d %b %Y %H:%M:%S %z") {
        return dt.timestamp_millis();
    }
    // common fallback: "2026-09-27 12:00:00"
    if let Ok(nd) = chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S") {
        return nd.and_utc().timestamp_millis();
    }
    if let Ok(nd) = chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d") {
        return nd
            .and_hms_opt(0, 0, 0)
            .map(|d| d.and_utc().timestamp_millis())
            .unwrap_or(0);
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    const RSS: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
<channel>
  <title>测试订阅源</title>
  <link>https://example.com</link>
  <item>
    <title>Hello &amp; welcome</title>
    <link>https://example.com/1</link>
    <description><![CDATA[<p>Some <b>HTML</b> content</p>]]></description>
    <pubDate>Sat, 27 Sep 2026 08:00:00 GMT</pubDate>
    <guid>guid-1</guid>
    <dc:creator>alice</dc:creator>
    <enclosure url="magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&amp;dn=ubuntu" type="application/x-bittorrent" length="123"/>
  </item>
  <item>
    <title>Plain</title>
    <link>https://example.com/2</link>
    <description>text with magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa inside</description>
    <pubDate>2026-09-26T07:00:00Z</pubDate>
  </item>
</channel>
</rss>"#;

    const ATOM: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom 源</title>
  <entry>
    <id>urn:uuid:1</id>
    <title>Entry one</title>
    <link href="https://example.com/e1"/>
    <updated>2026-09-27T10:00:00Z</updated>
    <author><name>bob</name></author>
    <summary>Summary &lt;b&gt;text&lt;/b&gt;</summary>
  </entry>
</feed>"#;

    #[test]
    fn parse_rss2_full() {
        let f = parse_feed(RSS.as_bytes()).unwrap();
        assert_eq!(f.title, "测试订阅源");
        assert_eq!(f.items.len(), 2);
        let i0 = &f.items[0];
        assert_eq!(i0.title, "Hello & welcome");
        assert_eq!(i0.guid, "guid-1");
        assert_eq!(i0.author, "alice");
        assert_eq!(i0.content, "Some HTML content");
        assert!(i0.ts > 0);
        assert!(i0.magnet.starts_with("magnet:?xt=urn:btih:0123"));
        assert!(i0.magnet.contains("dn=ubuntu"));
        assert_eq!(i0.enclosure_type, "application/x-bittorrent");
        let i1 = &f.items[1];
        assert!(i1.magnet.contains("aaaaaaaa"));
        assert_eq!(i1.guid, "https://example.com/2"); // fallback to link
    }

    #[test]
    fn parse_atom_full() {
        let f = parse_feed(ATOM.as_bytes()).unwrap();
        assert_eq!(f.title, "Atom 源");
        assert_eq!(f.items.len(), 1);
        let e = &f.items[0];
        assert_eq!(e.title, "Entry one");
        assert_eq!(e.link, "https://example.com/e1");
        assert_eq!(e.author, "bob");
        assert_eq!(e.guid, "urn:uuid:1");
        assert_eq!(e.content, "Summary text");
        assert!(e.ts > 0);
    }

    #[test]
    fn html_strip_and_unescape() {
        assert_eq!(html_to_text("<p>a &amp; b<br/>c</p>"), "a & b c");
        assert!(
            extract_magnet(
                "see magnet:?xt=urn:btih:0123456789ABCDEF0123456789ABCDEF01234567&dn=x now"
            )
            .unwrap()
            .len()
                > 30
        );
        assert!(extract_magnet("no link here").is_none());
    }

    #[test]
    fn dates() {
        assert!(parse_date("Sat, 27 Sep 2026 08:00:00 GMT") > 0);
        assert!(parse_date("2026-09-26T07:00:00Z") > 0);
        assert!(parse_date("2026-09-26 07:00:00") > 0);
        assert_eq!(parse_date("garbage"), 0);
    }

    #[test]
    fn rejects_non_feeds() {
        assert!(parse_feed(b"<html><body>hi</body></html>").is_err());
    }
}
