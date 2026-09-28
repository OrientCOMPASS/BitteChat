/* bitte_torrent.cpp — libtorrent-backed BT engine with the bc_chat
 * extension (BEP10 custom extension messages) and BEP44 DHT items.
 *
 * Design notes:
 *  - one lt::session per bc_session, alerts drained on a dedicated thread
 *  - custom peer plugin advertises extension "bc_chat" (local id 42);
 *    sends are queued per-peer and flushed ON the libtorrent session thread
 *    (send_buffer is not thread-safe), woken via post_torrent_updates()
 *  - all JSON via boost::json (header-only); binary as base64 inside JSON
 *  - v1-only torrents for maximum client compatibility
 */

#include "bitte_torrent.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <filesystem>
#include <sys/stat.h>

#include <boost/json.hpp>
// compile the boost::json implementation into this TU (single-TU project)
#include <boost/json/src.hpp>

#include <libtorrent/libtorrent.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/bdecode.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/entry.hpp>
#include <libtorrent/extensions.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/peer_connection_handle.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_stats.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>

namespace json = boost::json;

using namespace libtorrent;
using namespace std::chrono_literals;

static constexpr int BC_EXT_ID = 42;
static constexpr int BC_MAX_EXT_PAYLOAD = 64 * 1024;

// ---------------------------------------------------------------------------
// small utilities
// ---------------------------------------------------------------------------

static std::string hex_encode(char const* d, std::size_t n)
{
    static const char* digits = "0123456789abcdef";
    std::string out;
    out.reserve(n * 2);
    for (std::size_t i = 0; i < n; ++i)
    {
        auto const c = static_cast<unsigned char>(d[i]);
        out.push_back(digits[c >> 4]);
        out.push_back(digits[c & 0xF]);
    }
    return out;
}

template <std::size_t N>
static std::string hex_encode(std::array<char, N> const& a)
{
    return hex_encode(a.data(), N);
}

static bool hex_decode(std::string const& in, std::vector<unsigned char>& out)
{
    if (in.size() % 2 != 0) return false;
    out.clear();
    out.reserve(in.size() / 2);
    auto val = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    };
    for (std::size_t i = 0; i < in.size(); i += 2)
    {
        int const hi = val(in[i]);
        int const lo = val(in[i + 1]);
        if (hi < 0 || lo < 0) return false;
        out.push_back(static_cast<unsigned char>((hi << 4) | lo));
    }
    return true;
}

static std::string b64_encode(char const* d, std::size_t n)
{
    static const char* tbl =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    out.reserve(((n + 2) / 3) * 4);
    std::size_t i = 0;
    while (i + 3 <= n)
    {
        std::uint32_t v = (static_cast<std::uint8_t>(d[i]) << 16)
            | (static_cast<std::uint8_t>(d[i + 1]) << 8)
            | static_cast<std::uint8_t>(d[i + 2]);
        out.push_back(tbl[(v >> 18) & 63]);
        out.push_back(tbl[(v >> 12) & 63]);
        out.push_back(tbl[(v >> 6) & 63]);
        out.push_back(tbl[v & 63]);
        i += 3;
    }
    if (i + 1 == n)
    {
        std::uint32_t v = static_cast<std::uint8_t>(d[i]) << 16;
        out.push_back(tbl[(v >> 18) & 63]);
        out.push_back(tbl[(v >> 12) & 63]);
        out.push_back('=');
        out.push_back('=');
    }
    else if (i + 2 == n)
    {
        std::uint32_t v = (static_cast<std::uint8_t>(d[i]) << 16)
            | (static_cast<std::uint8_t>(d[i + 1]) << 8);
        out.push_back(tbl[(v >> 18) & 63]);
        out.push_back(tbl[(v >> 12) & 63]);
        out.push_back(tbl[(v >> 6) & 63]);
        out.push_back('=');
    }
    return out;
}

static std::string b64_encode(std::vector<char> const& v)
{
    return b64_encode(v.data(), v.size());
}

static bool b64_decode(std::string const& in, std::vector<char>& out)
{
    auto val = [](char c) -> int {
        if (c >= 'A' && c <= 'Z') return c - 'A';
        if (c >= 'a' && c <= 'z') return c - 'a' + 26;
        if (c >= '0' && c <= '9') return c - '0' + 52;
        if (c == '+') return 62;
        if (c == '/') return 63;
        return -1;
    };
    out.clear();
    out.reserve(in.size() / 4 * 3);
    int buf = 0;
    int bits = 0;
    for (char c : in)
    {
        if (c == '=' || c == '\n' || c == '\r') continue;
        int const v = val(c);
        if (v < 0) return false;
        buf = (buf << 6) | v;
        bits += 6;
        if (bits >= 8)
        {
            bits -= 8;
            out.push_back(static_cast<char>((buf >> bits) & 0xFF));
        }
    }
    return true;
}

static std::string entry_to_b64(entry const& e)
{
    std::vector<char> buf;
    bencode(std::back_inserter(buf), e);
    return b64_encode(buf);
}

static std::string peer_endpoint_str(tcp::endpoint const& ep)
{
    return ep.address().to_string() + ":" + std::to_string(ep.port());
}

static json::value json_err(std::string const& msg)
{
    json::object o;
    o["ok"] = false;
    o["error"] = msg;
    return o;
}

static json::value json_ok()
{
    json::object o;
    o["ok"] = true;
    return o;
}

// json param accessors ------------------------------------------------------------

static std::string jstr(json::object const& o, char const* key, std::string def = {})
{
    auto it = o.find(key);
    if (it == o.end() || !it->value().is_string()) return def;
    return std::string(it->value().get_string());
}

static std::int64_t jint(json::object const& o, char const* key, std::int64_t def = 0)
{
    auto it = o.find(key);
    if (it == o.end()) return def;
    if (it->value().is_int64()) return it->value().get_int64();
    if (it->value().is_uint64()) return static_cast<std::int64_t>(it->value().get_uint64());
    if (it->value().is_double()) return static_cast<std::int64_t>(it->value().get_double());
    return def;
}

static bool jbool(json::object const& o, char const* key, bool def = false)
{
    auto it = o.find(key);
    if (it == o.end() || !it->value().is_bool()) return def;
    return it->value().get_bool();
}

