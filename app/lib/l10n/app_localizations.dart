import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh')
  ];

  /// No description provided for @chatTab.
  ///
  /// In zh, this message translates to:
  /// **'聊天'**
  String get chatTab;

  /// No description provided for @btTab.
  ///
  /// In zh, this message translates to:
  /// **'种子'**
  String get btTab;

  /// No description provided for @rssTab.
  ///
  /// In zh, this message translates to:
  /// **'订阅'**
  String get rssTab;

  /// No description provided for @settings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get settings;

  /// No description provided for @identitySettings.
  ///
  /// In zh, this message translates to:
  /// **'身份设置'**
  String get identitySettings;

  /// No description provided for @demoMode.
  ///
  /// In zh, this message translates to:
  /// **'演示模式'**
  String get demoMode;

  /// No description provided for @demoHint.
  ///
  /// In zh, this message translates to:
  /// **'未加载 libbitte_core.so。\n请安装 CI 构建的 Android APK 以启用完整功能。'**
  String get demoHint;

  /// No description provided for @coreUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'原生核心不可用（当前为演示模式）'**
  String get coreUnavailable;

  /// No description provided for @coreUnavailableShort.
  ///
  /// In zh, this message translates to:
  /// **'原生核心不可用（演示模式）'**
  String get coreUnavailableShort;

  /// No description provided for @installApkHint.
  ///
  /// In zh, this message translates to:
  /// **'原生核心不可用：请安装 CI 构建的 APK'**
  String get installApkHint;

  /// No description provided for @noGroups.
  ///
  /// In zh, this message translates to:
  /// **'还没有种子群聊'**
  String get noGroups;

  /// No description provided for @noGroupsHint.
  ///
  /// In zh, this message translates to:
  /// **'一个种子就是一个群聊。\n添加任意 BT 种子（磁力链接 / info hash / 种子文件），即可进入它的聊天室，与同一 swarm 里的其他 BitTorrent 用户交流。'**
  String get noGroupsHint;

  /// No description provided for @createGroup.
  ///
  /// In zh, this message translates to:
  /// **'创建群聊'**
  String get createGroup;

  /// No description provided for @joinGroup.
  ///
  /// In zh, this message translates to:
  /// **'加入群聊'**
  String get joinGroup;

  /// No description provided for @groupName.
  ///
  /// In zh, this message translates to:
  /// **'群名称'**
  String get groupName;

  /// No description provided for @groupNameHint.
  ///
  /// In zh, this message translates to:
  /// **'例如：BT 爱好者'**
  String get groupNameHint;

  /// No description provided for @create.
  ///
  /// In zh, this message translates to:
  /// **'创建'**
  String get create;

  /// No description provided for @join.
  ///
  /// In zh, this message translates to:
  /// **'加入'**
  String get join;

  /// No description provided for @cancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get cancel;

  /// No description provided for @confirm.
  ///
  /// In zh, this message translates to:
  /// **'确定'**
  String get confirm;

  /// No description provided for @save.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get save;

  /// No description provided for @delete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get delete;

  /// No description provided for @refresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get refresh;

  /// No description provided for @refreshAll.
  ///
  /// In zh, this message translates to:
  /// **'全部刷新'**
  String get refreshAll;

  /// No description provided for @paste.
  ///
  /// In zh, this message translates to:
  /// **'粘贴'**
  String get paste;

  /// No description provided for @copyLink.
  ///
  /// In zh, this message translates to:
  /// **'复制链接'**
  String get copyLink;

  /// No description provided for @done.
  ///
  /// In zh, this message translates to:
  /// **'完成'**
  String get done;

  /// No description provided for @inviteMagnet.
  ///
  /// In zh, this message translates to:
  /// **'邀请磁力链接'**
  String get inviteMagnet;

  /// No description provided for @magnetHint.
  ///
  /// In zh, this message translates to:
  /// **'magnet:?xt=urn:btih:...'**
  String get magnetHint;

  /// No description provided for @alreadyInGroup.
  ///
  /// In zh, this message translates to:
  /// **'已经在该群中'**
  String get alreadyInGroup;

  /// No description provided for @fetchingManifest.
  ///
  /// In zh, this message translates to:
  /// **'正在从 BT 网络获取群清单……需要群内有成员在线做种'**
  String get fetchingManifest;

  /// No description provided for @groupCreated.
  ///
  /// In zh, this message translates to:
  /// **'群聊已创建 🎉'**
  String get groupCreated;

  /// No description provided for @inviteHint.
  ///
  /// In zh, this message translates to:
  /// **'把邀请链接发给朋友（对方需能连上你或任一在线成员的种子网络）'**
  String get inviteHint;

  /// No description provided for @joinViaPaste.
  ///
  /// In zh, this message translates to:
  /// **'粘贴或扫描他人分享的邀请链接'**
  String get joinViaPaste;

  /// No description provided for @createGroupDesc.
  ///
  /// In zh, this message translates to:
  /// **'生成邀请磁力链接，分享给朋友'**
  String get createGroupDesc;

  /// No description provided for @online.
  ///
  /// In zh, this message translates to:
  /// **'在线'**
  String get online;

  /// No description provided for @noMessages.
  ///
  /// In zh, this message translates to:
  /// **'暂无消息'**
  String get noMessages;

  /// No description provided for @syncingMissing.
  ///
  /// In zh, this message translates to:
  /// **'同步中：缺 {n} 条历史消息'**
  String syncingMissing(Object n);

  /// No description provided for @historySynced.
  ///
  /// In zh, this message translates to:
  /// **'历史已同步 · {n} 节点在线'**
  String historySynced(Object n);

  /// No description provided for @dmEncrypted.
  ///
  /// In zh, this message translates to:
  /// **'端到端加密私聊（X25519 + ChaCha20-Poly1305）'**
  String get dmEncrypted;

  /// No description provided for @resync.
  ///
  /// In zh, this message translates to:
  /// **'重新同步'**
  String get resync;

  /// No description provided for @resyncStarted.
  ///
  /// In zh, this message translates to:
  /// **'已向 DHT 与相邻节点发起同步'**
  String get resyncStarted;

  /// No description provided for @groupDetail.
  ///
  /// In zh, this message translates to:
  /// **'群详情'**
  String get groupDetail;

  /// No description provided for @genesisTitle.
  ///
  /// In zh, this message translates to:
  /// **'「{name}」的哈希链从这里开始'**
  String genesisTitle(Object name);

  /// No description provided for @genesisSub.
  ///
  /// In zh, this message translates to:
  /// **'每条消息都经作者签名并链接前序消息，任何篡改都会被网络拒绝'**
  String get genesisSub;

  /// No description provided for @emptyGroupHint.
  ///
  /// In zh, this message translates to:
  /// **'还没有消息\n说点什么吧 👇'**
  String get emptyGroupHint;

  /// No description provided for @inputHint.
  ///
  /// In zh, this message translates to:
  /// **'说点什么……（消息将签名并写入哈希链）'**
  String get inputHint;

  /// No description provided for @sendFileTip.
  ///
  /// In zh, this message translates to:
  /// **'发送文件（做种）'**
  String get sendFileTip;

  /// No description provided for @sending.
  ///
  /// In zh, this message translates to:
  /// **'正在做种并发送……'**
  String get sending;

  /// No description provided for @sentSeeding.
  ///
  /// In zh, this message translates to:
  /// **'已发送，正在做种：{h}'**
  String sentSeeding(Object h);

  /// No description provided for @downloadViaBt.
  ///
  /// In zh, this message translates to:
  /// **'通过 BT 下载'**
  String get downloadViaBt;

  /// No description provided for @downloadStarted.
  ///
  /// In zh, this message translates to:
  /// **'已开始下载「{name}」（聊天内传输，不占用种子页）'**
  String downloadStarted(Object name);

  /// No description provided for @anonymous.
  ///
  /// In zh, this message translates to:
  /// **'匿名'**
  String get anonymous;

  /// No description provided for @copyMessage.
  ///
  /// In zh, this message translates to:
  /// **'复制消息内容'**
  String get copyMessage;

  /// No description provided for @copyMessageId.
  ///
  /// In zh, this message translates to:
  /// **'复制消息 ID（SHA-1）'**
  String get copyMessageId;

  /// No description provided for @copied.
  ///
  /// In zh, this message translates to:
  /// **'已复制'**
  String get copied;

  /// No description provided for @copiedId.
  ///
  /// In zh, this message translates to:
  /// **'已复制消息 ID'**
  String get copiedId;

  /// No description provided for @copiedInvite.
  ///
  /// In zh, this message translates to:
  /// **'已复制：对方添加这个种子即可进入同一群聊'**
  String get copiedInvite;

  /// No description provided for @signatureInfo.
  ///
  /// In zh, this message translates to:
  /// **'签名信息'**
  String get signatureInfo;

  /// No description provided for @sigDetail.
  ///
  /// In zh, this message translates to:
  /// **'作者公钥 {pk}\n状态 {state}'**
  String sigDetail(Object pk, Object state);

  /// No description provided for @sigConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'已确认（DHT 已存储）'**
  String get sigConfirmed;

  /// No description provided for @sigPending.
  ///
  /// In zh, this message translates to:
  /// **'待确认'**
  String get sigPending;

  /// No description provided for @blockAuthor.
  ///
  /// In zh, this message translates to:
  /// **'屏蔽该作者'**
  String get blockAuthor;

  /// No description provided for @blockAuthorHint.
  ///
  /// In zh, this message translates to:
  /// **'加入过滤规则（可在设置中管理）'**
  String get blockAuthorHint;

  /// No description provided for @blockedAuthor.
  ///
  /// In zh, this message translates to:
  /// **'已屏蔽 {name}'**
  String blockedAuthor(Object name);

  /// No description provided for @blockedCount.
  ///
  /// In zh, this message translates to:
  /// **'{n} 条被屏蔽的消息'**
  String blockedCount(Object n);

  /// No description provided for @startDm.
  ///
  /// In zh, this message translates to:
  /// **'发起私聊'**
  String get startDm;

  /// No description provided for @startDmHint.
  ///
  /// In zh, this message translates to:
  /// **'与 {name} 的端到端加密频道'**
  String startDmHint(Object name);

  /// No description provided for @sysCreate.
  ///
  /// In zh, this message translates to:
  /// **'🎉 {name} 创建了群聊「{detail}」'**
  String sysCreate(Object name, Object detail);

  /// No description provided for @sysJoin.
  ///
  /// In zh, this message translates to:
  /// **'👋 {name} 加入了群聊'**
  String sysJoin(Object name);

  /// No description provided for @sysLeave.
  ///
  /// In zh, this message translates to:
  /// **'{name} 退出了群聊'**
  String sysLeave(Object name);

  /// No description provided for @sysRename.
  ///
  /// In zh, this message translates to:
  /// **'📛 {name} 将群名改为「{detail}」'**
  String sysRename(Object name, Object detail);

  /// No description provided for @sysDmInvite.
  ///
  /// In zh, this message translates to:
  /// **'发来了私聊邀请（自动加入）'**
  String get sysDmInvite;

  /// No description provided for @sysGeneric.
  ///
  /// In zh, this message translates to:
  /// **'[系统] {code} {detail}'**
  String sysGeneric(Object code, Object detail);

  /// No description provided for @sysMsg.
  ///
  /// In zh, this message translates to:
  /// **'系统消息'**
  String get sysMsg;

  /// No description provided for @chunkSyncing.
  ///
  /// In zh, this message translates to:
  /// **'〔长消息分块同步中…〕'**
  String get chunkSyncing;

  /// No description provided for @renameGroup.
  ///
  /// In zh, this message translates to:
  /// **'修改群名'**
  String get renameGroup;

  /// No description provided for @renameBroadcast.
  ///
  /// In zh, this message translates to:
  /// **'以签名系统消息广播给全群'**
  String get renameBroadcast;

  /// No description provided for @leaveGroup.
  ///
  /// In zh, this message translates to:
  /// **'退出群聊（保留本地历史）'**
  String get leaveGroup;

  /// No description provided for @leaveGroupQ.
  ///
  /// In zh, this message translates to:
  /// **'退出群聊？'**
  String get leaveGroupQ;

  /// No description provided for @leaveGroupHint.
  ///
  /// In zh, this message translates to:
  /// **'将停止做种频道清单，本地聊天记录默认保留。'**
  String get leaveGroupHint;

  /// No description provided for @leave.
  ///
  /// In zh, this message translates to:
  /// **'退出'**
  String get leave;

  /// No description provided for @members.
  ///
  /// In zh, this message translates to:
  /// **'在线成员'**
  String get members;

  /// No description provided for @manifestTorrent.
  ///
  /// In zh, this message translates to:
  /// **'清单种子'**
  String get manifestTorrent;

  /// No description provided for @msgCount.
  ///
  /// In zh, this message translates to:
  /// **'消息总数'**
  String get msgCount;

  /// No description provided for @headsCount.
  ///
  /// In zh, this message translates to:
  /// **'链头 (heads)'**
  String get headsCount;

  /// No description provided for @missingCount.
  ///
  /// In zh, this message translates to:
  /// **'缺失历史'**
  String get missingCount;

  /// No description provided for @headSeq.
  ///
  /// In zh, this message translates to:
  /// **'头指针版本 (seq)'**
  String get headSeq;

  /// No description provided for @p2pPeers.
  ///
  /// In zh, this message translates to:
  /// **'P2P 节点'**
  String get p2pPeers;

  /// No description provided for @chatCapable.
  ///
  /// In zh, this message translates to:
  /// **'支持聊天'**
  String get chatCapable;

  /// No description provided for @plainBtClient.
  ///
  /// In zh, this message translates to:
  /// **'普通 BT 客户端'**
  String get plainBtClient;

  /// No description provided for @createdBy.
  ///
  /// In zh, this message translates to:
  /// **'创建于 {date} · 创建者 {name}'**
  String createdBy(Object date, Object name);

  /// No description provided for @noBtTasks.
  ///
  /// In zh, this message translates to:
  /// **'暂无任务'**
  String get noBtTasks;

  /// No description provided for @noBtTasksHint.
  ///
  /// In zh, this message translates to:
  /// **'点击右下角按钮添加磁力链接或种子文件'**
  String get noBtTasksHint;

  /// No description provided for @addMagnet.
  ///
  /// In zh, this message translates to:
  /// **'添加种子'**
  String get addMagnet;

  /// No description provided for @importTorrent.
  ///
  /// In zh, this message translates to:
  /// **'导入种子文件 (.torrent)'**
  String get importTorrent;

  /// No description provided for @added.
  ///
  /// In zh, this message translates to:
  /// **'已添加'**
  String get added;

  /// No description provided for @addedTorrentFile.
  ///
  /// In zh, this message translates to:
  /// **'已添加种子文件'**
  String get addedTorrentFile;

  /// No description provided for @magnetCopied.
  ///
  /// In zh, this message translates to:
  /// **'磁力链接已复制'**
  String get magnetCopied;

  /// No description provided for @copyMagnet.
  ///
  /// In zh, this message translates to:
  /// **'复制磁力链接'**
  String get copyMagnet;

  /// No description provided for @pause.
  ///
  /// In zh, this message translates to:
  /// **'暂停'**
  String get pause;

  /// No description provided for @resume.
  ///
  /// In zh, this message translates to:
  /// **'继续'**
  String get resume;

  /// No description provided for @recheck.
  ///
  /// In zh, this message translates to:
  /// **'重新校验'**
  String get recheck;

  /// No description provided for @deleteTaskQ.
  ///
  /// In zh, this message translates to:
  /// **'删除「{name}」？'**
  String deleteTaskQ(Object name);

  /// No description provided for @deleteTaskHint.
  ///
  /// In zh, this message translates to:
  /// **'选择是否同时删除已下载的文件。'**
  String get deleteTaskHint;

  /// No description provided for @deleteTaskOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅删除任务'**
  String get deleteTaskOnly;

  /// No description provided for @deleteTaskFiles.
  ///
  /// In zh, this message translates to:
  /// **'删除任务+文件'**
  String get deleteTaskFiles;

  /// No description provided for @stateSeeding.
  ///
  /// In zh, this message translates to:
  /// **'做种中'**
  String get stateSeeding;

  /// No description provided for @stateDownloading.
  ///
  /// In zh, this message translates to:
  /// **'下载中'**
  String get stateDownloading;

  /// No description provided for @stateMetadata.
  ///
  /// In zh, this message translates to:
  /// **'获取元数据…'**
  String get stateMetadata;

  /// No description provided for @stateChecking.
  ///
  /// In zh, this message translates to:
  /// **'校验中'**
  String get stateChecking;

  /// No description provided for @stateFinished.
  ///
  /// In zh, this message translates to:
  /// **'已完成'**
  String get stateFinished;

  /// No description provided for @stateQueued.
  ///
  /// In zh, this message translates to:
  /// **'排队中'**
  String get stateQueued;

  /// No description provided for @statePaused.
  ///
  /// In zh, this message translates to:
  /// **'已暂停'**
  String get statePaused;

  /// No description provided for @showChatTorrents.
  ///
  /// In zh, this message translates to:
  /// **'显示聊天内部种子'**
  String get showChatTorrents;

  /// No description provided for @hideChatTorrents.
  ///
  /// In zh, this message translates to:
  /// **'隐藏聊天内部种子'**
  String get hideChatTorrents;

  /// No description provided for @rateLimits.
  ///
  /// In zh, this message translates to:
  /// **'传输限速'**
  String get rateLimits;

  /// No description provided for @rateLimitsHint.
  ///
  /// In zh, this message translates to:
  /// **'传输限速（KB/s，留空或 0 为不限速）'**
  String get rateLimitsHint;

  /// No description provided for @upload.
  ///
  /// In zh, this message translates to:
  /// **'上传'**
  String get upload;

  /// No description provided for @download.
  ///
  /// In zh, this message translates to:
  /// **'下载'**
  String get download;

  /// No description provided for @limitsApplied.
  ///
  /// In zh, this message translates to:
  /// **'限速已应用'**
  String get limitsApplied;

  /// No description provided for @filesCount.
  ///
  /// In zh, this message translates to:
  /// **'文件（{n}）'**
  String filesCount(Object n);

  /// No description provided for @peersCount.
  ///
  /// In zh, this message translates to:
  /// **'连接节点（{n}）'**
  String peersCount(Object n);

  /// No description provided for @noPeers.
  ///
  /// In zh, this message translates to:
  /// **'暂无连接'**
  String get noPeers;

  /// No description provided for @noMetadata.
  ///
  /// In zh, this message translates to:
  /// **'元数据尚未获取'**
  String get noMetadata;

  /// No description provided for @savePath.
  ///
  /// In zh, this message translates to:
  /// **'保存目录: {p}'**
  String savePath(Object p);

  /// No description provided for @noFeeds.
  ///
  /// In zh, this message translates to:
  /// **'还没有订阅'**
  String get noFeeds;

  /// No description provided for @noFeedsHint.
  ///
  /// In zh, this message translates to:
  /// **'支持 RSS 2.0 与 Atom；含磁力/种子的条目可一键转 BT 下载'**
  String get noFeedsHint;

  /// No description provided for @addFeed.
  ///
  /// In zh, this message translates to:
  /// **'添加订阅'**
  String get addFeed;

  /// No description provided for @feedAdded.
  ///
  /// In zh, this message translates to:
  /// **'已添加，正在后台抓取……'**
  String get feedAdded;

  /// No description provided for @refreshingAll.
  ///
  /// In zh, this message translates to:
  /// **'正在刷新全部订阅'**
  String get refreshingAll;

  /// No description provided for @markAllRead.
  ///
  /// In zh, this message translates to:
  /// **'全部标记已读'**
  String get markAllRead;

  /// No description provided for @unreadOnly.
  ///
  /// In zh, this message translates to:
  /// **'只看未读'**
  String get unreadOnly;

  /// No description provided for @showAll.
  ///
  /// In zh, this message translates to:
  /// **'显示全部'**
  String get showAll;

  /// No description provided for @noItems.
  ///
  /// In zh, this message translates to:
  /// **'暂无条目（可能仍在抓取）'**
  String get noItems;

  /// No description provided for @noUnread.
  ///
  /// In zh, this message translates to:
  /// **'没有未读条目'**
  String get noUnread;

  /// No description provided for @untitled.
  ///
  /// In zh, this message translates to:
  /// **'(无标题)'**
  String get untitled;

  /// No description provided for @downloadToBt.
  ///
  /// In zh, this message translates to:
  /// **'转 BT 下载'**
  String get downloadToBt;

  /// No description provided for @queuedBt.
  ///
  /// In zh, this message translates to:
  /// **'已开始后台处理，稍后见种子页'**
  String get queuedBt;

  /// No description provided for @addedQueue.
  ///
  /// In zh, this message translates to:
  /// **'已加入下载队列'**
  String get addedQueue;

  /// No description provided for @article.
  ///
  /// In zh, this message translates to:
  /// **'正文'**
  String get article;

  /// No description provided for @openBrowser.
  ///
  /// In zh, this message translates to:
  /// **'浏览器打开'**
  String get openBrowser;

  /// No description provided for @hasBtResource.
  ///
  /// In zh, this message translates to:
  /// **'此条目附带 BT 资源'**
  String get hasBtResource;

  /// No description provided for @noContent.
  ///
  /// In zh, this message translates to:
  /// **'（无正文）'**
  String get noContent;

  /// No description provided for @lastFetch.
  ///
  /// In zh, this message translates to:
  /// **'上次更新 {t}'**
  String lastFetch(Object t);

  /// No description provided for @notFetched.
  ///
  /// In zh, this message translates to:
  /// **'尚未抓取'**
  String get notFetched;

  /// No description provided for @deleteFeedQ.
  ///
  /// In zh, this message translates to:
  /// **'删除「{name}」？'**
  String deleteFeedQ(Object name);

  /// No description provided for @deleteFeedHint.
  ///
  /// In zh, this message translates to:
  /// **'将同时删除该源的全部已缓存条目。'**
  String get deleteFeedHint;

  /// No description provided for @coreVersion.
  ///
  /// In zh, this message translates to:
  /// **'核心版本'**
  String get coreVersion;

  /// No description provided for @dataDir.
  ///
  /// In zh, this message translates to:
  /// **'数据目录'**
  String get dataDir;

  /// No description provided for @msgSecurity.
  ///
  /// In zh, this message translates to:
  /// **'消息安全'**
  String get msgSecurity;

  /// No description provided for @msgSecurityDesc.
  ///
  /// In zh, this message translates to:
  /// **'每条消息使用你的 Ed25519 密钥签名并链接父消息（git 式哈希链）。'**
  String get msgSecurityDesc;

  /// No description provided for @privKeyLocal.
  ///
  /// In zh, this message translates to:
  /// **'私钥仅保存在本机，永不外传。'**
  String get privKeyLocal;

  /// No description provided for @aboutDesc.
  ///
  /// In zh, this message translates to:
  /// **'去中心化 BitTorrent 群聊：一个种子就是一个群，'**
  String get aboutDesc;

  /// No description provided for @aboutDesc2.
  ///
  /// In zh, this message translates to:
  /// **'消息以哈希链方式在 BT/DHT 网络中保存与传播，无法被单点篡改。\n\n'**
  String get aboutDesc2;

  /// No description provided for @appearance.
  ///
  /// In zh, this message translates to:
  /// **'外观'**
  String get appearance;

  /// No description provided for @themeSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In zh, this message translates to:
  /// **'浅色'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In zh, this message translates to:
  /// **'深色'**
  String get themeDark;

  /// No description provided for @seedSource.
  ///
  /// In zh, this message translates to:
  /// **'主题色来源'**
  String get seedSource;

  /// No description provided for @seedBrand.
  ///
  /// In zh, this message translates to:
  /// **'品牌蓝'**
  String get seedBrand;

  /// No description provided for @seedWallpaper.
  ///
  /// In zh, this message translates to:
  /// **'壁纸自动取色'**
  String get seedWallpaper;

  /// No description provided for @seedCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义颜色'**
  String get seedCustom;

  /// No description provided for @pickColor.
  ///
  /// In zh, this message translates to:
  /// **'选择主题色'**
  String get pickColor;

  /// No description provided for @wallpaper.
  ///
  /// In zh, this message translates to:
  /// **'聊天背景图'**
  String get wallpaper;

  /// No description provided for @wallpaperNone.
  ///
  /// In zh, this message translates to:
  /// **'未设置'**
  String get wallpaperNone;

  /// No description provided for @wallpaperSet.
  ///
  /// In zh, this message translates to:
  /// **'不透明度 {p}%'**
  String wallpaperSet(Object p);

  /// No description provided for @wallpaperBlur.
  ///
  /// In zh, this message translates to:
  /// **'背景模糊'**
  String get wallpaperBlur;

  /// No description provided for @opacity.
  ///
  /// In zh, this message translates to:
  /// **'不透明度'**
  String get opacity;

  /// No description provided for @pickWallpaper.
  ///
  /// In zh, this message translates to:
  /// **'选择聊天背景图'**
  String get pickWallpaper;

  /// No description provided for @wallpaperApplied.
  ///
  /// In zh, this message translates to:
  /// **'背景已应用；若主题色来源为\"壁纸取色\"将同时更新'**
  String get wallpaperApplied;

  /// No description provided for @filterRules.
  ///
  /// In zh, this message translates to:
  /// **'消息过滤规则'**
  String get filterRules;

  /// No description provided for @addRule.
  ///
  /// In zh, this message translates to:
  /// **'添加过滤规则'**
  String get addRule;

  /// No description provided for @editRule.
  ///
  /// In zh, this message translates to:
  /// **'编辑过滤规则'**
  String get editRule;

  /// No description provided for @add.
  ///
  /// In zh, this message translates to:
  /// **'添加'**
  String get add;

  /// No description provided for @noRules.
  ///
  /// In zh, this message translates to:
  /// **'无规则。可按昵称/公钥/内容屏蔽恶意消息；'**
  String get noRules;

  /// No description provided for @noRules2.
  ///
  /// In zh, this message translates to:
  /// **'被屏蔽消息在聊天中折叠显示。'**
  String get noRules2;

  /// No description provided for @fieldText.
  ///
  /// In zh, this message translates to:
  /// **'消息内容'**
  String get fieldText;

  /// No description provided for @fieldName.
  ///
  /// In zh, this message translates to:
  /// **'作者昵称'**
  String get fieldName;

  /// No description provided for @fieldPk.
  ///
  /// In zh, this message translates to:
  /// **'作者公钥'**
  String get fieldPk;

  /// No description provided for @modeContains.
  ///
  /// In zh, this message translates to:
  /// **'包含'**
  String get modeContains;

  /// No description provided for @modeEquals.
  ///
  /// In zh, this message translates to:
  /// **'等于'**
  String get modeEquals;

  /// No description provided for @modeRegex.
  ///
  /// In zh, this message translates to:
  /// **'正则表达式'**
  String get modeRegex;

  /// No description provided for @matchValue.
  ///
  /// In zh, this message translates to:
  /// **'匹配值'**
  String get matchValue;

  /// No description provided for @caseSensitive.
  ///
  /// In zh, this message translates to:
  /// **'区分大小写'**
  String get caseSensitive;

  /// No description provided for @caseSensitiveMark.
  ///
  /// In zh, this message translates to:
  /// **' · 区分大小写'**
  String get caseSensitiveMark;

  /// No description provided for @clear.
  ///
  /// In zh, this message translates to:
  /// **'清除'**
  String get clear;

  /// No description provided for @today.
  ///
  /// In zh, this message translates to:
  /// **'今天'**
  String get today;

  /// No description provided for @yesterday.
  ///
  /// In zh, this message translates to:
  /// **'昨天'**
  String get yesterday;

  /// No description provided for @mon.
  ///
  /// In zh, this message translates to:
  /// **'星期一'**
  String get mon;

  /// No description provided for @tue.
  ///
  /// In zh, this message translates to:
  /// **'星期二'**
  String get tue;

  /// No description provided for @wed.
  ///
  /// In zh, this message translates to:
  /// **'星期三'**
  String get wed;

  /// No description provided for @thu.
  ///
  /// In zh, this message translates to:
  /// **'星期四'**
  String get thu;

  /// No description provided for @fri.
  ///
  /// In zh, this message translates to:
  /// **'星期五'**
  String get fri;

  /// No description provided for @sat.
  ///
  /// In zh, this message translates to:
  /// **'星期六'**
  String get sat;

  /// No description provided for @sun.
  ///
  /// In zh, this message translates to:
  /// **'星期日'**
  String get sun;

  /// No description provided for @videoFail.
  ///
  /// In zh, this message translates to:
  /// **'无法播放该视频'**
  String get videoFail;

  /// No description provided for @tapPlayVideo.
  ///
  /// In zh, this message translates to:
  /// **'点击播放视频'**
  String get tapPlayVideo;

  /// No description provided for @previewText.
  ///
  /// In zh, this message translates to:
  /// **'预览文本'**
  String get previewText;

  /// No description provided for @openWith.
  ///
  /// In zh, this message translates to:
  /// **'用其他应用打开'**
  String get openWith;

  /// No description provided for @noAppForFile.
  ///
  /// In zh, this message translates to:
  /// **'没有可打开该文件的应用'**
  String get noAppForFile;

  /// No description provided for @fileTooBig.
  ///
  /// In zh, this message translates to:
  /// **'文件超过 2MB，请使用“其他应用打开”'**
  String get fileTooBig;

  /// No description provided for @notPlainText.
  ///
  /// In zh, this message translates to:
  /// **'该文件不是纯文本'**
  String get notPlainText;

  /// No description provided for @kindImage.
  ///
  /// In zh, this message translates to:
  /// **'图片'**
  String get kindImage;

  /// No description provided for @kindAudio.
  ///
  /// In zh, this message translates to:
  /// **'音频'**
  String get kindAudio;

  /// No description provided for @kindVideo.
  ///
  /// In zh, this message translates to:
  /// **'视频'**
  String get kindVideo;

  /// No description provided for @kindText.
  ///
  /// In zh, this message translates to:
  /// **'文本'**
  String get kindText;

  /// No description provided for @kindFile.
  ///
  /// In zh, this message translates to:
  /// **'文件'**
  String get kindFile;

  /// No description provided for @pickFileToSend.
  ///
  /// In zh, this message translates to:
  /// **'选择要发送的文件'**
  String get pickFileToSend;

  /// No description provided for @pausedMark.
  ///
  /// In zh, this message translates to:
  /// **' · 已暂停'**
  String get pausedMark;

  /// No description provided for @blurredMark.
  ///
  /// In zh, this message translates to:
  /// **' · 已模糊'**
  String get blurredMark;

  /// No description provided for @tasksCount.
  ///
  /// In zh, this message translates to:
  /// **'{n} 任务'**
  String tasksCount(Object n);

  /// No description provided for @editName.
  ///
  /// In zh, this message translates to:
  /// **'昵称'**
  String get editName;

  /// No description provided for @pubkeyLabel.
  ///
  /// In zh, this message translates to:
  /// **'公钥 {pk}'**
  String pubkeyLabel(Object pk);

  /// No description provided for @identity.
  ///
  /// In zh, this message translates to:
  /// **'身份'**
  String get identity;

  /// No description provided for @onlinePeers.
  ///
  /// In zh, this message translates to:
  /// **'{n} 在线'**
  String onlinePeers(Object n);

  /// No description provided for @chatCapableMark.
  ///
  /// In zh, this message translates to:
  /// **' · 支持聊天'**
  String get chatCapableMark;

  /// No description provided for @coreVersionValue.
  ///
  /// In zh, this message translates to:
  /// **'{v} · 引擎: {e}'**
  String coreVersionValue(Object v, Object e);

  /// No description provided for @torrentError.
  ///
  /// In zh, this message translates to:
  /// **'种子出错：{e}'**
  String torrentError(Object e);

  /// No description provided for @rssError.
  ///
  /// In zh, this message translates to:
  /// **'订阅失败：{e}'**
  String rssError(Object e);

  /// No description provided for @downloaded.
  ///
  /// In zh, this message translates to:
  /// **'已下载'**
  String get downloaded;

  /// No description provided for @attMeta.
  ///
  /// In zh, this message translates to:
  /// **'{size} · {tail}'**
  String attMeta(Object size, Object tail);

  /// No description provided for @dlProgress.
  ///
  /// In zh, this message translates to:
  /// **'{pct}% · {rate} · {peers} peers'**
  String dlProgress(Object pct, Object rate, Object peers);

  /// No description provided for @sigState.
  ///
  /// In zh, this message translates to:
  /// **'状态 {s}'**
  String sigState(Object s);

  /// No description provided for @filterRuleDesc.
  ///
  /// In zh, this message translates to:
  /// **'{field} {mode} “{value}”'**
  String filterRuleDesc(Object field, Object mode, Object value);

  /// No description provided for @errDmSelf.
  ///
  /// In zh, this message translates to:
  /// **'不能和自己私聊'**
  String get errDmSelf;

  /// No description provided for @errNoKeyInfo.
  ///
  /// In zh, this message translates to:
  /// **'还没有对方的密钥信息：先在同群聊里收到 TA 至少一条消息'**
  String get errNoKeyInfo;

  /// No description provided for @errNameLen.
  ///
  /// In zh, this message translates to:
  /// **'昵称长度需在 1..32 字符'**
  String get errNameLen;

  /// No description provided for @errGroupNameLen.
  ///
  /// In zh, this message translates to:
  /// **'群名长度需在 1..96 字节'**
  String get errGroupNameLen;

  /// No description provided for @errUrlScheme.
  ///
  /// In zh, this message translates to:
  /// **'URL 必须以 http(s):// 开头'**
  String get errUrlScheme;

  /// No description provided for @errManifestProtected.
  ///
  /// In zh, this message translates to:
  /// **'这是群聊清单种子，请通过聊天页退群来移除'**
  String get errManifestProtected;

  /// No description provided for @errNoResource.
  ///
  /// In zh, this message translates to:
  /// **'该条目没有可下载的资源'**
  String get errNoResource;

  /// No description provided for @errTextEmpty.
  ///
  /// In zh, this message translates to:
  /// **'空消息或过长（≤32KB）'**
  String get errTextEmpty;

  /// No description provided for @fabGroup.
  ///
  /// In zh, this message translates to:
  /// **'种子群聊'**
  String get fabGroup;

  /// No description provided for @inviteLink.
  ///
  /// In zh, this message translates to:
  /// **'邀请链接（频道磁力）'**
  String get inviteLink;

  /// No description provided for @copyInviteLink.
  ///
  /// In zh, this message translates to:
  /// **'复制磁力邀请链接'**
  String get copyInviteLink;

  /// No description provided for @groupChat.
  ///
  /// In zh, this message translates to:
  /// **'群聊'**
  String get groupChat;

  /// No description provided for @identities.
  ///
  /// In zh, this message translates to:
  /// **'身份档案'**
  String get identities;

  /// No description provided for @identitiesHint.
  ///
  /// In zh, this message translates to:
  /// **'每个昵称绑定一把私钥：改名=新身份。删除后私钥不可恢复。'**
  String get identitiesHint;

  /// No description provided for @currentIdentity.
  ///
  /// In zh, this message translates to:
  /// **'当前身份'**
  String get currentIdentity;

  /// No description provided for @createIdentity.
  ///
  /// In zh, this message translates to:
  /// **'新建身份'**
  String get createIdentity;

  /// No description provided for @newIdentityName.
  ///
  /// In zh, this message translates to:
  /// **'新身份昵称'**
  String get newIdentityName;

  /// No description provided for @createIdentityWarn.
  ///
  /// In zh, this message translates to:
  /// **'将生成全新的 Ed25519 私钥：新消息以新身份署名，旧身份历史保留。'**
  String get createIdentityWarn;

  /// No description provided for @switchIdentity.
  ///
  /// In zh, this message translates to:
  /// **'切换身份'**
  String get switchIdentity;

  /// No description provided for @switchIdentityQ.
  ///
  /// In zh, this message translates to:
  /// **'切换到「{name}」？'**
  String switchIdentityQ(Object name);

  /// No description provided for @switchIdentityHint.
  ///
  /// In zh, this message translates to:
  /// **'切换后，新消息将以该身份的私钥署名（相当于以另一个昵称发言）。'**
  String get switchIdentityHint;

  /// No description provided for @switched.
  ///
  /// In zh, this message translates to:
  /// **'已切换为「{name}」'**
  String switched(Object name);

  /// No description provided for @deleteIdentity.
  ///
  /// In zh, this message translates to:
  /// **'删除身份'**
  String get deleteIdentity;

  /// No description provided for @deleteIdentityQ.
  ///
  /// In zh, this message translates to:
  /// **'永久删除身份「{name}」？'**
  String deleteIdentityQ(Object name);

  /// No description provided for @deleteIdentityWarn.
  ///
  /// In zh, this message translates to:
  /// **'私钥将被销毁且不可恢复；该身份的历史消息仍在链上但无法再以它发言。'**
  String get deleteIdentityWarn;

  /// No description provided for @identityCreated.
  ///
  /// In zh, this message translates to:
  /// **'身份「{name}」已创建（未启用）'**
  String identityCreated(Object name);

  /// No description provided for @identityCreatedSwitch.
  ///
  /// In zh, this message translates to:
  /// **'身份「{name}」已创建并启用'**
  String identityCreatedSwitch(Object name);

  /// No description provided for @identityDeleted.
  ///
  /// In zh, this message translates to:
  /// **'身份已删除'**
  String get identityDeleted;

  /// No description provided for @activeMark.
  ///
  /// In zh, this message translates to:
  /// **'使用中'**
  String get activeMark;

  /// No description provided for @errIdentityActive.
  ///
  /// In zh, this message translates to:
  /// **'不能删除正在使用的身份'**
  String get errIdentityActive;

  /// No description provided for @errIdentityLast.
  ///
  /// In zh, this message translates to:
  /// **'至少保留一个身份'**
  String get errIdentityLast;

  /// No description provided for @errNameLen2.
  ///
  /// In zh, this message translates to:
  /// **'昵称长度需在 1..32 字符'**
  String get errNameLen2;

  /// No description provided for @setAvatar.
  ///
  /// In zh, this message translates to:
  /// **'更换头像'**
  String get setAvatar;

  /// No description provided for @enterRoomTitle.
  ///
  /// In zh, this message translates to:
  /// **'进入种子群聊'**
  String get enterRoomTitle;

  /// No description provided for @roomInputLabel.
  ///
  /// In zh, this message translates to:
  /// **'磁力链接 / info hash'**
  String get roomInputLabel;

  /// No description provided for @magnetHashHint.
  ///
  /// In zh, this message translates to:
  /// **'magnet:?xt=urn:btih:… 或 40 位 info hash'**
  String get magnetHashHint;

  /// No description provided for @enterRoom.
  ///
  /// In zh, this message translates to:
  /// **'进入群聊'**
  String get enterRoom;

  /// No description provided for @enterRoomNew.
  ///
  /// In zh, this message translates to:
  /// **'进入该种子的群聊'**
  String get enterRoomNew;

  /// No description provided for @addTorrentRoom.
  ///
  /// In zh, this message translates to:
  /// **'添加种子进入群聊'**
  String get addTorrentRoom;

  /// No description provided for @addTorrentRoomDesc.
  ///
  /// In zh, this message translates to:
  /// **'粘贴磁力链接或 info hash：添加种子并进入它的聊天室'**
  String get addTorrentRoomDesc;

  /// No description provided for @importTorrentRoomDesc.
  ///
  /// In zh, this message translates to:
  /// **'选择 .torrent 文件：添加任务并进入它的群聊'**
  String get importTorrentRoomDesc;

  /// No description provided for @roomEntered.
  ///
  /// In zh, this message translates to:
  /// **'已进入群聊「{name}」'**
  String roomEntered(Object name);

  /// No description provided for @torrentRoomKind.
  ///
  /// In zh, this message translates to:
  /// **'种子群聊 · 该种子的所有 BitTorrent 用户共享'**
  String get torrentRoomKind;

  /// No description provided for @dmChannelKind.
  ///
  /// In zh, this message translates to:
  /// **'端到端加密私聊频道'**
  String get dmChannelKind;

  /// No description provided for @infohashLabel.
  ///
  /// In zh, this message translates to:
  /// **'种子 infohash'**
  String get infohashLabel;

  /// No description provided for @roomInviteTitle.
  ///
  /// In zh, this message translates to:
  /// **'邀请 = 分享这个种子'**
  String get roomInviteTitle;

  /// No description provided for @roomInviteHint.
  ///
  /// In zh, this message translates to:
  /// **'把磁力链接或 info hash 发给别人，对方添加该种子后即可进入同一群聊'**
  String get roomInviteHint;

  /// No description provided for @leaveRoomHint.
  ///
  /// In zh, this message translates to:
  /// **'只解除群聊绑定，种子任务保留在种子页。'**
  String get leaveRoomHint;

  /// No description provided for @network.
  ///
  /// In zh, this message translates to:
  /// **'网络'**
  String get network;

  /// No description provided for @defaultTrackers.
  ///
  /// In zh, this message translates to:
  /// **'默认 Tracker 列表'**
  String get defaultTrackers;

  /// No description provided for @defaultTrackersNone.
  ///
  /// In zh, this message translates to:
  /// **'未设置（仅 DHT/PEX 发现节点）'**
  String get defaultTrackersNone;

  /// No description provided for @defaultTrackersSet.
  ///
  /// In zh, this message translates to:
  /// **'已设置 {n} 个 · 自动附加到新任务'**
  String defaultTrackersSet(Object n);

  /// No description provided for @defaultTrackersHint.
  ///
  /// In zh, this message translates to:
  /// **'每行一个 announce 地址（http/https/udp）。会自动附加到每个新种子（含聊天附件）并立即应用到现有任务；在 DHT 不畅的网络里能显著提升连通性。'**
  String get defaultTrackersHint;

  /// No description provided for @trackersApplied.
  ///
  /// In zh, this message translates to:
  /// **'已保存并应用到 {n} 个任务'**
  String trackersApplied(Object n);

  /// No description provided for @trackers.
  ///
  /// In zh, this message translates to:
  /// **'Tracker（{n}）'**
  String trackers(Object n);

  /// No description provided for @addTracker.
  ///
  /// In zh, this message translates to:
  /// **'添加 Tracker'**
  String get addTracker;

  /// No description provided for @trackerUrl.
  ///
  /// In zh, this message translates to:
  /// **'Tracker 地址'**
  String get trackerUrl;

  /// No description provided for @noTrackersHint.
  ///
  /// In zh, this message translates to:
  /// **'无 tracker：依赖 DHT/PEX 发现节点。可在设置 → 网络 中配置默认 Tracker 列表'**
  String get noTrackersHint;

  /// No description provided for @trackerFails.
  ///
  /// In zh, this message translates to:
  /// **'失败 {n} 次'**
  String trackerFails(Object n);

  /// No description provided for @accept.
  ///
  /// In zh, this message translates to:
  /// **'接受'**
  String get accept;

  /// No description provided for @decline.
  ///
  /// In zh, this message translates to:
  /// **'拒绝'**
  String get decline;

  /// No description provided for @wallpaperEdit.
  ///
  /// In zh, this message translates to:
  /// **'调整壁纸'**
  String get wallpaperEdit;

  /// No description provided for @wallpaperEditHint.
  ///
  /// In zh, this message translates to:
  /// **'双指缩放与拖动调整构图；下方滑杆实时预览最终效果'**
  String get wallpaperEditHint;

  /// No description provided for @wallpaperLoadFail.
  ///
  /// In zh, this message translates to:
  /// **'图片加载失败'**
  String get wallpaperLoadFail;

  /// No description provided for @exportLogs.
  ///
  /// In zh, this message translates to:
  /// **'导出日志'**
  String get exportLogs;

  /// No description provided for @exportLogsHint.
  ///
  /// In zh, this message translates to:
  /// **'将核心与界面日志导出到「下载」目录，用于问题反馈'**
  String get exportLogsHint;

  /// No description provided for @logsExported.
  ///
  /// In zh, this message translates to:
  /// **'日志已导出：{dest}'**
  String logsExported(Object dest);

  /// No description provided for @exportLogsFail.
  ///
  /// In zh, this message translates to:
  /// **'导出失败：'**
  String get exportLogsFail;

  /// No description provided for @videoDecoder.
  ///
  /// In zh, this message translates to:
  /// **'视频解码'**
  String get videoDecoder;

  /// No description provided for @videoDecoderSoftware.
  ///
  /// In zh, this message translates to:
  /// **'软件解码（兼容优先）'**
  String get videoDecoderSoftware;

  /// No description provided for @videoDecoderHardware.
  ///
  /// In zh, this message translates to:
  /// **'硬件解码优先（省电）'**
  String get videoDecoderHardware;

  /// No description provided for @videoDecoderHint.
  ///
  /// In zh, this message translates to:
  /// **'遇到视频"有声无画"请保持软件解码；硬件解码更省电，但部分机型/编码会黑屏。切换后对新打开的视频生效'**
  String get videoDecoderHint;

  /// No description provided for @videoDecoderTip.
  ///
  /// In zh, this message translates to:
  /// **'无法播放？可点「外部打开」，并到 设置 → 导出日志 反馈'**
  String get videoDecoderTip;

  /// No description provided for @avatarLocalOnly.
  ///
  /// In zh, this message translates to:
  /// **'头像与昵称仅保存在本机，不会广播给其他用户'**
  String get avatarLocalOnly;

  /// No description provided for @renameLocalNote.
  ///
  /// In zh, this message translates to:
  /// **'备注仅自己可见，不会广播'**
  String get renameLocalNote;

  /// No description provided for @dmRequestTitle.
  ///
  /// In zh, this message translates to:
  /// **'私聊请求'**
  String get dmRequestTitle;

  /// No description provided for @dmRequestBody.
  ///
  /// In zh, this message translates to:
  /// **'{name} 请求与你建立端到端加密私聊'**
  String dmRequestBody(Object name);

  /// No description provided for @dmRequestBodyAnonymous.
  ///
  /// In zh, this message translates to:
  /// **'有用户请求与你建立端到端加密私聊'**
  String get dmRequestBodyAnonymous;

  /// No description provided for @dmRejectedByPeer.
  ///
  /// In zh, this message translates to:
  /// **'对方婉拒了私聊请求'**
  String get dmRejectedByPeer;

  /// No description provided for @dmAwaitingAccept.
  ///
  /// In zh, this message translates to:
  /// **'等待对方接受'**
  String get dmAwaitingAccept;

  /// No description provided for @dmRequestSent.
  ///
  /// In zh, this message translates to:
  /// **'私聊请求已发送'**
  String get dmRequestSent;

  /// No description provided for @dmRequestQueued.
  ///
  /// In zh, this message translates to:
  /// **'对方当前不在线，请求将在 TA 上线后自动送达'**
  String get dmRequestQueued;

  /// No description provided for @dmAlreadyExists.
  ///
  /// In zh, this message translates to:
  /// **'私聊已存在'**
  String get dmAlreadyExists;

  /// No description provided for @dmOnline.
  ///
  /// In zh, this message translates to:
  /// **'在线'**
  String get dmOnline;

  /// No description provided for @dmOffline.
  ///
  /// In zh, this message translates to:
  /// **'离线'**
  String get dmOffline;

  /// No description provided for @dmLocalOnlyHint.
  ///
  /// In zh, this message translates to:
  /// **'私聊消息在两台设备之间直连传输、仅本地存储：不写入 DHT，也不新建种子'**
  String get dmLocalOnlyHint;

  /// No description provided for @membersIdentified.
  ///
  /// In zh, this message translates to:
  /// **'可私聊的成员'**
  String get membersIdentified;

  /// No description provided for @attPhaseHash.
  ///
  /// In zh, this message translates to:
  /// **'正在计算文件哈希…'**
  String get attPhaseHash;

  /// No description provided for @attPhaseCopy.
  ///
  /// In zh, this message translates to:
  /// **'正在复制到做种目录…'**
  String get attPhaseCopy;

  /// No description provided for @attPhaseSeed.
  ///
  /// In zh, this message translates to:
  /// **'正在做种并发送…'**
  String get attPhaseSeed;

  /// No description provided for @attachFailed.
  ///
  /// In zh, this message translates to:
  /// **'附件发送失败'**
  String get attachFailed;

  /// No description provided for @videoDecoderHardwareOnly.
  ///
  /// In zh, this message translates to:
  /// **'硬件解码（MediaCodec）· 解码失败将明确报错'**
  String get videoDecoderHardwareOnly;

  /// No description provided for @dmRequestSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'请求与你私聊'**
  String get dmRequestSubtitle;

  /// No description provided for @block.
  ///
  /// In zh, this message translates to:
  /// **'屏蔽'**
  String get block;

  /// No description provided for @dmBlocked.
  ///
  /// In zh, this message translates to:
  /// **'已屏蔽该用户'**
  String get dmBlocked;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
