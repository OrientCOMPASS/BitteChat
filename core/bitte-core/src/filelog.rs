//! Truncating file log sink (`<data>/logs/core.log`, 64 KiB cap).
//!
//! The FFI layer installs a global `log::Log` implementation that tees into
//! this sink plus platform logging (logcat on Android), so a single exported
//! bundle contains everything the core ever logged — crucial for diagnosing
//! field crashes the sandbox can never reproduce.
//!
//! Policy (v0.5.6): the log is a **single bounded file**, not a set of
//! generations. Once it grows past [`MAX_BYTES`] the FIRST HALF OF THE LINES
//! is dropped and the rest is kept, then accumulation continues until the cap
//! is hit again. Compared with the old `core.log → core.1.log → core.2.log`
//! rotation this keeps the newest ~2× more context in one place, needs no
//! multi-file export, and never grows beyond the cap (the transient rewrite
//! peaks at ~2× 64 KiB on disk).

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

const MAX_BYTES: u64 = 64 * 1024; // 64 KiB per generation (product decision)

/// Generations used by the pre-0.5.6 rotation; removed on open so an exported
/// bundle can never contain stale duplicates of lines that are still in
/// `core.log`.
const LEGACY_KEEP: u32 = 3;

pub struct FileLog {
    dir: PathBuf,
    file: Mutex<Option<File>>,
    written: Mutex<u64>,
}

/// Split `data` at the line boundary nearest to half of its lines and return
/// (dropped_line_count, kept_bytes). Pure so it can be unit tested.
///
/// A short marker line is prepended to the kept half so an exported log always
/// says that (and how much) history was trimmed.
fn truncate_front_half(data: &[u8]) -> (usize, Vec<u8>) {
    let mut ends: Vec<usize> = Vec::new();
    for (i, b) in data.iter().enumerate() {
        if *b == b'\n' {
            ends.push(i + 1);
        }
    }
    if ends.is_empty() {
        // one unterminated line: nothing sensible to split, keep it all
        return (0, data.to_vec());
    }
    // a trailing fragment without '\n' counts as a line too
    let total = ends.len()
        + if ends.last().copied() == Some(data.len()) {
            0
        } else {
            1
        };
    let keep_from_line = total / 2; // drop lines [0, keep_from_line)
    if keep_from_line == 0 {
        return (0, data.to_vec());
    }
    let offset = if keep_from_line < ends.len() {
        ends[keep_from_line]
    } else {
        // keep only the unterminated tail fragment
        *ends.last().unwrap()
    };
    let dropped = if offset >= data.len() {
        total
    } else {
        keep_from_line
    };
    let mut body = &data[offset.min(data.len())..];
    // fold a previous trim marker into this one so repeated trims do not
    // stack "[trimmed]" lines at the top of the log
    let mut already = 0usize;
    if body.starts_with(b"[core.log trimmed:") {
        if let Some(nl) = body.iter().position(|b| *b == b'\n') {
            already = 1;
            body = &body[nl + 1..];
        }
    }
    let mut out = Vec::with_capacity(body.len() + 64);
    let _ = writeln!(
        out,
        "[core.log trimmed: {} older lines dropped]",
        dropped + already
    );
    out.extend_from_slice(body);
    (dropped + already, out)
}

impl FileLog {
    /// Open (creating) `<dir>/core.log` for appending. Never fails hard: on
    /// I/O errors the sink silently degrades to a no-op so logging can't
    /// break the app.
    pub fn open(dir: &Path) -> Self {
        let logs = dir.join("logs");
        let path = logs.join("core.log");
        let _ = fs::create_dir_all(&logs);
        // retire the pre-0.5.6 generations
        for i in 1..LEGACY_KEEP {
            let _ = fs::remove_file(logs.join(format!("core.{i}.log")));
        }
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .ok();
        let written = file
            .as_ref()
            .and_then(|f| f.metadata().ok().map(|m| m.len()))
            .unwrap_or(0);
        FileLog {
            dir: logs,
            file: Mutex::new(file),
            written: Mutex::new(written),
        }
    }

    /// Append one preformatted line, trimming the older half when over the cap.
    ///
    /// Lock order is always `written` -> `file` (and `trim_to_back_half` takes
    /// neither), so concurrent callers can't deadlock.
    pub fn line(&self, text: &str) {
        let mut written = self.written.lock().unwrap_or_else(|e| e.into_inner());
        if *written > MAX_BYTES {
            // release the handle so the rewrite can replace the file wholesale
            {
                let mut guard = self.file.lock().unwrap_or_else(|e| e.into_inner());
                *guard = None;
            }
            self.trim_to_back_half();
            let mut guard = self.file.lock().unwrap_or_else(|e| e.into_inner());
            *guard = OpenOptions::new()
                .create(true)
                .append(true)
                .open(self.dir.join("core.log"))
                .ok();
            *written = guard
                .as_ref()
                .and_then(|f| f.metadata().ok().map(|m| m.len()))
                .unwrap_or(0);
        }
        let mut guard = self.file.lock().unwrap_or_else(|e| e.into_inner());
        let Some(file) = guard.as_mut() else {
            return;
        };
        if writeln!(file, "{text}").is_ok() {
            let _ = file.flush(); // crash-resilient: every line hits the disk
            *written += text.len() as u64 + 1;
        }
    }