// ---------------------------------------------------------------------------
// bc_chat peer plugin
// ---------------------------------------------------------------------------

struct bc_ctx;

struct chat_peer_plugin final : peer_plugin
{
    chat_peer_plugin(bt_peer_connection_handle pc, sha1_hash ih, bc_ctx* ctx)
        : m_pc(std::move(pc)), m_ih(std::move(ih)), m_ctx(ctx)
    {}

    string_view type() const override { return "bc_chat"; }

    void add_handshake(entry& h) override
    {
        h["m"]["bc_chat"] = BC_EXT_ID;
        h["bc_cap"] = 1;
    }

    bool on_extension_handshake(bdecode_node const& h) override;
    bool on_extended(int length, int msg, span<char const> body) override;

    void on_disconnect(error_code const&) override;

    // called from any thread
    void queue_send(std::string payload)
    {
        std::lock_guard<std::mutex> l(m_mx);
        if (m_out.size() < 512) m_out.push_back(std::move(payload));
    }

    // MUST be called on the libtorrent session thread only
    void flush_outgoing()
    {
        std::vector<std::string> pending;
        {
            std::lock_guard<std::mutex> l(m_mx);
            pending.swap(m_out);
        }
        int const peer_id = m_peer_ext_id.load();
        if (peer_id <= 0) return;
        for (auto const& p : pending)
        {
            std::uint32_t const total = 2 + static_cast<std::uint32_t>(p.size());
            std::vector<char> frame;
            frame.reserve(total + 4);
            frame.push_back(static_cast<char>((total >> 24) & 0xFF));
            frame.push_back(static_cast<char>((total >> 16) & 0xFF));
            frame.push_back(static_cast<char>((total >> 8) & 0xFF));
            frame.push_back(static_cast<char>(total & 0xFF));
            frame.push_back(static_cast<char>(20)); // msg_extended
            frame.push_back(static_cast<char>(peer_id));
            frame.insert(frame.end(), p.begin(), p.end());
            m_pc.send_buffer(frame.data(), static_cast<int>(frame.size()));
        }
    }

    bool chat_ready() const { return m_peer_ext_id.load() > 0; }
    tcp::endpoint remote() const { return m_pc.remote(); }

private:
    bt_peer_connection_handle m_pc;
    sha1_hash m_ih;
    bc_ctx* m_ctx;
    std::atomic<int> m_peer_ext_id{0};
    std::mutex m_mx;
    std::vector<std::string> m_out;
};

// ---------------------------------------------------------------------------
// context shared between plugins and the session wrapper
// ---------------------------------------------------------------------------

struct bc_ctx
{
    bc_event_fn cb = nullptr;
    void* cb_ctx = nullptr;

    std::mutex reg_mx;
    std::map<std::string, std::vector<std::weak_ptr<chat_peer_plugin>>> registry;

    void emit(json::value const& v) const
    {
        if (!cb) return;
        std::string s = json::serialize(v);
        cb(cb_ctx, s.data(), static_cast<unsigned int>(s.size()));
    }

    void emit_event(char const* type, json::object data) const
    {
        json::object o;
        o["type"] = type;
        o["data"] = std::move(data);
        emit(o);
    }

    void register_peer(std::string const& ih, std::weak_ptr<chat_peer_plugin> p)
    {
        std::lock_guard<std::mutex> l(reg_mx);
        auto& v = registry[ih];
        // prune expired occasionally
        if (v.size() > 64)
        {
            v.erase(std::remove_if(v.begin(), v.end(),
                        [](auto const& w) { return w.expired(); }),
                v.end());
        }
        v.push_back(std::move(p));
    }

    void unregister_peer(std::string const& ih, chat_peer_plugin const* p)
    {
        std::lock_guard<std::mutex> l(reg_mx);
        auto it = registry.find(ih);
        if (it == registry.end()) return;
        auto& v = it->second;
        v.erase(std::remove_if(v.begin(), v.end(),
                    [p](auto const& w) {
                        auto sp = w.lock();
                        return !sp || sp.get() == p;
                    }),
            v.end());
        if (v.empty()) registry.erase(it);
    }

    // session-thread: flush all queues
    void flush_all()
    {
        std::vector<std::shared_ptr<chat_peer_plugin>> live;
        {
            std::lock_guard<std::mutex> l(reg_mx);
            for (auto it = registry.begin(); it != registry.end();)
            {
                auto& v = it->second;
                v.erase(std::remove_if(v.begin(), v.end(),
                            [&live](auto const& w) {
                                auto sp = w.lock();
                                if (!sp) return true;
                                live.push_back(std::move(sp));
                                return false;
                            }),
                    v.end());
                if (v.empty())
                    it = registry.erase(it);
                else
                    ++it;
            }
        }
        for (auto const& p : live) p->flush_outgoing();
    }

    std::size_t broadcast(std::string const& ih, std::string payload)
    {
        std::vector<std::shared_ptr<chat_peer_plugin>> live;
        {
            std::lock_guard<std::mutex> l(reg_mx);
            auto it = registry.find(ih);
            if (it == registry.end()) return 0;
            auto& v = it->second;
            v.erase(std::remove_if(v.begin(), v.end(),
                        [&live](auto const& w) {
                            auto sp = w.lock();
                            if (!sp) return true;
                            live.push_back(std::move(sp));
                            return false;
                        }),
                v.end());
        }
        std::size_t n = 0;
        for (auto const& p : live)
        {
            if (!p->chat_ready()) continue;
            p->queue_send(payload);
            ++n;
        }
        return n;
    }

    bool peer_is_chat(tcp::endpoint const& ep)
    {
        std::lock_guard<std::mutex> l(reg_mx);
        for (auto const& kv : registry)
        {
            for (auto const& w : kv.second)
            {
                auto sp = w.lock();
                if (sp && sp->chat_ready() && sp->remote() == ep) return true;
            }
        }
        return false;
    }
};

bool chat_peer_plugin::on_extension_handshake(bdecode_node const& h)
{
    if (h.type() != bdecode_node::dict_t) return false;
    bdecode_node const m = h.dict_find_dict("m");
    if (m.type() != bdecode_node::dict_t) return false;
    std::int64_t const id = m.dict_find_int_value("bc_chat", 0);
    if (id <= 0 || id > 255) return false;
    m_peer_ext_id.store(static_cast<int>(id));
    {
        json::object data;
        data["infohash"] = hex_encode(m_ih.data(), 20);
        data["peer"] = peer_endpoint_str(m_pc.remote());
        data["connected"] = true;
        m_ctx->emit_event("chat_peer", std::move(data));
    }
    return true;
}

