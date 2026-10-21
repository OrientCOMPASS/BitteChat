// The deterministic dual-instance swarm torrent (see
// scripts/swarm/gen_torrent.py: fixed 16 MiB content, 256 KiB pieces, no
// creation date => constant infohash). The CI host seeds it with aria2
// behind scripts/swarm/mini_tracker.py; the emulator downloads it through
// 10.0.2.2, giving the Peers tab a REAL second client to show.
//
// Regenerate with:
//   python3 scripts/swarm/gen_torrent.py --out /tmp/swarm && \
//   base64 -w0 /tmp/swarm/swarm.torrent
// (gen_torrent.py exits non-zero if the infohash ever drifts from
// kSwarmInfohash below.)

/// sha1(info) of [kSwarmTorrentB64]; asserted by the integration test.
const String kSwarmInfohash = '71a6e141ca08eadbe408d70ed97e21562be14fa4';

/// Display name stored for the imported torrent.
const String kSwarmName = 'bitte-swarm.bin';

/// The host-side mini tracker, as seen from inside the emulator.
const String kSwarmTracker = 'http://10.0.2.2:6969/announce';

/// base64 of the .torrent bytes (split for readability; join() it).
const List<String> kSwarmTorrentB64 = [
  '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'
];