    /// Rewrite `core.log` keeping only its newer half (see the module docs).
    fn trim_to_back_half(&self) {
        let path = self.dir.join("core.log");
        let Ok(data) = fs::read(&path) else {
            return;
        };
        let (_dropped, kept) = truncate_front_half(&data);
        let tmp = self.dir.join("core.log.tmp");
        let written = fs::write(&tmp, &kept).and_then(|()| fs::rename(&tmp, &path));
        if written.is_err() {
            let _ = fs::remove_file(&tmp);
        }
    }

    /// All log files (newest first) as (file_name, path) — for export.
    pub fn files(&self) -> Vec<(String, PathBuf)> {
        let mut out = Vec::new();
        let base = self.dir.join("core.log");
        if base.exists() {
            out.push(("core.log".to_string(), base));
        }
        out
    }
}

/// Format one log record line: `2026-09-28T13:05:01Z INFO target — message`.
pub fn format_record(record: &log::Record) -> String {
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ");
    format!(
        "{ts} {} {} — {}",
        record.level(),
        record.target(),
        record.args()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(s: &[u8]) -> usize {
        s.iter().filter(|b| **b == b'\n').count()
    }

    #[test]
    fn keeps_the_newer_half_by_line_count() {
        let mut data = Vec::new();
        for i in 0..10 {
            let _ = writeln!(data, "line {i}");
        }
        let (dropped, kept) = truncate_front_half(&data);
        assert_eq!(dropped, 5);
        assert_eq!(lines(&kept), 6); // 5 kept lines + the marker
        let text = String::from_utf8(kept).unwrap();
        assert!(text.contains("line 5"));
        assert!(text.contains("line 9"));
        assert!(!text.contains("line 4\n"));
        assert!(text.starts_with("[core.log trimmed:"));
    }

    #[test]
    fn odd_line_count_drops_the_smaller_half() {
        let mut data = Vec::new();
        for i in 0..7 {
            let _ = writeln!(data, "l{i}");
        }
        let (dropped, kept) = truncate_front_half(&data);
        assert_eq!(dropped, 3);
        let text = String::from_utf8(kept).unwrap();
        assert!(text.contains("l3") && text.contains("l6"));
        assert!(!text.contains("l2\n"));
    }

    #[test]
    fn degenerate_inputs_are_kept_verbatim() {
        // no newline at all
        let (dropped, kept) = truncate_front_half(b"one long unterminated line");
        assert_eq!(dropped, 0);
        assert_eq!(kept, b"one long unterminated line");
        // single line
        let (dropped, kept) = truncate_front_half(b"only\n");
        assert_eq!(dropped, 0);
        assert_eq!(kept, b"only\n");
        // empty
        let (dropped, kept) = truncate_front_half(b"");
        assert_eq!(dropped, 0);
        assert!(kept.is_empty());
    }

    #[test]
    fn trailing_fragment_counts_as_a_line() {
        let data = b"a\nb\nc\nd\nno-newline-tail";
        let (dropped, kept) = truncate_front_half(data);
        // 5 logical lines -> drop 2 ("a", "b")
        assert_eq!(dropped, 2);
        let text = String::from_utf8(kept).unwrap();
        assert!(text.contains('c') && text.contains("no-newline-tail"));
        assert!(!text.contains("a\nb"));
    }

    #[test]
    fn file_stays_under_the_cap_across_many_lines() {
        let dir = tempfile::tempdir().unwrap();
        let log = FileLog::open(dir.path());
        let payload = "x".repeat(400);
        for i in 0..900 {
            log.line(&format!("[{i}] {payload}"));
        }
        let path = dir.path().join("logs/core.log");
        let len = fs::metadata(&path).unwrap().len();
        assert!(
            len <= MAX_BYTES + 1024,
            "log grew to {len} bytes, cap is {MAX_BYTES}"
        );
        let text = fs::read_to_string(&path).unwrap();
        assert!(text.contains("[899]"), "newest line must survive");
        assert!(text.contains("trimmed"), "a trim must have been recorded");
        assert!(!text.contains("[0] "), "oldest lines must be gone");
        assert!(!path.with_file_name("core.1.log").exists());
    }
}