void chat_peer_plugin::on_disconnect(error_code const&)
{
    json::object data;
    data["infohash"] = hex_encode(m_ih.data(), 20);
    data["peer"] = peer_endpoint_str(m_pc.remote());
    data["connected"] = false;
    m_ctx->emit_event("chat_peer", std::move(data));
}

bool chat_peer_plugin::on_extended(int const length, int const msg, span<char const> body)
{
    if (msg != BC_EXT_ID) return false;
    if (m_peer_ext_id.load() <= 0) return false;
    if (length > BC_MAX_EXT_PAYLOAD) return true; // drop oversized silently
    if (!m_pc.packet_finished()) return true;     // wait for the full packet

    json::object data;
    data["infohash"] = hex_encode(m_ih.data(), 20);
    data["peer"] = peer_endpoint_str(m_pc.remote());
    data["payload_b64"] = b64_encode(body.data(), static_cast<std::size_t>(body.size()));
    m_ctx->emit_event("ext_msg", std::move(data));
    return true;
}

// ---------------------------------------------------------------------------
// torrent + session plugins
// ---------------------------------------------------------------------------

struct chat_torrent_plugin final : torrent_plugin
{
    chat_torrent_plugin(bc_ctx* ctx, sha1_hash ih) : m_ctx(ctx), m_ih(std::move(ih)) {}

    std::shared_ptr<peer_plugin> new_connection(peer_connection_handle const& pc) override
    {
        if (pc.type() != connection_type::bittorrent) return {};
        auto p = std::make_shared<chat_peer_plugin>(
            bt_peer_connection_handle(pc), m_ih, m_ctx);
        m_ctx->register_peer(hex_encode(m_ih.data(), 20), p);
        return p;
    }

private:
    bc_ctx* m_ctx;
    sha1_hash m_ih;
};

struct chat_session_plugin final : plugin
{
    explicit chat_session_plugin(bc_ctx* ctx) : m_ctx(ctx) {}

    feature_flags_t implemented_features() override
    {
        return plugin::alert_feature | plugin::tick_feature;
    }

    std::shared_ptr<torrent_plugin> new_torrent(torrent_handle const& th, client_data_t) override
    {
        auto const ih = th.info_hashes();
        if (!ih.has_v1()) return {};
        return std::make_shared<chat_torrent_plugin>(m_ctx, ih.v1);
    }

    void on_alert(alert const* a) override
    {
        if (a->type() == state_update_alert::alert_type) m_ctx->flush_all();
    }

    void on_tick() override { m_ctx->flush_all(); }

private:
    bc_ctx* m_ctx;
};

// ---------------------------------------------------------------------------
// session wrapper
// ---------------------------------------------------------------------------

struct bc_session
{
    bc_ctx ctx;
    std::unique_ptr<lt::session> ses;
    std::atomic<bool> stop{false};
    std::thread alert_thread;

    std::mutex st_mx;
    std::map<std::string, torrent_status> statuses;
    std::map<std::string, torrent_handle> handles;

    // libtorrent postpones start_dht() until every bootstrap router hostname
    // has been resolved, and session dht_* calls made before that point are
    // SILENTLY DROPPED (no alert, no error). Queue the ops here instead of
    // losing them; alert_loop drains the queue once is_dht_running() flips.
    std::mutex dht_mx;
    std::vector<std::function<void()>> dht_pending;
    std::atomic<bool> dht_ready{false};

    std::atomic<std::int64_t> dht_nodes{-1};
    std::atomic<std::int64_t> has_incoming{0};
    int idx_dht_nodes = -1;
    int idx_has_incoming = -1;
};

static char* json_to_cstr(json::value const& v)
{
    std::string s = json::serialize(v);
    char* out = static_cast<char*>(std::malloc(s.size() + 1));
    if (!out) return nullptr;
    std::memcpy(out, s.c_str(), s.size() + 1);
    return out;
}

static std::string ih_hex(info_hash_t const& ih)
{
    if (ih.has_v1()) return hex_encode(ih.v1.data(), 20);
    if (ih.has_v2()) return hex_encode(ih.v2.data(), 32);
    return {};
}

static char const* state_name(torrent_status::state_t s)
{
    switch (s)
    {
    case torrent_status::checking_files: return "checking";
    case torrent_status::downloading_metadata: return "metadata";
    case torrent_status::downloading: return "downloading";
    case torrent_status::finished: return "finished";
    case torrent_status::seeding: return "seeding";
    case torrent_status::checking_resume_data: return "resume";
    default: return "unknown";
    }
}

static json::value status_to_json(torrent_status const& st)
{
    json::object o;
    o["infohash"] = ih_hex(st.info_hashes);
    o["name"] = st.name;
    o["save_path"] = st.save_path;
    o["total_bytes"] = st.total_wanted;
    o["done_bytes"] = st.total_wanted_done;
    o["progress"] = static_cast<double>(st.progress);
    o["download_rate"] = st.download_rate;
    o["upload_rate"] = st.upload_rate;
    o["num_peers"] = st.num_peers;
    o["num_seeds"] = st.num_seeds;
    o["paused"] = bool(st.flags & torrent_flags::paused);
    o["finished"] = st.is_finished;
    o["error"] = st.errc.message();
    o["state"] = state_name(st.state);
    return o;
}

static void register_handle(bc_session* s, torrent_handle const& th)
{
    auto const ih = th.info_hashes();
    std::string const key = ih_hex(ih);
    if (key.empty()) return;
    std::lock_guard<std::mutex> l(s->st_mx);
    s->handles[key] = th;
}

static torrent_handle find_handle(bc_session* s, std::string const& ih)
{
    std::lock_guard<std::mutex> l(s->st_mx);
    auto it = s->handles.find(ih);
    if (it == s->handles.end()) return {};
    return it->second;
}

