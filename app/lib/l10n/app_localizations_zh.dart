// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get chatTab => '聊天';

  @override
  String get btTab => '种子';

  @override
  String get rssTab => '订阅';

  @override
  String get settings => '设置';

  @override
  String get identitySettings => '身份设置';

  @override
  String get demoMode => '演示模式';

  @override
  String get demoHint =>
      '未加载 libbitte_core.so。\n请安装 CI 构建的 Android APK 以启用完整功能。';

  @override
  String get coreUnavailable => '原生核心不可用（当前为演示模式）';

  @override
  String get coreUnavailableShort => '原生核心不可用（演示模式）';

  @override
  String get installApkHint => '原生核心不可用：请安装 CI 构建的 APK';

  @override
  String get noGroups => '还没有群聊';

  @override
  String get noGroupsHint => '一个 BT 种子就是一个群。\n创建群聊，或粘贴邀请磁力链接加入。';

  @override
  String get createGroup => '创建群聊';

  @override
  String get joinGroup => '加入群聊';

  @override
  String get groupName => '群名称';

  @override
  String get groupNameHint => '例如：BT 爱好者';

  @override
  String get create => '创建';

  @override
  String get join => '加入';

  @override
  String get cancel => '取消';

  @override
  String get confirm => '确定';

  @override
  String get save => '保存';

  @override
  String get delete => '删除';

  @override
  String get refresh => '刷新';

  @override
  String get refreshAll => '全部刷新';

  @override
  String get paste => '粘贴';

  @override
  String get copyLink => '复制链接';

  @override
  String get done => '完成';

  @override
  String get inviteMagnet => '邀请磁力链接';

  @override
  String get magnetHint => 'magnet:?xt=urn:btih:...';

  @override
  String get alreadyInGroup => '已经在该群中';

  @override
  String get fetchingManifest => '正在从 BT 网络获取群清单……需要群内有成员在线做种';

  @override
  String get groupCreated => '群聊已创建 🎉';

  @override
  String get inviteHint => '把邀请链接发给朋友（对方需能连上你或任一在线成员的种子网络）';

  @override
  String get joinViaPaste => '粘贴或扫描他人分享的邀请链接';

  @override
  String get createGroupDesc => '生成邀请磁力链接，分享给朋友';

  @override
  String get online => '在线';

  @override
  String get noMessages => '暂无消息';

  @override
  String syncingMissing(Object n) {
    return '同步中：缺 $n 条历史消息';
  }

  @override
  String historySynced(Object n) {
    return '历史已同步 · $n 节点在线';
  }

  @override
  String get dmEncrypted => '端到端加密私聊（X25519 + ChaCha20-Poly1305）';

  @override
  String get resync => '重新同步';

  @override
  String get resyncStarted => '已向 DHT 与相邻节点发起同步';

  @override
  String get groupDetail => '群详情';

  @override
  String genesisTitle(Object name) {
    return '「$name」的哈希链从这里开始';
  }

  @override
  String get genesisSub => '每条消息都经作者签名并链接前序消息，任何篡改都会被网络拒绝';

  @override
  String get emptyGroupHint => '群刚创建，还没有消息\n说点什么吧 👇';

  @override
  String get inputHint => '说点什么……（消息将签名并写入哈希链）';

  @override
  String get sendFileTip => '发送文件（做种）';

  @override
  String get sending => '正在做种并发送……';

  @override
  String sentSeeding(Object h) {
    return '已发送，正在做种：$h';
  }

  @override
  String get downloadViaBt => '通过 BT 下载';

  @override
  String downloadStarted(Object name) {
    return '已开始下载「$name」（聊天内传输，不占用种子页）';
  }

  @override
  String get anonymous => '匿名';

  @override
  String get copyMessage => '复制消息内容';

  @override
  String get copyMessageId => '复制消息 ID（SHA-1）';

  @override
  String get copied => '已复制';

  @override
  String get copiedId => '已复制消息 ID';

  @override
  String get copiedInvite => '已复制：对方在聊天页「加入群聊」粘贴即可';

  @override
  String get signatureInfo => '签名信息';

  @override
  String sigDetail(Object pk, Object state) {
    return '作者公钥 $pk\n状态 $state';
  }

  @override
  String get sigConfirmed => '已确认（DHT 已存储）';

  @override
  String get sigPending => '待确认';

  @override
  String get blockAuthor => '屏蔽该作者';

  @override
  String get blockAuthorHint => '加入过滤规则（可在设置中管理）';

  @override
  String blockedAuthor(Object name) {
    return '已屏蔽 $name';
  }

  @override
  String blockedCount(Object n) {
    return '$n 条被屏蔽的消息';
  }

  @override
  String get startDm => '发起私聊';

  @override
  String startDmHint(Object name) {
    return '与 $name 的端到端加密频道';
  }

  @override
  String sysCreate(Object name, Object detail) {
    return '🎉 $name 创建了群聊「$detail」';
  }

  @override
  String sysJoin(Object name) {
    return '👋 $name 加入了群聊';
  }

  @override
  String sysLeave(Object name) {
    return '$name 退出了群聊';
  }

  @override
  String sysRename(Object name, Object detail) {
    return '📛 $name 将群名改为「$detail」';
  }

  @override
  String get sysDmInvite => '发来了私聊邀请（自动加入）';

  @override
  String sysGeneric(Object code, Object detail) {
    return '[系统] $code $detail';
  }

  @override
  String get sysMsg => '系统消息';

  @override
  String get chunkSyncing => '〔长消息分块同步中…〕';

  @override
  String get renameGroup => '修改群名';

  @override
  String get renameBroadcast => '以签名系统消息广播给全群';

  @override
  String get leaveGroup => '退出群聊（保留本地历史）';

  @override
  String get leaveGroupQ => '退出群聊？';

  @override
  String get leaveGroupHint => '将停止做种群清单，本地聊天记录默认保留。';

  @override
  String get leave => '退出';

  @override
  String get members => '在线成员';

  @override
  String get manifestTorrent => '清单种子';

  @override
  String get msgCount => '消息总数';

  @override
  String get headsCount => '链头 (heads)';

  @override
  String get missingCount => '缺失历史';

  @override
  String get headSeq => '头指针版本 (seq)';

  @override
  String get p2pPeers => 'P2P 节点';

  @override
  String get chatCapable => '支持聊天';

  @override
  String get plainBtClient => '普通 BT 客户端';

  @override
  String createdBy(Object date, Object name) {
    return '创建于 $date · 创建者 $name';
  }

  @override
  String get noBtTasks => '暂无任务';

  @override
  String get noBtTasksHint => '点击右下角按钮添加磁力链接或种子文件';

  @override
  String get addMagnet => '添加磁力链接';

  @override
  String get importTorrent => '导入种子文件 (.torrent)';

  @override
  String get added => '已添加';

  @override
  String get addedTorrentFile => '已添加种子文件';

  @override
  String get magnetCopied => '磁力链接已复制';

  @override
  String get copyMagnet => '复制磁力链接';

  @override
  String get pause => '暂停';

  @override
  String get resume => '继续';

  @override
  String get recheck => '重新校验';

  @override
  String deleteTaskQ(Object name) {
    return '删除「$name」？';
  }

  @override
  String get deleteTaskHint => '选择是否同时删除已下载的文件。';

  @override
  String get deleteTaskOnly => '仅删除任务';

  @override
  String get deleteTaskFiles => '删除任务+文件';

  @override
  String get stateSeeding => '做种中';

  @override
  String get stateDownloading => '下载中';

  @override
  String get stateMetadata => '获取元数据…';

  @override
  String get stateChecking => '校验中';

  @override
  String get stateFinished => '已完成';

  @override
  String get stateQueued => '排队中';

  @override
  String get statePaused => '已暂停';

  @override
  String get showChatTorrents => '显示聊天内部种子';

  @override
  String get hideChatTorrents => '隐藏聊天内部种子';

  @override
  String get rateLimits => '传输限速';

  @override
  String get rateLimitsHint => '传输限速（KB/s，留空或 0 为不限速）';

  @override
  String get upload => '上传';

  @override
  String get download => '下载';

  @override
  String get limitsApplied => '限速已应用';

  @override
  String filesCount(Object n) {
    return '文件（$n）';
  }

  @override
  String peersCount(Object n) {
    return '连接节点（$n）';
  }

  @override
  String get noPeers => '暂无连接';

  @override
  String get noMetadata => '元数据尚未获取';

  @override
  String savePath(Object p) {
    return '保存目录: $p';
  }

  @override
  String get noFeeds => '还没有订阅';

  @override
  String get noFeedsHint => '支持 RSS 2.0 与 Atom；含磁力/种子的条目可一键转 BT 下载';

  @override
  String get addFeed => '添加订阅';

  @override
  String get feedAdded => '已添加，正在后台抓取……';

  @override
  String get refreshingAll => '正在刷新全部订阅';

  @override
  String get markAllRead => '全部标记已读';

  @override
  String get unreadOnly => '只看未读';

  @override
  String get showAll => '显示全部';

  @override
  String get noItems => '暂无条目（可能仍在抓取）';

  @override
  String get noUnread => '没有未读条目';

  @override
  String get untitled => '(无标题)';

  @override
  String get downloadToBt => '转 BT 下载';

  @override
  String get queuedBt => '已开始后台处理，稍后见种子页';

  @override
  String get addedQueue => '已加入下载队列';

  @override
  String get article => '正文';

  @override
  String get openBrowser => '浏览器打开';

  @override
  String get hasBtResource => '此条目附带 BT 资源';

  @override
  String get noContent => '（无正文）';

  @override
  String lastFetch(Object t) {
    return '上次更新 $t';
  }

  @override
  String get notFetched => '尚未抓取';

  @override
  String deleteFeedQ(Object name) {
    return '删除「$name」？';
  }

  @override
  String get deleteFeedHint => '将同时删除该源的全部已缓存条目。';

  @override
  String get coreVersion => '核心版本';

  @override
  String get dataDir => '数据目录';

  @override
  String get msgSecurity => '消息安全';

  @override
  String get msgSecurityDesc => '每条消息使用你的 Ed25519 密钥签名并链接父消息（git 式哈希链）。';

  @override
  String get privKeyLocal => '私钥仅保存在本机，永不外传。';

  @override
  String get aboutDesc => '去中心化 BitTorrent 群聊：一个种子就是一个群，';

  @override
  String get aboutDesc2 => '消息以哈希链方式在 BT/DHT 网络中保存与传播，无法被单点篡改。\n\n';

  @override
  String get appearance => '外观';

  @override
  String get themeSystem => '跟随系统';

  @override
  String get themeLight => '浅色';

  @override
  String get themeDark => '深色';

  @override
  String get seedSource => '主题色来源';

  @override
  String get seedBrand => '品牌蓝';

  @override
  String get seedWallpaper => '壁纸自动取色';

  @override
  String get seedCustom => '自定义颜色';

  @override
  String get pickColor => '选择主题色';

  @override
  String get wallpaper => '聊天背景图';

  @override
  String get wallpaperNone => '未设置';

  @override
  String wallpaperSet(Object p) {
    return '不透明度 $p%';
  }

  @override
  String get wallpaperBlur => '背景模糊';

  @override
  String get opacity => '不透明度';

  @override
  String get pickWallpaper => '选择聊天背景图';

  @override
  String get wallpaperApplied => '背景已应用；若主题色来源为\"壁纸取色\"将同时更新';

  @override
  String get filterRules => '消息过滤规则';

  @override
  String get addRule => '添加过滤规则';

  @override
  String get editRule => '编辑过滤规则';

  @override
  String get add => '添加';

  @override
  String get noRules => '无规则。可按昵称/公钥/内容屏蔽恶意消息；';

  @override
  String get noRules2 => '被屏蔽消息在聊天中折叠显示。';

  @override
  String get fieldText => '消息内容';

  @override
  String get fieldName => '作者昵称';

  @override
  String get fieldPk => '作者公钥';

  @override
  String get modeContains => '包含';

  @override
  String get modeEquals => '等于';

  @override
  String get modeRegex => '正则表达式';

  @override
  String get matchValue => '匹配值';

  @override
  String get caseSensitive => '区分大小写';

  @override
  String get caseSensitiveMark => ' · 区分大小写';

  @override
  String get clear => '清除';

  @override
  String get today => '今天';

  @override
  String get yesterday => '昨天';

  @override
  String get mon => '星期一';

  @override
  String get tue => '星期二';

  @override
  String get wed => '星期三';

  @override
  String get thu => '星期四';

  @override
  String get fri => '星期五';

  @override
  String get sat => '星期六';

  @override
  String get sun => '星期日';

  @override
  String get videoFail => '无法播放该视频';

  @override
  String get tapPlayVideo => '点击播放视频';

  @override
  String get previewText => '预览文本';

  @override
  String get openWith => '用其他应用打开';

  @override
  String get noAppForFile => '没有可打开该文件的应用';

  @override
  String get fileTooBig => '文件超过 2MB，请使用“其他应用打开”';

  @override
  String get notPlainText => '该文件不是纯文本';

  @override
  String get kindImage => '图片';

  @override
  String get kindAudio => '音频';

  @override
  String get kindVideo => '视频';

  @override
  String get kindText => '文本';

  @override
  String get kindFile => '文件';

  @override
  String get pickFileToSend => '选择要发送的文件';

  @override
  String get pausedMark => ' · 已暂停';

  @override
  String get blurredMark => ' · 已模糊';

  @override
  String tasksCount(Object n) {
    return '$n 任务';
  }

  @override
  String get editName => '昵称';

  @override
  String pubkeyLabel(Object pk) {
    return '公钥 $pk';
  }

  @override
  String get identity => '身份';

  @override
  String onlinePeers(Object n) {
    return '$n 在线';
  }

  @override
  String get chatCapableMark => ' · 支持聊天';

  @override
  String coreVersionValue(Object v, Object e) {
    return '$v · 引擎: $e';
  }

  @override
  String torrentError(Object e) {
    return '种子出错：$e';
  }

  @override
  String rssError(Object e) {
    return '订阅失败：$e';
  }

  @override
  String get downloaded => '已下载';

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
    return '状态 $s';
  }

  @override
  String filterRuleDesc(Object field, Object mode, Object value) {
    return '$field $mode “$value”';
  }

  @override
  String get errDmSelf => '不能和自己私聊';

  @override
  String get errNoKeyInfo => '还没有对方的密钥信息：先在同群聊里收到 TA 至少一条消息';

  @override
  String get errNameLen => '昵称长度需在 1..32 字符';

  @override
  String get errGroupNameLen => '群名长度需在 1..96 字节';

  @override
  String get errUrlScheme => 'URL 必须以 http(s):// 开头';

  @override
  String get errManifestProtected => '这是群聊清单种子，请通过聊天页退群来移除';

  @override
  String get errNoResource => '该条目没有可下载的资源';

  @override
  String get errTextEmpty => '空消息或过长（≤32KB）';

  @override
  String get fabGroup => '群聊';

  @override
  String get inviteLink => '邀请链接';

  @override
  String get copyInviteLink => '复制磁力邀请链接';

  @override
  String get groupChat => '群聊';
}
