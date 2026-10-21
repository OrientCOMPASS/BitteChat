//! Chat subsystem: message format, DAG and group manifest.

pub mod dag;
pub mod group;
pub mod message;
pub mod sync;

pub use dag::Dag;
pub use group::{GroupManifest, HeadItem};
pub use message::{ChatMessage, MsgKind, Payload, SignedMessage};