// ---- DHT readiness queue ---------------------------------------------------
//
// libtorrent defers start_dht() until every dht_bootstrap_nodes hostname has
// been resolved (m_outstanding_router_lookups). Until then, session::dht_*
// calls are silently dropped: no alert, no error. That breaks two things:
//   * BEP44 gets never produce their dht_immutable/mutable_item alert, so
//     callers that marked a fetch "in flight" wait forever;
//   * head-pointer puts issued right after app start vanish.
// Queue the operation instead and let alert_loop (which wakes at least every
// 500ms) run it the moment the DHT starts. Even fully offline the DHT does
// start — failed router lookups also decrement the outstanding counter.

static constexpr std::size_t DHT_QUEUE_CAP = 4096;

/// Runs `op` immediately when the DHT is up; otherwise queues it for the
/// alert loop. Returns true when the op ran synchronously.
static bool dht_run_or_queue(bc_session* s, std::function<void()> op)
{
    if (s->dht_ready.load(std::memory_order_acquire))
    {
        op();
        return true;
    }
    std::lock_guard<std::mutex> l(s->dht_mx);
    if (s->ses->is_dht_running())
    {
        s->dht_ready.store(true, std::memory_order_release);
        std::vector<std::function<void()>> q;
        q.swap(s->dht_pending);
        for (auto& f : q) f();
        op();
        return true;
    }
    // cap the queue: ops are best-effort and re-issued by the sync layer
    if (s->dht_pending.size() < DHT_QUEUE_CAP)
        s->dht_pending.push_back(std::move(op));
    return false;
}

// ---- alert loop ------------------------------------------------------------

static void alert_loop(bc_session* s)
{
    auto last_updates = std::chrono::steady_clock::now();
    auto last_stats = last_updates;
    std::vector<alert*> alerts;
    while (!s->stop.load())
    {
        s->ses->wait_for_alert(500ms);
        s->ses->pop_alerts(&alerts);

        // flush DHT ops that arrived before the DHT finished bootstrapping
        if (!s->dht_ready.load(std::memory_order_relaxed)
            && s->ses->is_dht_running())
        {
            std::vector<std::function<void()>> q;
            {
                std::lock_guard<std::mutex> l(s->dht_mx);
                if (!s->dht_ready.exchange(true, std::memory_order_acq_rel))
                    q.swap(s->dht_pending);
            }
            for (auto& f : q) f();
        }

        for (alert* a : alerts)
        {
            switch (a->type())
            {
            case state_update_alert::alert_type:
            {
                auto* ua = alert_cast<state_update_alert>(a);
                std::lock_guard<std::mutex> l(s->st_mx);
                for (auto const& st : ua->status)
                {
                    std::string const key = ih_hex(st.info_hashes);
                    if (key.empty()) continue;
                    s->statuses[key] = st;
                }
                break;
            }
            case metadata_received_alert::alert_type:
            {
                auto* ma = alert_cast<metadata_received_alert>(a);
                {
                    std::lock_guard<std::mutex> l(s->st_mx);
                    auto it = s->handles.find(ih_hex(ma->handle.info_hashes()));
                    if (it == s->handles.end()) register_handle(s, ma->handle);
                }
                json::object data;
                data["infohash"] = ih_hex(ma->handle.info_hashes());
                s->ctx.emit_event("metadata", std::move(data));
                break;
            }
            case torrent_finished_alert::alert_type:
            {
                auto* fa = alert_cast<torrent_finished_alert>(a);
                json::object data;
                data["infohash"] = ih_hex(fa->handle.info_hashes());
                s->ctx.emit_event("finished", std::move(data));
                break;
            }
            case torrent_error_alert::alert_type:
            {
                auto* ea = alert_cast<torrent_error_alert>(a);
                json::object data;
                data["infohash"] = ih_hex(ea->handle.info_hashes());
                data["error"] = ea->error.message();
                s->ctx.emit_event("torrent_error", std::move(data));
                break;
            }
            case torrent_removed_alert::alert_type:
            {
                auto* ra = alert_cast<torrent_removed_alert>(a);
                std::string const key = ih_hex(ra->info_hashes);
                {
                    std::lock_guard<std::mutex> l(s->st_mx);
                    s->statuses.erase(key);
                    s->handles.erase(key);
                }
                json::object data;
                data["infohash"] = key;
                s->ctx.emit_event("removed", std::move(data));
                break;
            }
            case dht_immutable_item_alert::alert_type:
            {
                auto* ia = alert_cast<dht_immutable_item_alert>(a);
                bool const found = ia->item.type() != entry::undefined_t;
                json::object data;
                data["target_hex"] = hex_encode(ia->target.data(), 20);
                data["found"] = found;
                data["value_b64"] = found ? entry_to_b64(ia->item) : std::string();
                s->ctx.emit_event("dht_immutable", std::move(data));
                break;
            }
            case dht_mutable_item_alert::alert_type:
            {
                auto* ma = alert_cast<dht_mutable_item_alert>(a);
                bool const found = ma->item.type() != entry::undefined_t;
                json::object data;
                data["pk_hex"] = hex_encode(ma->key);
                data["salt"] = ma->salt;
                data["seq"] = ma->seq;
                data["sig_b64"] = b64_encode(ma->signature.data(), ma->signature.size());
                data["found"] = found;
                data["authoritative"] = ma->authoritative;
                data["value_b64"] = found ? entry_to_b64(ma->item) : std::string();
                s->ctx.emit_event("dht_mutable", std::move(data));
                break;
            }
            case dht_put_alert::alert_type:
            {
                auto* pa = alert_cast<dht_put_alert>(a);
                bool const mutable_put = pa->public_key != std::array<char, 32>{};
                json::object data;
                data["mutable"] = mutable_put;
                data["key"] = mutable_put
                    ? hex_encode(pa->public_key)
                    : hex_encode(pa->target.data(), 20);
                data["num_success"] = pa->num_success;
                s->ctx.emit_event("dht_put", std::move(data));
                break;
            }
            case session_stats_alert::alert_type:
            {
                auto* sa = alert_cast<session_stats_alert>(a);
                auto const vals = sa->counters();
                if (s->idx_dht_nodes >= 0
                    && s->idx_dht_nodes < static_cast<int>(vals.size()))
                    s->dht_nodes.store(vals[s->idx_dht_nodes]);
                if (s->idx_has_incoming >= 0
                    && s->idx_has_incoming < static_cast<int>(vals.size()))
                    s->has_incoming.store(vals[s->idx_has_incoming]);
                break;
            }
            case listen_succeeded_alert::alert_type:
            {
                auto* la = alert_cast<listen_succeeded_alert>(a);
                json::object data;
                data["level"] = "info";
                data["msg"] = std::string("listen ok: ") + la->message();
                s->ctx.emit_event("log", std::move(data));
                break;
            }
            case listen_failed_alert::alert_type:
            {
                auto* la = alert_cast<listen_failed_alert>(a);
                json::object data;
                data["level"] = "warn";
                data["msg"] = std::string("listen failed: ") + la->message();
                s->ctx.emit_event("log", std::move(data));
                break;
            }
            case dht_bootstrap_alert::alert_type:
            {
                json::object data;
                data["level"] = "info";
                data["msg"] = "DHT bootstrapped";
                s->ctx.emit_event("log", std::move(data));
                break;
            }
            case torrent_deleted_alert::alert_type:
            case save_resume_data_alert::alert_type:
            case save_resume_data_failed_alert::alert_type:
                break;
            default:
                break;
            }
        }
        alerts.clear();

        auto const now = std::chrono::steady_clock::now();
        if (now - last_updates >= 2s)
        {
            last_updates = now;
            s->ses->post_torrent_updates();
        }
        if (now - last_stats >= 5s)
        {
            last_stats = now;
            s->ses->post_session_stats();
        }
    }
}

