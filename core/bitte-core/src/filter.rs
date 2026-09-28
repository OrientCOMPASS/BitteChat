//! User-defined message filter rules (spam/malicious-peer mitigation).
//!
//! Rules are evaluated at *display* time only: blocked messages remain
//! stored, signed and part of the DAG (history integrity is untouched),
//! the UI collapses consecutive blocked messages into a single placeholder.

use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::chat::message::{ChatMessage, Payload};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuleField {
    AuthorName,
    AuthorPk,
    Text,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuleMode {
    Contains,
    Equals,
    Regex,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FilterRule {
    pub id: i64,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
    pub field: RuleField,
    pub mode: RuleMode,
    pub value: String,
    #[serde(default)]
    pub case_sensitive: bool,
}

fn default_enabled() -> bool {
    true
}

/// Plain-text projection of a message used for text matching.
pub fn message_search_text(m: &ChatMessage) -> String {
    match &m.payload {
        Payload::Text { text } => text.clone(),
        Payload::Attachment(a) => a.name.clone(),
        Payload::System { code, detail } => format!("{code} {detail}"),
        Payload::Chunk { data, .. } => String::from_utf8_lossy(data).to_string(),
        Payload::Sealed { .. } => String::new(),
    }
}

fn fold(s: &str) -> String {
    s.to_lowercase()
}

/// Whether a single rule matches the message. `regex_err` reports a broken
/// compiled pattern (treated as non-matching at eval time).
pub fn rule_matches(rule: &FilterRule, m: &ChatMessage) -> bool {
    if !rule.enabled || rule.value.is_empty() {
        return false;
    }
    let subject: String = match rule.field {
        RuleField::AuthorName => m.author_name.clone(),
        RuleField::AuthorPk => m.author_pk.clone(),
        RuleField::Text => message_search_text(m),
    };
    let (subject, value) = if rule.case_sensitive {
        (subject, rule.value.clone())
    } else {
        (fold(&subject), fold(&rule.value))
    };
    match rule.mode {
        RuleMode::Contains => subject.contains(&value),
        RuleMode::Equals => subject == value,
        RuleMode::Regex => match Regex::new(&rule.value) {
            Ok(re) => re.is_match(&subject),
            Err(_) => false,
        },
    }
}

/// True when any enabled rule matches. Own messages are never blocked.
pub fn is_blocked(rules: &[FilterRule], m: &ChatMessage) -> bool {
    if m.own {
        return false;
    }
    rules.iter().any(|r| rule_matches(r, m))
}

/// Validate a rule (regex compilation, sane lengths); returns Err(message).
pub fn validate_rule(rule: &FilterRule) -> Result<(), String> {
    if rule.value.is_empty() || rule.value.len() > 200 {
        return Err("rule value must be 1..200 bytes".into());
    }
    if rule.mode == RuleMode::Regex && Regex::new(&rule.value).is_err() {
        return Err("invalid regular expression".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chat::message::MsgKind;

    fn msg(name: &str, text: &str, pk: &str) -> ChatMessage {
        ChatMessage {
            id: "i".into(),
            group: "g".into(),
            parents: vec![],
            author_seq: 0,
            ts: 0,
            author_pk: pk.into(),
            author_name: name.into(),
            kind: MsgKind::Text as i64,
            payload: Payload::Text {
                text: text.to_string(),
            },
            sender_x: None,
            own: false,
            state: 1,
        }
    }

    #[test]
    fn contains_case_insensitive() {
        let r = FilterRule {
            id: 1,
            enabled: true,
            field: RuleField::Text,
            mode: RuleMode::Contains,
            value: "SPAM".into(),
            case_sensitive: false,
        };
        assert!(rule_matches(&r, &msg("a", "buy my Spam now", "p")));
        let cs = FilterRule {
            case_sensitive: true,
            ..r.clone()
        };
        assert!(!rule_matches(&cs, &msg("a", "buy my Spam now", "p")));
        assert!(rule_matches(&cs, &msg("a", "SPAM", "p")));
    }

    #[test]
    fn author_pk_equals() {
        let r = FilterRule {
            id: 1,
            enabled: true,
            field: RuleField::AuthorPk,
            mode: RuleMode::Equals,
            value: "deadbeef".into(),
            case_sensitive: false,
        };
        assert!(rule_matches(&r, &msg("a", "hi", "deadbeef")));
        assert!(!rule_matches(&r, &msg("a", "hi", "deadbeef00")));
    }

    #[test]
    fn regex_mode() {
        let r = FilterRule {
            id: 1,
            enabled: true,
            field: RuleField::AuthorName,
            mode: RuleMode::Regex,
            value: r"^ad\d+$".into(),
            case_sensitive: false,
        };
        assert!(rule_matches(&r, &msg("ad42", "x", "p")));
        assert!(!rule_matches(&r, &msg("xad42", "x", "p")));
        let bad = FilterRule {
            value: "(".into(),
            ..r
        };
        assert!(validate_rule(&bad).is_err());
        assert!(!rule_matches(&bad, &msg("ad42", "x", "p")));
    }

    #[test]
    fn disabled_and_own_never_block() {
        let r = FilterRule {
            id: 1,
            enabled: false,
            field: RuleField::Text,
            mode: RuleMode::Contains,
            value: "hi".into(),
            case_sensitive: false,
        };
        assert!(!is_blocked(std::slice::from_ref(&r), &msg("a", "hi", "p")));
        let on = FilterRule { enabled: true, ..r };
        let mut own = msg("a", "hi", "p");
        own.own = true;
        assert!(!is_blocked(std::slice::from_ref(&on), &own));
        assert!(is_blocked(std::slice::from_ref(&on), &msg("a", "hi", "p")));
    }
}
