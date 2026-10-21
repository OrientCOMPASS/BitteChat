//! Embedded WebUI groundwork (qBittorrent-style, LAN remote control).
//!
//! The planned shape is an HTTP/WebSocket server INSIDE the core (behind a
//! future feature), serving a bundled web frontend and exposing the exact
//! JSON-RPC surface the Flutter app uses today (`Api::dispatch` plus the
//! `sys.drain_events` event stream pushed over a socket). This module fixes
//! the configuration surface and its validation rules ahead of that work;
//! no server is implemented yet (see docs/PLATFORMS.md, WebUI section).
//!
//! Security posture decided up front:
//! * default OFF, and when enabled bound to link-local/LAN interfaces only;
//! * password mandatory before enable (stored as a salted hash, never plain);
//! * every RPC keeps its existing validation — the web client gets no
//!   privilege the in-app client does not have.

use serde::{Deserialize, Serialize};

/// KV key under which the serialized [`WebUiConfig`] is persisted.
pub const KV_KEY: &str = "webui_config_v1";

/// Default listen port (the FFI/BT stack uses 17531; keep them adjacent but
/// distinct so both can run side by side).
pub const DEFAULT_PORT: u16 = 17532;

fn default_port() -> u16 {
    DEFAULT_PORT
}

fn default_lan_only() -> bool {
    true
}

fn default_username() -> String {
    "admin".to_string()
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WebUiConfig {
    /// Master switch; default off.
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "default_port")]
    pub port: u16,
    /// Restrict binding to private/link-local addresses (default true).
    #[serde(default = "default_lan_only")]
    pub lan_only: bool,
    #[serde(default = "default_username")]
    pub username: String,
    /// Salted hash (hex); empty means "no password set yet", which makes
    /// `enabled = true` invalid.
    #[serde(default)]
    pub password_hash: String,
}

impl Default for WebUiConfig {
    fn default() -> Self {
        WebUiConfig {
            enabled: false,
            port: DEFAULT_PORT,
            lan_only: true,
            username: default_username(),
            password_hash: String::new(),
        }
    }
}

impl WebUiConfig {
    /// Enforced on every write path (RPC setter and startup load).
    pub fn validate(&self) -> Result<(), String> {
        if self.port == 0 {
            return Err("webui port must be non-zero".to_string());
        }
        if self.username.trim().is_empty() {
            return Err("webui requires a non-empty username".to_string());
        }
        if self.enabled && self.password_hash.is_empty() {
            return Err("webui cannot be enabled without a password".to_string());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_disabled_and_lan_only() {
        let c = WebUiConfig::default();
        assert!(!c.enabled);
        assert!(c.lan_only);
        assert_eq!(c.port, DEFAULT_PORT);
        assert!(c.validate().is_ok());
    }

    #[test]
    fn enabled_requires_password() {
        let mut c = WebUiConfig {
            enabled: true,
            ..Default::default()
        };
        assert!(c.validate().is_err());
        c.password_hash = "deadbeef".to_string();
        assert!(c.validate().is_ok());
        c.username = "   ".to_string();
        assert!(c.validate().is_err());
    }

    #[test]
    fn serde_roundtrip_keeps_defaults() {
        let c = WebUiConfig::default();
        let j = serde_json::to_string(&c).unwrap();
        let back: WebUiConfig = serde_json::from_str(&j).unwrap();
        assert_eq!(back, c);
        // missing fields fall back to the safe defaults
        let sparse: WebUiConfig = serde_json::from_str("{}").unwrap();
        assert_eq!(sparse, WebUiConfig::default());
    }
}