// ---- commands ----------------------------------------------------------------

static json::value cmd_add_magnet(bc_session* s, json::object const& o)
{
    std::string const magnet = jstr(o, "magnet");
    if (magnet.empty()) return json_err("missing magnet");
    error_code ec;
    add_torrent_params atp = parse_magnet_uri(magnet, ec);
    if (ec) return json_err("bad magnet: " + ec.message());
    if (!atp.info_hashes.has_v1()) return json_err("magnet without v1 infohash");
    atp.save_path = jstr(o, "save_dir", ".");
    std::string const name = jstr(o, "name");
    if (!name.empty()) atp.name = name;
    if (jbool(o, "always_active"))
        atp.flags &= ~(torrent_flags::auto_managed | torrent_flags::paused);
    std::error_code fec;
    std::filesystem::create_directories(atp.save_path, fec);
    std::string const key = hex_encode(atp.info_hashes.v1.data(), 20);
    torrent_handle th = s->ses->add_torrent(std::move(atp));
    {
        std::lock_guard<std::mutex> l(s->st_mx);
        s->handles[key] = th;
    }
    json::object r;
    r["ok"] = true;
    r["infohash"] = key;
    return r;
}

static json::value cmd_add_torrent(bc_session* s, json::object const& o)
{
    std::vector<char> bytes;
    if (!b64_decode(jstr(o, "torrent_b64"), bytes)) return json_err("bad base64");
    error_code ec;
    bdecode_node const node = bdecode(bytes, ec);
    if (ec) return json_err("bad torrent file: " + ec.message());
    torrent_info ti(node, ec);
    if (ec) return json_err("bad torrent file: " + ec.message());
    add_torrent_params atp;
    atp.ti = std::make_shared<torrent_info>(std::move(ti));
    atp.save_path = jstr(o, "save_dir", ".");
    std::string const name_hint = jstr(o, "name");
    if (!name_hint.empty()) atp.name = name_hint;
    if (jbool(o, "always_active"))
        atp.flags &= ~(torrent_flags::auto_managed | torrent_flags::paused);
    std::error_code fec;
    std::filesystem::create_directories(atp.save_path, fec);
    std::string const magnet = make_magnet_uri(atp);
    auto const ih = atp.ti->info_hashes();
    std::string key = ih_hex(ih);
    if (!ih.has_v1()) return json_err("v2-only torrents are not supported yet");
    torrent_handle th = s->ses->add_torrent(std::move(atp));
    std::string const tname = th.status(torrent_handle::query_name).name;
    {
        std::lock_guard<std::mutex> l(s->st_mx);
        s->handles[key] = th;
    }
    json::object r;
    r["ok"] = true;
    r["infohash"] = key;
    r["name"] = tname;
    r["magnet"] = magnet;
    return r;
}

static json::value cmd_remove(bc_session* s, json::object const& o)
{
    torrent_handle const th = find_handle(s, jstr(o, "infohash"));
    if (!th.is_valid()) return json_err("unknown torrent");
    s->ses->remove_torrent(th,
        jbool(o, "delete_files") ? session_handle::delete_files : remove_flags_t{});
    return json_ok();
}

static json::value cmd_pause(bc_session* s, json::object const& o)
{
    torrent_handle const th = find_handle(s, jstr(o, "infohash"));
    if (!th.is_valid()) return json_err("unknown torrent");
    if (jbool(o, "paused", true))
    {
        th.unset_flags(torrent_flags::auto_managed);
        th.pause();
    }
    else
    {
        th.set_flags(torrent_flags::auto_managed);
        th.resume();
    }
    s->ses->post_torrent_updates();
    return json_ok();
}

static json::value cmd_states(bc_session* s, json::object const&)
{
    s->ses->post_torrent_updates();
    json::array arr;
    {
        std::lock_guard<std::mutex> l(s->st_mx);
        for (auto const& kv : s->statuses) arr.push_back(status_to_json(kv.second));
    }
    json::object r;
    r["ok"] = true;
    r["torrents"] = std::move(arr);
    return r;
}

static json::value cmd_peers(bc_session* s, json::object const& o)
{
    torrent_handle const th = find_handle(s, jstr(o, "infohash"));
    if (!th.is_valid()) return json_err("unknown torrent");
    json::array arr;
    try
    {
        std::vector<peer_info> pis;
        th.get_peer_info(pis);
        for (auto const& p : pis)
        {
            json::object po;
            po["ip"] = p.ip.address().to_string();
            po["port"] = p.ip.port();
            po["client"] = p.client;
            po["progress"] = static_cast<double>(p.progress);
            po["up_speed"] = p.up_speed;
            po["down_speed"] = p.down_speed;
            po["flags"] = static_cast<std::uint64_t>(
                static_cast<std::uint32_t>(p.flags));
            po["chat_capable"] = s->ctx.peer_is_chat(p.ip);
            arr.push_back(std::move(po));
        }
    }
    catch (std::exception const& e)
    {
        return json_err(e.what());
    }
    json::object r;
    r["ok"] = true;
    r["peers"] = std::move(arr);
    return r;
}

