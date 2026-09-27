/* bitte_torrent.h — C ABI of the libtorrent-backed BitTorrent engine.
 *
 * The Rust crate `bitte-bt` links against this. All strings are UTF-8,
 * NUL-terminated. All binary data crosses the boundary as base64 inside JSON.
 * All methods are JSON-in / JSON-out via bc_call(); asynchronous events are
 * pushed through the bc_event_fn callback registered at bc_create().
 *
 * Thread-safety: bc_call may be invoked from any thread. Events may be
 * delivered from the internal alert thread. The implementation must not
 * block the caller on network I/O.
 */
#ifndef BITTE_TORRENT_H
#define BITTE_TORRENT_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct bc_session bc_session;

/* Event callback: JSON document (not NUL-terminated) of `len` bytes. */
typedef void (*bc_event_fn)(void* ctx, const char* json, unsigned int len);

/* cfg_json: {"data_dir": "...", "listen_port": 6881, "up_limit": 0,
 *            "down_limit": 0, "user_agent": "BitteChat/0.1"}
 * Returns NULL on failure (writes a log line to stderr). */
bc_session* bc_create(const char* cfg_json, bc_event_fn cb, void* ctx);

/* Invoke a command. Returns a heap-allocated JSON string:
 *   {"ok": true, ...result fields...}   on success
 *   {"ok": false, "error": "..."}       on failure
 * Free with bc_free_str. */
char* bc_call(bc_session* s, const char* method, const char* params_json);

void bc_free_str(char* s);

void bc_destroy(bc_session* s);

/* libtorrent version string, e.g. "2.1.2.0" */
const char* bc_libtorrent_version(void);

#ifdef __cplusplus
}
#endif

#endif /* BITTE_TORRENT_H */
