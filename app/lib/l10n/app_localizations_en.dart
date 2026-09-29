// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get chatTab => 'Chats';

  @override
  String get btTab => 'Torrents';

  @override
  String get rssTab => 'Feeds';

  @override
  String get settings => 'Settings';

  @override
  String get identitySettings => 'Identity';

  @override
  String get demoMode => 'Demo mode';

  @override
  String get demoHint =>
      'libbitte_core.so not loaded.\nInstall a CI-built Android APK for full functionality.';

  @override
  String get coreUnavailable => 'Native core unavailable (demo mode)';

  @override
  String get coreUnavailableShort => 'Native core unavailable (demo mode)';

  @override
  String get installApkHint =>
      'Native core unavailable: install the CI-built APK';

  @override
  String get noGroups => 'No torrent rooms yet';

  @override
  String get noGroupsHint =>
      'Every torrent is a chat room.\nAdd any BT torrent (magnet link / info hash / .torrent file) to enter its room and talk with the other BitTorrent users in the same swarm.';

  @override
  String get createGroup => 'Create group';

  @override
  String get joinGroup => 'Join group';

  @override
  String get groupName => 'Group name';

  @override
  String get groupNameHint => 'e.g. BT enthusiasts';

  @override
  String get create => 'Create';

  @override
  String get join => 'Join';

  @override
  String get cancel => 'Cancel';

  @override
  String get confirm => 'OK';

  @override
  String get save => 'Save';

  @override
  String get delete => 'Delete';

  @override
  String get refresh => 'Refresh';

  @override
  String get refreshAll => 'Refresh all';

  @override
  String get paste => 'Paste';

  @override
  String get copyLink => 'Copy link';

  @override
  String get done => 'Done';

  @override
  String get inviteMagnet => 'Invite magnet link';

  @override
  String get magnetHint => 'magnet:?xt=urn:btih:...';

  @override
  String get alreadyInGroup => 'Already in this group';

  @override
  String get fetchingManifest =>
      'Fetching group manifest from the BT network… a member must be online seeding';

  @override
  String get groupCreated => 'Group created 🎉';

  @override
  String get inviteHint =>
      'Share the invite link (the peer must reach you or any online member\'s swarm)';

  @override
  String get joinViaPaste => 'Paste or scan someone\'s invite link';

  @override
  String get createGroupDesc => 'Generate an invite magnet to share';

  @override
  String get online => 'online';

  @override
  String get noMessages => 'No messages';

  @override
  String syncingMissing(Object n) {
    return 'Syncing: $n messages missing';
  }

  @override
  String historySynced(Object n) {
    return 'History synced · $n peers online';
  }

  @override
  String get dmEncrypted =>
      'End-to-end encrypted DM (X25519 + ChaCha20-Poly1305)';

  @override
  String get resync => 'Resync';

  @override
  String get resyncStarted => 'Sync requested from DHT and neighbours';

  @override
  String get groupDetail => 'Group details';

  @override
  String genesisTitle(Object name) {
    return 'The hash chain of \"$name\" starts here';
  }

  @override
  String get genesisSub =>
      'Every message is signed and links its parents; tampering is rejected by the network';

  @override
  String get emptyGroupHint => 'No messages yet\nSay something 👇';

  @override
  String get inputHint =>
      'Say something… (messages are signed into the hash chain)';

  @override
  String get sendFileTip => 'Send file (seed)';

  @override
  String get sending => 'Seeding and sending…';

  @override
  String sentSeeding(Object h) {
    return 'Sent, seeding: $h';
  }

  @override
  String get downloadViaBt => 'Download via BT';

  @override
  String downloadStarted(Object name) {
    return 'Downloading \"$name\" (chat transfer, hidden from the BT page)';
  }

  @override
  String get anonymous => 'anon';

  @override
  String get copyMessage => 'Copy message text';

  @override
  String get copyMessageId => 'Copy message ID (SHA-1)';

  @override
  String get copied => 'Copied';

  @override
  String get copiedId => 'Message ID copied';

  @override
  String get copiedInvite =>
      'Copied: anyone adding this torrent enters the same room';

  @override
  String get signatureInfo => 'Signature info';

  @override
  String sigDetail(Object pk, Object state) {
    return 'Author key $pk\nState $state';
  }

  @override
  String get sigConfirmed => 'confirmed (stored in DHT)';

  @override
  String get sigPending => 'pending';

  @override
  String get blockAuthor => 'Block this author';

  @override
  String get blockAuthorHint => 'Adds a filter rule (manage in Settings)';

  @override
  String blockedAuthor(Object name) {
    return 'Blocked $name';
  }

  @override
  String blockedCount(Object n) {
    return '$n blocked messages';
  }

  @override
  String get startDm => 'Start private chat';

  @override
  String startDmHint(Object name) {
    return 'End-to-end encrypted channel with $name';
  }

  @override
  String sysCreate(Object name, Object detail) {
    return '🎉 $name created group \"$detail\"';
  }

  @override
  String sysJoin(Object name) {
    return '👋 $name joined the group';
  }

  @override
  String sysLeave(Object name) {
    return '$name left the group';
  }

  @override
  String sysRename(Object name, Object detail) {
    return '📛 $name renamed the group to \"$detail\"';
  }

  @override
  String get sysDmInvite => 'sent a DM invite (auto-join)';

  @override
  String sysGeneric(Object code, Object detail) {
    return '[system] $code $detail';
  }

  @override
  String get sysMsg => 'System message';

  @override
  String get chunkSyncing => '〔long message chunks syncing…〕';

  @override
  String get renameGroup => 'Rename group';

  @override
  String get renameBroadcast => 'Broadcast as a signed system message';

  @override
  String get leaveGroup => 'Leave group';

  @override
  String get leaveGroupQ => 'Leave group?';

  @override
  String get leaveGroupHint =>
      'Ends the private conversation (local history is kept by default).';

  @override
  String get leave => 'Leave';

  @override
  String get members => 'Online members';

  @override
  String get manifestTorrent => 'Manifest torrent';

  @override
  String get msgCount => 'Messages';

  @override
  String get headsCount => 'Heads';

  @override
  String get missingCount => 'Missing';

  @override
  String get headSeq => 'Head seq';

  @override
  String get p2pPeers => 'P2P peers';

  @override
  String get chatCapable => 'chat-capable';

  @override
  String get plainBtClient => 'plain BT client';

  @override
  String createdBy(Object date, Object name) {
    return 'Created $date · by $name';
  }

  @override
  String get noBtTasks => 'No tasks';

  @override
  String get noBtTasksHint =>
      'Use the + button to add magnets or .torrent files';

  @override
  String get addMagnet => 'Add torrent';

  @override
  String get importTorrent => 'Import .torrent file';

  @override
  String get added => 'Added';

  @override
  String get addedTorrentFile => 'Torrent file added';

  @override
  String get magnetCopied => 'Magnet link copied';

  @override
  String get copyMagnet => 'Copy magnet link';

  @override
  String get pause => 'Pause';

  @override
  String get resume => 'Resume';

  @override
  String get recheck => 'Recheck';

  @override
  String deleteTaskQ(Object name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get deleteTaskHint =>
      'Choose whether downloaded files are deleted too.';

  @override
  String get deleteTaskOnly => 'Remove task only';

  @override
  String get deleteTaskFiles => 'Remove task + files';

  @override
  String get stateSeeding => 'Seeding';

  @override
  String get stateDownloading => 'Downloading';

  @override
  String get stateMetadata => 'Fetching metadata…';

  @override
  String get stateChecking => 'Checking';

  @override
  String get stateFinished => 'Finished';

  @override
  String get stateQueued => 'Queued';

  @override
  String get statePaused => 'Paused';

  @override
  String get showChatTorrents => 'Show chat-internal torrents';

  @override
  String get hideChatTorrents => 'Hide chat-internal torrents';

  @override
  String get rateLimits => 'Rate limits';

  @override
  String get rateLimitsHint => 'Rate limits (KB/s, empty or 0 = unlimited)';

  @override
  String get upload => 'Upload';

  @override
  String get download => 'Download';

  @override
  String get limitsApplied => 'Limits applied';

  @override
  String filesCount(Object n) {
    return 'Files ($n)';
  }

  @override
  String peersCount(Object n) {
    return 'Connected peers ($n)';
  }

  @override
  String get noPeers => 'No peers';

  @override
  String get noMetadata => 'Metadata not available yet';

  @override
  String savePath(Object p) {
    return 'Save path: $p';
  }

  @override
  String get noFeeds => 'No feeds yet';

  @override
  String get noFeedsHint =>
      'RSS 2.0 & Atom supported; entries with magnets/torrents can go straight to BT';

  @override
  String get addFeed => 'Add feed';

  @override
  String get feedAdded => 'Added, fetching in background…';

  @override
  String get refreshingAll => 'Refreshing all feeds';

  @override
  String get markAllRead => 'Mark all read';

  @override
  String get unreadOnly => 'Unread only';

  @override
  String get showAll => 'Show all';

  @override
  String get noItems => 'No items (fetch may still be running)';

  @override
  String get noUnread => 'No unread items';

  @override
  String get untitled => '(untitled)';

  @override
  String get downloadToBt => 'Send to BT';

  @override
  String get queuedBt => 'Queued; see the Torrents tab shortly';

  @override
  String get addedQueue => 'Added to download queue';

  @override
  String get article => 'Article';

  @override
  String get openBrowser => 'Open in browser';

  @override
  String get hasBtResource => 'This entry ships a BT resource';

  @override
  String get noContent => '(no content)';

  @override
  String lastFetch(Object t) {
    return 'Last fetch $t';
  }

  @override
  String get notFetched => 'Not fetched yet';

  @override
  String deleteFeedQ(Object name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get deleteFeedHint => 'All cached items of this feed are deleted too.';

  @override
  String get coreVersion => 'Core version';

  @override
  String get dataDir => 'Data directory';

  @override
  String get msgSecurity => 'Message security';

  @override
  String get msgSecurityDesc =>
      'Every message is signed with your Ed25519 key and links its parents (git-style hash chain).';

  @override
  String get privKeyLocal => 'Private keys never leave this device.';

  @override
  String get aboutDesc =>
      'Decentralized BitTorrent group chat: one torrent = one group;';

  @override
  String get aboutDesc2 =>
      'messages are stored and spread as hash chains over BT/DHT — no single point can tamper.\n\n';

  @override
  String get appearance => 'Appearance';

  @override
  String get themeSystem => 'System';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get seedSource => 'Theme seed source';

  @override
  String get seedBrand => 'Brand blue';

  @override
  String get seedWallpaper => 'Wallpaper auto-extract';

  @override
  String get seedCustom => 'Custom color';

  @override
  String get pickColor => 'Pick a theme color';

  @override
  String get wallpaper => 'Chat wallpaper';

  @override
  String get wallpaperNone => 'Not set';

  @override
  String wallpaperSet(Object p) {
    return 'Opacity $p%';
  }

  @override
  String get wallpaperBlur => 'Blur wallpaper';

  @override
  String get opacity => 'Opacity';

  @override
  String get pickWallpaper => 'Pick a wallpaper';

  @override
  String get wallpaperApplied =>
      'Wallpaper applied; theme seed updates if set to wallpaper';

  @override
  String get filterRules => 'Message filter rules';

  @override
  String get addRule => 'Add rule';

  @override
  String get editRule => 'Edit rule';

  @override
  String get add => 'Add';

  @override
  String get noRules =>
      'No rules. Block malicious messages by name/key/content;';

  @override
  String get noRules2 => 'blocked messages collapse in chat.';

  @override
  String get fieldText => 'Message text';

  @override
  String get fieldName => 'Author name';

  @override
  String get fieldPk => 'Author key';

  @override
  String get modeContains => 'contains';

  @override
  String get modeEquals => 'equals';

  @override
  String get modeRegex => 'regex';

  @override
  String get matchValue => 'Match value';

  @override
  String get caseSensitive => 'Case sensitive';

  @override
  String get caseSensitiveMark => ' · case-sensitive';

  @override
  String get clear => 'Clear';

  @override
  String get today => 'Today';

  @override
  String get yesterday => 'Yesterday';

  @override
  String get mon => 'Monday';

  @override
  String get tue => 'Tuesday';

  @override
  String get wed => 'Wednesday';

  @override
  String get thu => 'Thursday';

  @override
  String get fri => 'Friday';

  @override
  String get sat => 'Saturday';

  @override
  String get sun => 'Sunday';

  @override
  String get videoFail => 'Cannot play this video';

  @override
  String get tapPlayVideo => 'Tap to play video';

  @override
  String get previewText => 'Preview text';

  @override
  String get openWith => 'Open with another app';

  @override
  String get noAppForFile => 'No app can open this file';

  @override
  String get fileTooBig => 'File > 2MB; use \"open with another app\"';

  @override
  String get notPlainText => 'Not a plain-text file';

  @override
  String get kindImage => 'Image';

  @override
  String get kindAudio => 'Audio';

  @override
  String get kindVideo => 'Video';

  @override
  String get kindText => 'Text';

  @override
  String get kindFile => 'File';

  @override
  String get pickFileToSend => 'Pick a file to send';

  @override
  String get pausedMark => ' · paused';

  @override
  String get blurredMark => ' · blurred';

  @override
  String tasksCount(Object n) {
    return '$n tasks';
  }

  @override
  String get editName => 'Nickname';

  @override
  String pubkeyLabel(Object pk) {
    return 'Key $pk';
  }

  @override
  String get identity => 'Identity';

  @override
  String onlinePeers(Object n) {
    return '$n online';
  }

  @override
  String get chatCapableMark => ' · chat-capable';

  @override
  String coreVersionValue(Object v, Object e) {
    return '$v · engine: $e';
  }

  @override
  String torrentError(Object e) {
    return 'Torrent error: $e';
  }

  @override
  String rssError(Object e) {
    return 'Feed error: $e';
  }

  @override
  String get downloaded => 'downloaded';

  @override
  String attMeta(Object size, Object tail) {
    return '$size · $tail';
  }

  @override
  String dlProgress(Object pct, Object rate, Object peers) {
    return '$pct% · $rate · $peers peers';
  }

  @override
  String sigState(Object s) {
    return 'State: $s';
  }

  @override
  String filterRuleDesc(Object field, Object mode, Object value) {
    return '$field $mode “$value”';
  }

  @override
  String get errDmSelf => 'You cannot DM yourself';

  @override
  String get errNoKeyInfo =>
      'No key material for this peer yet: receive at least one message from them in a shared group first';

  @override
  String get errNameLen => 'Nickname must be 1..32 characters';

  @override
  String get errGroupNameLen => 'Group name must be 1..96 bytes';

  @override
  String get errUrlScheme => 'URL must start with http(s)://';

  @override
  String get errManifestProtected =>
      'This is a group manifest; leave the group from the Chats tab instead';

  @override
  String get errNoResource => 'This entry has no downloadable resource';

  @override
  String get errTextEmpty => 'Empty or too long (≤32KB)';

  @override
  String get fabGroup => 'Torrent room';

  @override
  String get inviteLink => 'Invite link (channel magnet)';

  @override
  String get copyInviteLink => 'Copy invite magnet';

  @override
  String get groupChat => 'Group chat';

  @override
  String get identities => 'Identities';

  @override
  String get identitiesHint =>
      'Each nickname binds one private key: renaming means a NEW identity. Deleted keys cannot be recovered.';

  @override
  String get currentIdentity => 'Current identity';

  @override
  String get createIdentity => 'New identity';

  @override
  String get newIdentityName => 'New identity nickname';

  @override
  String get createIdentityWarn =>
      'A brand-new Ed25519 key is generated: future messages sign as the new identity; the old one\'s history stays.';

  @override
  String get switchIdentity => 'Switch identity';

  @override
  String switchIdentityQ(Object name) {
    return 'Switch to \"$name\"?';
  }

  @override
  String get switchIdentityHint =>
      'After switching, new messages are signed with that identity\'s key (like speaking under another nickname).';

  @override
  String switched(Object name) {
    return 'Switched to \"$name\"';
  }

  @override
  String get deleteIdentity => 'Delete identity';

  @override
  String deleteIdentityQ(Object name) {
    return 'Permanently delete identity \"$name\"?';
  }

  @override
  String get deleteIdentityWarn =>
      'The private key is destroyed and cannot be recovered. Past messages remain on-chain but you can no longer post as it.';

  @override
  String identityCreated(Object name) {
    return 'Identity \"$name\" created (not active)';
  }

  @override
  String identityCreatedSwitch(Object name) {
    return 'Identity \"$name\" created and activated';
  }

  @override
  String get identityDeleted => 'Identity deleted';

  @override
  String get activeMark => 'active';

  @override
  String get errIdentityActive => 'Cannot delete the active identity';

  @override
  String get errIdentityLast => 'At least one identity must remain';

  @override
  String get errNameLen2 => 'Nickname must be 1..32 characters';

  @override
  String get setAvatar => 'Change avatar';

  @override
  String get enterRoomTitle => 'Enter torrent chat room';

  @override
  String get roomInputLabel => 'Magnet link / info hash';

  @override
  String get magnetHashHint =>
      'magnet:?xt=urn:btih:… or a bare 40-hex info hash';

  @override
  String get enterRoom => 'Enter chat room';

  @override
  String get enterRoomNew => 'Enter this torrent\'s chat room';

  @override
  String get addTorrentRoom => 'Add torrent & enter chat';

  @override
  String get addTorrentRoomDesc =>
      'Paste a magnet link or info hash: adds the torrent and opens its chat room';

  @override
  String get importTorrentRoomDesc =>
      'Pick a .torrent file: adds the task and enters its chat room';

  @override
  String roomEntered(Object name) {
    return 'Entered chat room “$name”';
  }

  @override
  String get torrentRoomKind =>
      'Torrent chat room · shared with every BitTorrent peer of this torrent';

  @override
  String get dmChannelKind => 'End-to-end encrypted DM channel';

  @override
  String get infohashLabel => 'Torrent infohash';

  @override
  String get roomInviteTitle => 'Invite = share this torrent';

  @override
  String get roomInviteHint =>
      'Send the magnet link or info hash to anyone; adding the torrent enters the same room';

  @override
  String get leaveRoomHint =>
      'Only unbinds the chat room; the torrent task stays on the Torrents page. You can also delete the local history (a chain reset).';

  @override
  String get network => 'Network';

  @override
  String get defaultTrackers => 'Default trackers';

  @override
  String get defaultTrackersNone => 'Not set (DHT/PEX discovery only)';

  @override
  String defaultTrackersSet(Object n) {
    return '$n configured · auto-applied to new tasks';
  }

  @override
  String get defaultTrackersHint =>
      'One announce URL per line (http/https/udp). Auto-appended to every new torrent (chat attachments included) and applied to existing tasks immediately; greatly improves connectivity where DHT alone struggles.';

  @override
  String trackersApplied(Object n) {
    return 'Saved and applied to $n tasks';
  }

  @override
  String trackers(Object n) {
    return 'Trackers ($n)';
  }

  @override
  String get addTracker => 'Add tracker';

  @override
  String get trackerUrl => 'Tracker URL';

  @override
  String get noTrackersHint =>
      'No trackers: relying on DHT/PEX. Configure default trackers under Settings → Network';

  @override
  String trackerFails(Object n) {
    return '$n fails';
  }

  @override
  String get accept => 'Accept';

  @override
  String get decline => 'Decline';

  @override
  String get wallpaperEdit => 'Adjust wallpaper';

  @override
  String get wallpaperEditHint =>
      'Pinch and drag to frame the image; the controls below preview the final look';

  @override
  String get wallpaperLoadFail => 'Could not load the image';

  @override
  String get exportLogs => 'Export logs';

  @override
  String get exportLogsHint =>
      'Writes the core + UI logs to the Download directory for bug reports';

  @override
  String logsExported(Object dest) {
    return 'Logs exported: $dest';
  }

  @override
  String get exportLogsFail => 'Export failed: ';

  @override
  String get videoDecoder => 'Video decoding';

  @override
  String get videoDecoderSoftware => 'Software (compatibility first)';

  @override
  String get videoDecoderHardware => 'Hardware first (battery saver)';

  @override
  String get videoDecoderHint =>
      'Keep software decoding if videos play audio with a black picture; hardware decoding saves battery but renders black on some device/codec combinations. Applies to newly opened videos';

  @override
  String get videoDecoderTip =>
      'Playback failed? Use \"Open with\" and report it via Settings → Export logs';

  @override
  String get avatarLocalOnly =>
      'Avatar and nickname stay on this device and are never broadcast';

  @override
  String get renameLocalNote => 'Local note — only visible to you';

  @override
  String get dmRequestTitle => 'Private chat request';

  @override
  String dmRequestBody(Object name) {
    return '$name wants to start an end-to-end encrypted private chat';
  }

  @override
  String get dmRequestBodyAnonymous =>
      'Someone wants to start an end-to-end encrypted private chat';

  @override
  String get dmRejectedByPeer => 'The other side declined the private chat';

  @override
  String get dmAwaitingAccept => 'Waiting for accept';

  @override
  String get dmRequestSent => 'Request sent';

  @override
  String get dmRequestQueued =>
      'Peer is offline — the request will be delivered when they return';

  @override
  String get dmAlreadyExists => 'Private chat already exists';

  @override
  String get dmOnline => 'Online';

  @override
  String get dmOffline => 'Offline';

  @override
  String get dmLocalOnlyHint =>
      'DM messages travel directly between the two devices and are stored locally only: no DHT items, no extra torrent';

  @override
  String get membersIdentified => 'Members (DM capable)';

  @override
  String get attPhaseHash => 'Hashing file…';

  @override
  String get attPhaseCopy => 'Copying into the seed folder…';

  @override
  String get attPhaseSeed => 'Seeding and sending…';

  @override
  String get attachFailed => 'Attachment failed';

  @override
  String get videoDecoderHardwareOnly =>
      'Hardware decoding (MediaCodec) · failures are reported explicitly';

  @override
  String get dmRequestSubtitle => 'wants to start a private chat';

  @override
  String get block => 'Block';

  @override
  String get dmBlocked => 'User blocked';

  @override
  String get storage => 'Storage';

  @override
  String get downloadDir => 'Download directory';

  @override
  String get downloadDirHint =>
      'New tasks and received attachments go here; existing tasks keep their location';

  @override
  String get downloadDirPick => 'Pick folder';

  @override
  String get downloadDirReset => 'Reset to default';

  @override
  String get downloadDirSaved => 'Download directory updated';

  @override
  String get filterScript => 'Filter script';

  @override
  String get filterScriptHint =>
      'Edit, import or export the filter rule script (JSON). Rules match locally on content/nickname/pubkey × contains/equals/regex';

  @override
  String get filterScriptApply => 'Apply';

  @override
  String filterScriptApplied(Object n) {
    return 'Filter script applied ($n rules)';
  }

  @override
  String get filterScriptInvalid => 'Invalid script format';

  @override
  String get importFile => 'Import';

  @override
  String get exportFile => 'Export';

  @override
  String get rotate => 'Rotate 90°';

  @override
  String get wallpaperBlurOff => 'Off';

  @override
  String get wallpaperPadding => 'Padding fill';

  @override
  String get wallpaperPaddingTransparent => 'Transparent';

  @override
  String get wallpaperPaddingBlack => 'Black';

  @override
  String get wallpaperPaddingWhite => 'White';

  @override
  String get wallpaperPaddingExtend => 'Extend edges';

  @override
  String get wallpaperEditGestureHint =>
      'Drag to move · pinch to zoom & rotate · double-tap to reset';

  @override
  String get wallpaperCropHint =>
      'The canvas is wider than the screen: the saved image is cropped to the screen ratio, so only the dashed area is finally visible';

  @override
  String get wallpaperPaddingExtendHint =>
      'The margin is filled by extending the picture\'s outermost pixels';

  @override
  String get videoDecoderChainNote =>
      'Decode ladder: zero-copy hw → hw read-back → software (a stalled picture downgrades automatically and the working rung is remembered)';

  @override
  String get videoDecoderSwActive => 'software rendering';

  @override
  String get deleteLocalHistory => 'Also delete local history';

  @override
  String get deleteLocalHistoryHint =>
      'Wipes this device\'s messages and DAG heads (the reset path after joining the wrong hash chain). Re-entering the same torrent re-syncs from the DHT and online members.';

  @override
  String videoDecoderSwitch(Object tier) {
    return 'Switched to the “$tier” decoder';
  }
}