static json::value cmd_files(bc_session* s, json::object const& o)
{
    torrent_handle const th = find_handle(s, jstr(o, "infohash"));
    if (!th.is_valid()) return json_err("unknown torrent");
    auto tf = th.torrent_file();
    if (!tf) return json_err("no metadata yet");
    file_storage const& fs = tf->files();
    std::vector<std::int64_t> progress;
    th.file_progress(progress);
    auto const prios = th.get_file_priorities();
    json::array arr;
    for (auto const i : fs.file_range())
    {
        json::object fo;
        fo["index"] = static_cast<int>(i);
        fo["path"] = fs.file_path(i);
        fo["size"] = fs.file_size(i);
        int const idx = static_cast<int>(i);
        fo["priority"] = idx < static_cast<int>(prios.size())
            ? static_cast<int>(static_cast<std::uint8_t>(prios[idx]))
            : 4;
        std::int64_t const done = idx < static_cast<int>(progress.size()) ? progress[idx] : 0;
        std::int64_t const size = fs.file_size(i);
        fo["progress"] = size > 0 ? static_cast<double>(done) / static_cast<double>(size) : 1.0;
        arr.push_back(std::move(fo));
    }
    json::object r;
    r["ok"] = true;
    r["files"] = std::move(arr);
    return r;
}

static json::value cmd_file_priorities(bc_session* s, json::object const& o)
{
    torrent_handle const th = find_handle(s, jstr(o, "infohash"));
    if (!th.is_valid()) return json_err("unknown torrent");
    auto it = o.find("priorities");
    if (it == o.end() || !it->value().is_array()) return json_err("missing priorities");
    std::vector<download_priority_t> prios;
    for (auto const& v : it->value().get_array())
    {
        int p = 4;
        if (v.is_int64()) p = static_cast<int>(v.get_int64());
        p = std::max(0, std::min(7, p));
        prios.emplace_back(static_cast<std::uint8_t>(p));
    }
    th.prioritize_files(prios);
    return json_ok();
}

static json::value cmd_trackers(bc_session* s, json::object const& o)
{
    torrent_handle const th = find_handle(s, jstr(o, "infohash"));
    if (!th.is_valid()) return json_err("unknown torrent");
    json::array arr;
    try
    {
        for (auto const& ae : th.trackers())
        {
            json::object to;
            to["url"] = ae.url;
            to["tier"] = static_cast<int>(ae.tier);
            to["verified"] = ae.verified;
            // libtorrent 2.x moved per-announce state (fails/last_error)
            // into per-endpoint structs; keep the JSON schema stable
            to["fails"] = 0;
            to["message"] = std::string();
            arr.push_back(std::move(to));
        }
    }
    catch (std::exception const& e)
    {
        return json_err(e.what());
    }
    json::object r;
    r["ok"] = true;
    r["trackers"] = std::move(arr);
    return r;
}

static json::value cmd_add_tracker(bc_session* s, json::object const& o)
{
    torrent_handle const th = find_handle(s, jstr(o, "infohash"));
    if (!th.is_valid()) return json_err("unknown torrent");
    std::string const url = jstr(o, "url");
    if (url.empty()) return json_err("missing url");
    int const tier = static_cast<int>(jint(o, "tier", 0));
    try
    {
        announce_entry ae(url);
        ae.tier = static_cast<std::uint8_t>(std::max(0, std::min(255, tier)));
        th.add_tracker(ae);
    }
    catch (std::exception const& e)
    {
        return json_err(e.what());
    }
    return json_ok();
}

static json::value cmd_remove_tracker(bc_session* s, json::object const& o)
{
    torrent_handle const th = find_handle(s, jstr(o, "infohash"));
    if (!th.is_valid()) return json_err("unknown torrent");
    std::string const url = jstr(o, "url");
    if (url.empty()) return json_err("missing url");
    try
    {
        // libtorrent 2.x has no remove_tracker; filter + replace
        std::vector<announce_entry> aes = th.trackers();
        auto const it = std::remove_if(aes.begin(), aes.end(),
            [&url](announce_entry const& e) { return e.url == url; });
        if (it == aes.end()) return json_err("tracker not found");
        aes.erase(it, aes.end());
        th.replace_trackers(std::move(aes));
    }
    catch (std::exception const& e)
    {
        return json_err(e.what());
    }
    return json_ok();
}

static json::value cmd_create_torrent(bc_session* s, json::object const& o)
{
    (void)s;
    std::string const path = jstr(o, "path");
    if (path.empty()) return json_err("missing path");
    struct stat st {};
    if (::stat(path.c_str(), &st) != 0) return json_err("file not found: " + path);
    if (S_ISDIR(st.st_mode)) return json_err("directory torrents are not supported yet");

    // single-file torrent; root name = file basename
    std::string base = path;
    auto const slash = base.find_last_of('/');
    if (slash != std::string::npos) base = base.substr(slash + 1);

    // root dir = parent of the file (fs paths are relative to it)
    std::string root_dir = (slash == std::string::npos) ? std::string(".")
                                                        : path.substr(0, slash);
    file_storage fs;
    fs.add_file(base, st.st_size);
    fs.set_name(base);
    create_torrent ct(fs, 0, create_torrent::v1_only);
    std::string const comment = jstr(o, "comment", "BitteChat");
    ct.set_comment(comment.c_str());
    ct.set_creator("BitteChat/libtorrent");
    error_code hec;
    set_piece_hashes(ct, root_dir, hec);
    if (hec) return json_err(std::string("set_piece_hashes: ") + hec.message());
    entry const te = ct.generate();
    std::vector<char> buf;
    bencode(std::back_inserter(buf), te);

    error_code ec;
    bdecode_node const node = bdecode(buf, ec);
    if (ec) return json_err(std::string("internal: ") + ec.message());
    torrent_info ti(node, ec);
    if (ec) return json_err(std::string("internal: ") + ec.message());
    if (!ti.info_hashes().has_v1()) return json_err("internal: no v1 hash");

    json::object r;
    r["ok"] = true;
    r["infohash"] = hex_encode(ti.info_hashes().v1.data(), 20);
    r["torrent_b64"] = b64_encode(buf);
    r["magnet"] = make_magnet_uri(ti);
    r["name"] = base;
    return r;
}

