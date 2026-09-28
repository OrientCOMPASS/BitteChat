//! Rolling file log sink (`<data>/logs/core.log`, 2 MiB × 3 generations).
//!
//! The FFI layer installs a global `log::Log` implementation that tees into
//! this sink plus platform logging (logcat on Android), so a single exported
//! bundle contains everything the core ever logged — crucial for diagnosing
//! field crashes the sandbox can never reproduce.

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

const MAX_BYTES: u64 = 2 * 1024 * 1024;
const KEEP: u32 = 3; // core.log, core.1.log, core.2.log

pub struct FileLog {
    dir: PathBuf,
    file: Mutex<Option<File>>,
    written: Mutex<u64>,
}

impl FileLog {
    /// Open (creating) `<dir>/core.log` for appending. Never fails hard: on
    /// I/O errors the sink silently degrades to a no-op so logging can't
    /// break the app.
    pub fn open(dir: &Path) -> Self {
        let logs = dir.join("logs");
        let path = logs.join("core.log");
        let file = fs::create_dir_all(&logs)
            .ok()
            .and_then(|()| {
                OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&path)
                    .ok()
            })
            .map(|f| (f, path.clone()));
        let written = file
            .as_ref()
            .and_then(|(f, _)| f.metadata().ok().map(|m| m.len()))
            .unwrap_or(0);
        FileLog {
            dir: logs,
            file: Mutex::new(file.map(|(f, _)| f)),
            written: Mutex::new(written),
        }
    }

    /// Append one preformatted line, rotating when over the size cap.
    pub fn line(&self, text: &str) {
        let mut guard = self.file.lock().unwrap_or_else(|e| e.into_inner());
        let Some(file) = guard.as_mut() else {
            return;
        };
        let mut written = self.written.lock().unwrap_or_else(|e| e.into_inner());
        if *written > MAX_BYTES {
            drop(guard);
            self.rotate();
            guard = self.file.lock().unwrap_or_else(|e| e.into_inner());
            *written = 0;
            let Some(file) = guard.as_mut() else {
                return;
            };
            let _ = writeln!(file, "{text}");
            let _ = file.flush();
            *written = text.len() as u64 + 1;
            return;
        }
        if writeln!(file, "{text}").is_ok() {
            let _ = file.flush(); // crash-resilient: every line hits the disk
            *written += text.len() as u64 + 1;
        }
    }

    fn rotate(&self) {
        let mut guard = self.file.lock().unwrap_or_else(|e| e.into_inner());
        *guard = None;
        let base = self.dir.join("core.log");
        let _ = fs::remove_file(self.dir.join(format!("core.{}.log", KEEP - 1)));
        for i in (1..KEEP).rev() {
            let from = self.dir.join(format!("core.{}.log", i - 1));
            let to = self.dir.join(format!("core.{i}.log"));
            let _ = fs::rename(&from, &to);
        }
        *guard = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&base)
            .ok();
    }

    /// All log files (newest first) as (file_name, path) — for export.
    pub fn files(&self) -> Vec<(String, PathBuf)> {
        let mut out = Vec::new();
        let base = self.dir.join("core.log");
        if base.exists() {
            out.push(("core.log".to_string(), base));
        }
        for i in 1..KEEP {
            let p = self.dir.join(format!("core.{i}.log"));
            if p.exists() {
                out.push((format!("core.{i}.log"), p));
            }
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