static json::value cmd_dht_get_immutable(bc_session* s, json::object const& o)
{
    std::vector<unsigned char> raw;
    if (!hex_decode(jstr(o, "target_hex"), raw) || raw.size() != 20)
        return json_err("bad target");
    sha1_hash target;
    std::memcpy(target.data(), raw.data(), 20);
    lt::session* ses = s->ses.get();
    dht_run_or_queue(s, [ses, target]() { ses->dht_get_item(target); });
    return json_ok();
}

static json::value cmd_dht_put_immutable(bc_session* s, json::object const& o)
{
    std::vector<char> value;
    if (!b64_decode(jstr(o, "value_b64"), value)) return json_err("bad base64");
    error_code ec;
    bdecode_node const node = bdecode(value, ec);
    if (ec) return json_err(std::string("value not bencoded: ") + ec.message());
    entry const data(node);
    // compute the target without touching the DHT — the exact computation
    // session::dht_put_item() does internally (sha1 of canonical bencode),
    // so matches_expected stays meaningful even while the put is queued
    std::vector<char> buf;
    bencode(std::back_inserter(buf), data);
    sha1_hash const target = hasher(buf).final();
    lt::session* ses = s->ses.get();
    dht_run_or_queue(s, [ses, data]() { ses->dht_put_item(data); });
    std::string const got = hex_encode(target.data(), 20);
    std::string const expected = jstr(o, "target_hex");
    json::object r;
    r["ok"] = true;
    r["target_hex"] = got;
    r["matches_expected"] = expected.empty() || expected == got;
    return r;
}

static json::value cmd_dht_get_mutable(bc_session* s, json::object const& o)
{
    std::vector<unsigned char> raw;
    if (!hex_decode(jstr(o, "pk_hex"), raw) || raw.size() != 32)
        return json_err("bad pubkey");
    std::array<char, 32> pk{};
    std::memcpy(pk.data(), raw.data(), 32);
    std::string const salt = jstr(o, "salt");
    lt::session* ses = s->ses.get();
    dht_run_or_queue(
        s, [ses, pk, salt]() { ses->dht_get_item(pk, salt); });
    return json_ok();
}

static json::value cmd_dht_put_mutable(bc_session* s, json::object const& o)
{
    std::vector<unsigned char> rawpk;
    if (!hex_decode(jstr(o, "pk_hex"), rawpk) || rawpk.size() != 32)
        return json_err("bad pubkey");
    std::array<char, 32> pk{};
    std::memcpy(pk.data(), rawpk.data(), 32);

    std::vector<char> sigraw;
    if (!b64_decode(jstr(o, "sig_b64"), sigraw) || sigraw.size() != 64)
        return json_err("bad signature");
    std::array<char, 64> sig{};
    std::memcpy(sig.data(), sigraw.data(), 64);

    std::vector<char> value;
    if (!b64_decode(jstr(o, "value_b64"), value)) return json_err("bad value");
    std::int64_t const seq = jint(o, "seq", 0);
    std::string const salt = jstr(o, "salt");

    std::string value_copy(value.data(), value.size());
    lt::session* ses = s->ses.get();
    dht_run_or_queue(s, [ses, pk, value_copy, sig, seq, salt]() {
        ses->dht_put_item(pk,
            [value_copy, sig, seq](entry& e, std::array<char, 64>& s_out,
                std::int64_t& seq_out, std::string const&) {
                error_code ec;
                bdecode_node const node
                    = bdecode(span<char const>(value_copy.data(), value_copy.size()), ec);
                if (!ec) e = entry(node);
                s_out = sig;
                seq_out = seq;
            },
            salt);
    });
    return json_ok();
}

static json::value cmd_ext_send(bc_session* s, json::object const& o)
{
    std::vector<char> payload;
    if (!b64_decode(jstr(o, "payload_b64"), payload)) return json_err("bad base64");
    std::string const ih = jstr(o, "infohash");
    std::size_t const n = s->ctx.broadcast(ih, std::string(payload.data(), payload.size()));
    if (n > 0) s->ses->post_torrent_updates(); // wake the session thread to flush
    json::object r;
    r["ok"] = true;
    r["sent"] = static_cast<std::int64_t>(n);
    return r;
}

static json::value cmd_stats(bc_session* s, json::object const&)
{
    std::int64_t up = 0, down = 0;
    std::size_t n = 0;
    {
        std::lock_guard<std::mutex> l(s->st_mx);
        for (auto const& kv : s->statuses)
        {
            up += kv.second.upload_rate;
            down += kv.second.download_rate;
            ++n;
        }
    }
    json::object r;
    r["ok"] = true;
    r["dht_nodes"] = s->dht_nodes.load();
    r["upload_rate"] = up;
    r["download_rate"] = down;
    r["num_torrents"] = static_cast<std::int64_t>(n);
    r["has_incoming"] = s->has_incoming.load() != 0;
    return r;
}

static json::value cmd_set_limits(bc_session* s, json::object const& o)
{
    settings_pack pack;
    bool any = false;
    auto it = o.find("up_limit");
    if (it != o.end() && it->value().is_int64())
    {
        pack.set_int(settings_pack::upload_rate_limit,
            static_cast<int>(it->value().get_int64()));
        any = true;
    }
    it = o.find("down_limit");
    if (it != o.end() && it->value().is_int64())
    {
        pack.set_int(settings_pack::download_rate_limit,
            static_cast<int>(it->value().get_int64()));
        any = true;
    }
    if (any) s->ses->apply_settings(std::move(pack));
    return json_ok();
}

// ---------------------------------------------------------------------------
// public C API
// ---------------------------------------------------------------------------

extern "C" const char* bct_libtorrent_version(void)
{
    return LIBTORRENT_VERSION;
}

extern "C" bc_session* bct_create(const char* cfg_json, bc_event_fn cb, void* cb_ctx)
{
#ifdef __unix__
    ::signal(SIGPIPE, SIG_IGN);
#endif
    boost::system::error_code jec;
    json::value cfgv = json::parse(cfg_json ? cfg_json : "{}", jec);
    if (jec) cfgv = json::object{};
    json::object const& cfg = cfgv.is_object() ? cfgv.get_object() : json::object{};

    auto* s = new bc_session();
    s->ctx.cb = cb;
    s->ctx.cb_ctx = cb_ctx;

    int const listen_port = static_cast<int>(jint(cfg, "listen_port", 17531));
    settings_pack pack;
    pack.set_str(settings_pack::listen_interfaces,
        "0.0.0.0:" + std::to_string(listen_port) + ",[::]:" + std::to_string(listen_port));
    pack.set_bool(settings_pack::listen_system_port_fallback, true);
    std::string ua = jstr(cfg, "user_agent");
    if (ua.empty()) ua = std::string("BitteChat/") + LIBTORRENT_VERSION;
    pack.set_str(settings_pack::user_agent, ua);
    {
        auto const mask = alert_category::status | alert_category::error
            | alert_category::dht;
        pack.set_int(settings_pack::alert_mask,
            static_cast<int>(static_cast<std::uint32_t>(mask)));
    }
    pack.set_bool(settings_pack::enable_dht, true);
    {
        // Keep libtorrent's own default bootstrap (dht.libtorrent.org:25401)
        // unless the caller overrides it: swapping in longer router lists was
        // observed to stall DHT bootstrap on CI runners — libtorrent defers
        // start_dht() until EVERY router hostname has resolved, so one
        // dead/slow domain delays the whole DHT. Configurable via cfg key
        // "dht_bootstrap_nodes" (comma-separated host:port list). Ops issued
        // before the DHT starts are queued by dht_run_or_queue() instead of
        // being silently dropped.
        std::string const bootstrap = jstr(cfg, "dht_bootstrap_nodes");
        if (!bootstrap.empty())
        {
            pack.set_str(settings_pack::dht_bootstrap_nodes, bootstrap);
        }
    }
    pack.set_bool(settings_pack::enable_lsd, true);
    pack.set_bool(settings_pack::enable_upnp, true);
    pack.set_bool(settings_pack::enable_natpmp, true);
    // chat manifests must never be queued inactive
    pack.set_int(settings_pack::active_downloads, -1);
    pack.set_int(settings_pack::active_seeds, -1);
    pack.set_int(settings_pack::active_limit, -1);
    pack.set_int(settings_pack::active_checking, -1);
    pack.set_int(settings_pack::upload_rate_limit,
        static_cast<int>(jint(cfg, "up_limit", 0)));
    pack.set_int(settings_pack::download_rate_limit,
        static_cast<int>(jint(cfg, "down_limit", 0)));
    pack.set_int(settings_pack::connections_limit,
        static_cast<int>(jint(cfg, "connections_limit", 200)));
    pack.set_bool(settings_pack::enable_outgoing_utp, true);
    pack.set_bool(settings_pack::enable_incoming_utp, true);
    pack.set_bool(settings_pack::enable_outgoing_tcp, true);
    pack.set_bool(settings_pack::enable_incoming_tcp, true);

    try
    {
        s->ses = std::make_unique<lt::session>(std::move(pack));
    }
    catch (std::exception const& e)
    {
        fprintf(stderr, "bct_create: session init failed: %s\n", e.what());
        delete s;
        return nullptr;
    }

    s->idx_dht_nodes = find_metric_idx("dht.nodes");
    s->idx_has_incoming = find_metric_idx("net.has_incoming_connections");

    s->ses->add_extension(std::make_shared<chat_session_plugin>(&s->ctx));

    s->alert_thread = std::thread(alert_loop, s);
    return s;
}

extern "C" char* bct_call(bc_session* s, const char* method, const char* params_json)
{
    if (!s || !method) return json_to_cstr(json_err("null session"));
    boost::system::error_code jec;
    json::value pv = json::parse(params_json && *params_json ? params_json : "{}", jec);
    json::object obj;
    if (!jec && pv.is_object()) obj = pv.get_object();

    try
    {
        std::string const m(method);
        if (m == "add_magnet") return json_to_cstr(cmd_add_magnet(s, obj));
        if (m == "add_torrent") return json_to_cstr(cmd_add_torrent(s, obj));
        if (m == "remove") return json_to_cstr(cmd_remove(s, obj));
        if (m == "pause") return json_to_cstr(cmd_pause(s, obj));
        if (m == "states") return json_to_cstr(cmd_states(s, obj));
        if (m == "peers") return json_to_cstr(cmd_peers(s, obj));
        if (m == "files") return json_to_cstr(cmd_files(s, obj));
        if (m == "file_priorities") return json_to_cstr(cmd_file_priorities(s, obj));
        if (m == "trackers") return json_to_cstr(cmd_trackers(s, obj));
        if (m == "add_tracker") return json_to_cstr(cmd_add_tracker(s, obj));
        if (m == "remove_tracker") return json_to_cstr(cmd_remove_tracker(s, obj));
        if (m == "create_torrent") return json_to_cstr(cmd_create_torrent(s, obj));
        if (m == "dht_get_immutable") return json_to_cstr(cmd_dht_get_immutable(s, obj));
        if (m == "dht_put_immutable") return json_to_cstr(cmd_dht_put_immutable(s, obj));
        if (m == "dht_get_mutable") return json_to_cstr(cmd_dht_get_mutable(s, obj));
        if (m == "dht_put_mutable") return json_to_cstr(cmd_dht_put_mutable(s, obj));
        if (m == "ext_send") return json_to_cstr(cmd_ext_send(s, obj));
        if (m == "stats") return json_to_cstr(cmd_stats(s, obj));
        if (m == "set_limits") return json_to_cstr(cmd_set_limits(s, obj));
        return json_to_cstr(json_err("unknown method: " + m));
    }
    catch (std::exception const& e)
    {
        return json_to_cstr(json_err(std::string("exception: ") + e.what()));
    }
}

extern "C" void bct_free_str(char* str)
{
    std::free(str);
}

extern "C" void bct_destroy(bc_session* s)
{
    if (!s) return;
    s->stop.store(true);
    if (s->alert_thread.joinable()) s->alert_thread.join();
    s->ses.reset(); // graceful session shutdown
    delete s;
}
