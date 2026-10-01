import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../../../core/diagnostics/diag_log.dart';
import '../../../core/error/drive_error.dart';
import '../../../core/utils/redact.dart';
import '../../../domain/adapters/cloud_drive_adapter.dart';
import '../../../domain/adapters/credential_store.dart';
import '../../../domain/entities/auth_credential.dart';
import '../../../domain/entities/capabilities.dart';
import '../../../domain/entities/cloud_account.dart';
import '../../../domain/entities/drive_entry.dart';
import '../../../domain/entities/drive_provider.dart';
import '../../../domain/entities/quality_option.dart';
import '../../../domain/entities/stream_ticket.dart';
import '../../http/http_client.dart';
import '../../http/token_bucket.dart';
import '../../auth/quark_qr_login.dart' show parseSetCookieLines;
import 'quark_endpoints.dart';
import 'quark_error_mapper.dart';
import 'quark_models.dart';
import 'quark_play_routes.dart';

/// `play/info` / `v2/play` 的解析结果。
///
/// 两个字段必须一起用：票据给「能播什么」，元信息给「原画那一档怎么写副标题」
/// （源文件的真实宽高/码率/容器只在这两个接口的 `meta` 里）。
typedef _PlayInfoResult = ({StreamTicket ticket, SourceMeta? meta});

/// 夸克网盘适配器。
///
/// 走 **PC 自用接口**（`drive-pc.quark.cn`），靠网页登录态 Cookie 鉴权。
/// 全部字段语义与端点均按 PoC 实测校准，见 [QuarkMapper] 的表格。
///
/// 该类**只依赖 [HttpClientLike]**，不依赖 `dio`，因此可以在单元测试里
/// 用假客户端把分页、错误映射、限流、**取流路由降级**、直链组装全部覆盖到，
/// 不发一次网络请求。
class QuarkAdapter implements CloudDriveAdapter {
  QuarkAdapter({
    required HttpClientLike http,
    required CredentialStore credentialStore,
    Capabilities? capabilities,
    TokenBucket? listBucket,
    TokenBucket? linkBucket,
    String gateway = QuarkEndpoints.pcGateway,
    DateTime Function()? clock,
  })  : _http = http,
        _store = credentialStore,
        _gateway = gateway,
        _clock = clock ?? DateTime.now,
        _capabilities = capabilities ?? quarkCapabilities,
        _listBucket = listBucket ??
            TokenBucket(ratePerSecond: quarkCapabilities.listQps),
        _linkBucket = linkBucket ??
            TokenBucket(
              ratePerSecond: quarkCapabilities.linkQps,
              burst: linkBucketBurst,
            );

  /// 取链桶的突发容量。
  ///
  /// ## 为什么是 2，而不是 `TokenBucket` 默认的 1
  ///
  /// 一次播放要**两个**请求：`audioplay`（原画）与 `play/info`（转码梯度）。
  /// 它们是一对「计划中的请求」，不是重试风暴 —— 而桶容量 1 意味着第二个
  /// 必然等满 1 秒（`linkQps = 1.0`）。表现是「点了播放，先干等一秒多」，
  /// 而且这一秒换来的是**零**保护价值。
  ///
  /// 2 仍然是保守的：瞬时最多 2 个请求，**持续速率依旧是 1/s**。
  /// 参照系是列表桶 —— 它以 3.0 QPS **持续**跑着（参考项目实测约 3 QPS
  /// 未触发风控），所以这个突发量严格低于已经在用的那档强度。
  ///
  /// 公开是为了让单测钉住它：调回 1 不会报错，只会让每次起播多等一秒。
  static const int linkBucketBurst = 2;

  /// 夸克的默认能力声明。
  ///
  /// ⚠️ **这里刻意不声明 [Capabilities.maxSingleFileBytes]**。
  ///
  /// 那条 50MiB 限制是 `/1/clouddrive/file/download`（PC 网页版取**下载**直链）
  /// 的限制，而本适配器的播放取链走播放路由。2026-09-24 参考项目实测：
  /// 音频播放路由**不受体积限制**（774.1MB 的整轨 WAV 照常返回原文件直链），
  /// 库内 195 首「超限」曲目抽样 40 首全部可播。
  ///
  /// 把 download 的上限写进能力声明，会让**大批其实能播的文件被误判为
  /// 不可播**，所以它只作为最后一条兜底路由存在（见 [resolveStream]）。
  /// 真正取不到链时，由播放控制器在运行时标记 —— 那才是「真的播不了」。
  static const Capabilities quarkCapabilities = Capabilities(
    provider: DriveProvider.quark,
    canListDirectory: true,
    canSearch: true,
    canResolveDirectLink: true,
    directLinkNeedsHeaders: true,
    supportsRangeRequests: true,
    listQps: 3.0,
    linkQps: 1.0,
    defaultPageSize: 50,
    authModes: {
      // 主链路：夸克 App 扫码 → service_ticket 换账号 Cookie。
      AuthMode.qrCode,
      // 备选与兜底。
      AuthMode.browserCookie,
      AuthMode.manualCookie,
    },
  );

  final HttpClientLike _http;
  final CredentialStore _store;
  final String _gateway;
  final DateTime Function() _clock;
  final Capabilities _capabilities;
  final TokenBucket _listBucket;
  final TokenBucket _linkBucket;

  AuthCredential? _credential;
  CloudAccount? _account;

  @override
  DriveProvider get provider => DriveProvider.quark;

  @override
  Capabilities get capabilities => _capabilities;

  @override
  String get rootId => QuarkEndpoints.rootId;

  /// 当前会话的 `Cookie:` 头。未授权时为空串。
  String get _cookieHeader => _credential?.cookieHeader ?? '';

  /// 是否持有会话（不代表仍然有效）
  bool get hasSession => _cookieHeader.isNotEmpty;

  /// 当前账号（若已恢复/授权）
  CloudAccount? get currentAccount => _account;

  // -------------------------------------------------------------------
  // 授权
  // -------------------------------------------------------------------

  @override
  Future<CloudAccount?> restoreSession() async {
    final stored = await _store.load(DriveProvider.quark);
    if (stored == null || stored.isEmpty) {
      diag.warn('会话', '恢复失败：凭证存储里没有可用凭证');
      return null;
    }

    _credential = stored;
    diag.info(
      '会话',
      '拿到凭证：模式=${stored.mode.name}，'
      'Cookie ${maskCookieHeader(stored.cookieHeader)}，'
      '捕获于 ${stored.capturedAt}',
    );

    final member = await _fetchMember();
    _account = member;
    diag.info('会话', '校验通过：${member.label}');
    return member;
  }

  @override
  Future<CloudAccount> authorize(AuthCredential credential) async {
    if (credential.isEmpty) {
      throw const DriveException(
        type: DriveErrorType.unauthorized,
        message: '授权凭证为空，请重新登录夸克账号',
      );
    }

    _credential = credential;
    diag.info(
      '会话',
      '提交凭证校验：模式=${credential.mode.name}，'
      'Cookie ${maskCookieHeader(credential.cookieHeader)}',
    );

    CloudAccount account;
    try {
      // 先校验再落库：避免把废凭证写进安全存储
      account = await _fetchMember();
    } catch (_) {
      _credential = null;
      _account = null;
      diag.error('会话', '凭证校验失败，已丢弃');
      rethrow;
    }

    _account = account;
    await _store.save(credential);
    diag.info('会话', '授权完成：${account.label}');
    return account;
  }

  @override
  Future<void> signOut() async {
    _credential = null;
    _account = null;
    await _store.clear(DriveProvider.quark);
    diag.info('会话', '已退出登录');
  }

  @override
  Future<bool> ping() async {
    if (!hasSession) return false;
    try {
      await _request(
        () => _get(QuarkEndpoints.config),
        context: '连接诊断',
      );
      return true;
    } on DriveException catch (e) {
      if (e.needsReauth) return false;
      rethrow;
    }
  }

  // -------------------------------------------------------------------
  // 遍历与搜索
  // -------------------------------------------------------------------

  @override
  Future<DrivePage> listDirectory({
    required String dirId,
    String? pageToken,
    int? pageSize,
  }) async {
    final size = pageSize ?? _capabilities.defaultPageSize;
    final page = _parsePageToken(pageToken);

    final result = await _listBucket.run(
      () => _request(
        () => _get(QuarkEndpoints.fileSort, {
          'pdir_fid': dirId.isEmpty ? rootId : dirId,
          '_page': page,
          '_size': size,
          // 实测：即便带 _fetch_total=1，PC 端也**不返回** data.total
          // （data 里只有 list / last_view_list / recent_file_list）。
          // 仍然带上，一是无害，二是官方接口若返回就能拿到更精确的总数。
          '_fetch_total': 1,
          '_sort': QuarkEndpoints.defaultSort,
          '_is_hl': 1,
        }),
        context: '列目录',
      ),
    );

    final entries = QuarkMapper.toEntries(result.dataListItems);
    final total = result.dataTotal;

    // 下一页判定。
    // 主路径实际走的是「满页启发式」：实测 data.total 恒为 null，
    // 但 _size=5 连续取 3 页各返回 5 条且互不重叠，说明
    // 「返回条数 == 请求条数」即代表还有下一页。
    String? nextToken;
    if (total != null) {
      if (page * size < total) nextToken = '${page + 1}';
    } else if (entries.length >= size) {
      nextToken = '${page + 1}';
    }

    return DrivePage(entries: entries, nextPageToken: nextToken, total: total);
  }

  @override
  Future<List<DriveEntry>> search({
    required String keyword,
    int limit = 100,
    int offset = 0,
  }) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return const [];

    final page = offset <= 0 ? 1 : (offset ~/ limit) + 1;

    final result = await _listBucket.run(
      () => _request(
        () => _get(QuarkEndpoints.fileSearch, {
          '_key': trimmed,
          '_page': page,
          '_size': limit,
          '_fetch_total': 1,
          // 文件优先：实测 file_type:asc 时前 20 条全是目录
          '_sort': QuarkEndpoints.searchSort,
        }),
        context: '搜索',
      ),
    );

    return QuarkMapper.toEntries(result.dataListItems);
  }

  // -------------------------------------------------------------------
  // 取流：多路由降级
  // -------------------------------------------------------------------

  /// 取播放直链（含清晰度档位）。
  ///
  /// ## 原画与转码梯度是**两个不同的接口**，必须分别取
  ///
  /// 2026-10-01 实测（指环王 S01E01 / 3.8 GB MKV，与無間道II 4K 交叉验证）：
  ///
  /// | 来源 | 给什么 | 实测证据 |
  /// |---|---|---|
  /// | `POST /batch/file/play/info` | **只有转码梯度** | `video_list` = super/high/low，`meta` 才是源文件 |
  /// | `GET /file/audioplay?fid=` | **原文件本身** | `Content-Type: video/x-matroska`，`Content-Range: bytes 0-4095/3828008839` |
  /// | `POST /file/download` | 原文件，但 **>50 MiB 直接 `23018`** | 3.8 GB 被拒 |
  /// | `POST /file/v2/play {"fid":…}` | 与 `play/info` 同构 | 与 play/info 交叉验证 |
  ///
  /// ⚠️ **以前这里是个坑**：`play/info` 的 `audio_list`（一条 `dolby_eac3`
  /// 纯音频流）被解析器当成「原画」，而原画永远排最前 → 默认播的就是那条
  /// **没有视频轨**的流：有声音、进度条在走、**没有画面**，且不报任何错。
  /// 解析器现在跳过音轨子树（见 `QuarkPlayInfoParser.audioOnlyKeys`），
  /// 真正的原画由这里从 `audioplay` 取。
  ///
  /// ## 为什么要两个都取，而不是「先原画、不行再梯度」
  ///
  /// 它们不是同一条链上的备选，而是**同时需要**的两份数据：
  ///   - 原画决定「点开就能看到原片质量」；
  ///   - 梯度决定画质菜单里有没有东西可选。
  ///
  /// 任一条失败都不影响另一条 —— 拿不到梯度只是菜单里没有转码档，
  /// 拿不到原画还能退回最高那一档转码流。
  ///
  /// 短路规则：授权失效（`needsReauth`）与文件不存在（`notFound`）
  /// **立即上抛**，换接口结果一样，再打只是白费一次取链配额。
  @override
  Future<StreamTicket> resolveStream(String fileId, {String? qualityId}) async {
    diag.info(
      '取链',
      '开始取直链 fid=$fileId，'
      '会话=${hasSession ? "有" : "无（会直接抛未授权）"}'
      '${qualityId == null ? "" : "，指定档位=$qualityId"}',
    );

    final failures = <String>[];

    // ── ① 原画：原文件本身 ────────────────────────────────────────────
    //
    // 路由名字叫 audio，但它对**任意 fid 都返回原文件**（视频也一样，
    // 实测回的是 `video/x-matroska` 而不是音频转码），且不受 50 MiB 限制。
    final original = await _attempt(
      'audio_play',
      failures,
      () => _resolveViaSimpleGet(
        route: QuarkPlayRoute.audioPlay,
        fileId: fileId,
        path: QuarkEndpoints.fileAudioplay,
        context: '取原文件直链',
      ),
    );

    // ── ② 转码梯度：清晰度切换的唯一来源 ──────────────────────────────
    final info = await _attempt(
      'play_info',
      failures,
      () => _resolveViaPlayInfo(fileId),
    );

    final merged = _mergeOriginalAndLadder(original: original, info: info);
    if (merged != null) {
      final switched = _applyQuality(merged, qualityId);
      diag.info(
        '取链',
        '取链成功：${switched.redactedUrl}，'
        '档位=[${describeQualities(switched.qualities)}]'
        '（原画=${original == null ? "无" : "有"}，'
        '转码梯度=${info?.ticket.qualities.length ?? 0} 档）',
      );
      return switched;
    }

    // ── ③ 兜底：两条主来源都空了才走这里 ──────────────────────────────
    //
    // 两条都拿不到地址是极少见的（服务端改了响应形状 / 该 fid 两种形态都
    // 不认）。这时按「信息量从多到少」再试一遍，任一条成功即返回。
    for (final route in const [QuarkPlayRoute.v2Play, QuarkPlayRoute.download]) {
      try {
        final ticket = route == QuarkPlayRoute.v2Play
            ? await _resolveViaV2Play(fileId)
            : await _resolveViaDownload(fileId);
        if (ticket == null) {
          failures.add('${route.id}: 响应里没有可用地址');
          continue;
        }

        final switched = _applyQuality(ticket, qualityId);
        diag.info(
          '取链',
          '兜底路由 ${route.id}（${route.label}）成功：'
          '${switched.redactedUrl}，档位=[${describeQualities(switched.qualities)}]',
        );
        return switched;
      } on DriveException catch (e) {
        if (e.needsReauth || e.type == DriveErrorType.notFound) {
          diag.error('取链', '路由 ${route.id} 失败且不可降级，直接放弃',
              error: _describe(e));
          rethrow;
        }
        failures.add('${route.id}: ${e.type.name} ${e.message}');
        diag.warn('取链', '路由 ${route.id}（${route.label}）失败',
            error: _describe(e));
      }
    }

    diag.error('取链', '全部取链路由失败：${failures.join(" | ")}');
    throw DriveException(
      type: DriveErrorType.unknown,
      message: '取链失败，无法播放该文件。'
          '最后一条错误：${failures.isEmpty ? "无" : failures.last}',
    );
  }

  /// 试一条取链路径。失败记进 [failures] 并返回 `null`。
  ///
  /// 泛型是必要的：两条主来源的返回类型不同（`audioplay` 直接给票据，
  /// `play/info` 给「票据 + 源文件元信息」）。写死成 `StreamTicket?`
  /// 会把 `play/info` 那份元信息挤掉，原画那档就没有副标题了。
  ///
  /// 授权失效 / 文件不存在**直接上抛**（见 [resolveStream] 的短路规则）。
  Future<T?> _attempt<T>(
    String id,
    List<String> failures,
    Future<T?> Function() run,
  ) async {
    try {
      final value = await run();
      if (value == null) {
        diag.warn('取链', '$id：接口通了但响应里没有可用地址');
        failures.add('$id: 响应里没有可用地址');
      }
      return value;
    } on DriveException catch (e) {
      if (e.needsReauth || e.type == DriveErrorType.notFound) {
        diag.error('取链', '$id 失败且不可降级，直接放弃', error: _describe(e));
        rethrow;
      }
      failures.add('$id: ${e.type.name} ${e.message}');
      diag.warn('取链', '$id 失败，另一条来源仍可独立工作', error: _describe(e));
      return null;
    }
  }

  /// 把「原画（原文件）」与「转码梯度」合成一张票据。两条都缺时返回 `null`。
  ///
  /// 原画**永远排最前**，于是 `StreamTicket.pickActiveQualityId` 在调用方没
  /// 指定档位时自然选中它 —— 这正是「网盘媒体库播放器」该有的默认行为。
  ///
  /// 请求头与过期时间沿用各自票据的（夸克各条流走同一套签名参数，
  /// 实测 `audioplay` 与转码 CDN 都只认 Cookie，不认额外头）。
  StreamTicket? _mergeOriginalAndLadder({
    required StreamTicket? original,
    required _PlayInfoResult? info,
  }) {
    final ladder = info?.ticket;
    final base = original ?? ladder;
    if (base == null) return null;

    final meta = info?.meta;
    final qualities = <QualityOption>[
      if (original != null)
        QualityOption(
          id: kOriginalQualityId,
          label: '原画',
          url: original.url,
          isOriginal: true,
          // 服务端给的体积（audioplay 的 `size`）比索引库里那份更权威：
          // 索引库的值来自扫描时的目录列表，这里是读文件头得到的。
          estimatedBytes: original.contentLength,
          // 副标题取自 `play/info` 的 `meta` —— 转码档的副标题来自各自的
          // `video_info`，两边口径要一致，否则原画那行会光秃秃的。
          width: meta?.width,
          height: meta?.height,
          bitrate: meta?.bitrate,
          detail: _originalDetail(meta),
        ),
      ...?ladder?.qualities,
    ];

    return StreamTicket(
      url: base.url,
      headers: base.headers,
      expiresAt: base.expiresAt,
      contentLength: base.contentLength,
      supportsRange: base.supportsRange,
      contentType: base.contentType,
      qualities: qualities,
    );
  }

  /// 原画那一档的副标题（`1920×800 · 7.6 Mbps · MKV`）。元信息缺失时返回 `null`。
  static String? _originalDetail(SourceMeta? meta) {
    if (meta == null) return null;
    final text = QuarkPlayInfoParser.describeSourceMeta(meta);
    return text.isEmpty ? null : text;
  }

  /// 路由 2：`v2/play`（单文件形态）。与 `play/info` 响应同构，实测交叉验证。
  ///
  /// ⚠️ **必须是 `POST {"fid": …}`**。以前这里写的是 `GET ?fid=`，
  /// 实测返回 `405 Request method 'GET' not supported` —— 也就是这条路
  /// 从来没通过，只是它排在降级链里，坏了也没人发现。详见
  /// [QuarkPlayRoute.v2Play] 的文档。
  Future<StreamTicket?> _resolveViaV2Play(String fileId) async {
    final result = await _linkBucket.run(
      () => _request(
        () => _post(QuarkEndpoints.fileV2Play, body: {'fid': fileId}),
        context: '取视频播放直链',
      ),
    );
    return _parsePlayInfoLike(result, 'v2_play')?.ticket;
  }

  /// 路由 1：播放信息预取。**唯一能拿到转码梯度的路由。**
  ///
  /// ⚠️ 它**不给原画** —— `video_list` 里只有转码档。原画走 `audioplay`。
  Future<_PlayInfoResult?> _resolveViaPlayInfo(String fileId) async {
    final result = await _linkBucket.run(
      () => _request(
        () => _post(
          QuarkEndpoints.playInfo,
          body: {
            ...kQuarkPlayInfoBody,
            'fids': [fileId],
          },
          params: {'uc_param_str': 'utfrpr'},
        ),
        context: '取播放信息',
      ),
    );
    return _parsePlayInfoLike(result, 'play_info');
  }

  /// 把 `play/info` / `v2/play` 的响应解成「票据 + 源文件元信息」。
  ///
  /// 两者响应结构实测完全一致（`video_list` / `audio_list` / `meta`），
  /// 所以共用一个解析入口。返回 `null` 表示响应里没有视频档位。
  _PlayInfoResult? _parsePlayInfoLike(HttpResult result, String routeId) {
    final qualities = QuarkPlayInfoParser.parseQualities(result.data);
    if (qualities.isEmpty) {
      diag.info('取链', '$routeId 通了但没有解析出任何视频档位（响应形状可能变了）');
      return null;
    }

    // 排序后第一条 = 最高那一档。它只是**兜底**用的默认地址 ——
    // 正常情况下票据的地址由「原画」决定（见 _mergeOriginalAndLadder）。
    final url = qualities.first.url;
    if (url == null) return null;

    final ticket = QuarkMapper.toStreamTicket(
      url: url,
      cookieHeader: _cookieHeader,
      contentLength: qualities.first.estimatedBytes,
      now: _clock(),
    ).copyWithQualities(qualities);

    _logTicket(routeId, ticket);
    return (
      ticket: ticket,
      meta: QuarkPlayInfoParser.parseSourceMeta(result.data),
    );
  }

  /// 路由 2/3：`GET ?fid=` 形态的简单播放接口。
  ///
  /// 响应形状与 download **不同**：`data` 是一个**扁平对象**
  /// （`{audio_url, size, format_type, duration, ...}`），不是数组。
  /// 所以这里读 [HttpResult.dataMap]。
  ///
  /// 另有一个实测怪癖（参考项目）：DSF 文件返回 `format_type=text/plain`、
  /// `obj_category=doc`、`duration=0`（服务端不把它当音频），
  /// **但仍会返回原文件字节**。因此这里只信 `size` 与地址，
  /// 不拿 `format_type` / `duration` 做判定。
  Future<StreamTicket?> _resolveViaSimpleGet({
    required QuarkPlayRoute route,
    required String fileId,
    required String path,
    required String context,
  }) async {
    final result = await _linkBucket.run(
      () => _request(
        () => _get(path, {'fid': fileId}),
        context: context,
      ),
    );

    final data = result.dataMap;
    if (data == null) {
      diag.info('取链', '${route.id}：data 不是对象，响应形状可能变了');
      return null;
    }

    final url = QuarkMapper.parseDirectUrl(data);
    if (url == null) return null;

    final ticket = QuarkMapper.toStreamTicket(
      url: url,
      cookieHeader: _cookieHeader,
      contentLength: _intOf(data['size']),
      contentType: data['format_type'] as String?,
      now: _clock(),
    );
    _logTicket(route.id, ticket);
    return ticket;
  }

  /// 路由 4：下载直链接口。单文件 >50MiB 会返回 `code=23018`。
  Future<StreamTicket?> _resolveViaDownload(String fileId) async {
    final result = await _linkBucket.run(
      () => _request(
        () => _post(
          QuarkEndpoints.fileDownload,
          body: {
            'fids': [fileId],
          },
        ),
        context: '取播放直链',
      ),
    );

    final items = result.dataListItems;
    if (items.isEmpty) return null;

    final first = items.first;
    final url = QuarkMapper.parseDirectUrl(first);
    if (url == null) return null;

    final ticket = QuarkMapper.toStreamTicket(
      url: url,
      cookieHeader: _cookieHeader,
      contentLength: _intOf(first['size']),
      contentType: first['format_type'] as String?,
      now: _clock(),
    );
    _logTicket('download', ticket);
    return ticket;
  }

  /// 把票据切到指定档位。
  ///
  /// 档位不在票据里时**保留原画并记日志**，而不是抛错：
  /// 用户点了「4K」但服务端这次没给 4K 流，播原画显然比报错好。
  StreamTicket _applyQuality(StreamTicket ticket, String? qualityId) {
    if (qualityId == null || qualityId.isEmpty) return ticket;
    final q = ticket.qualityById(qualityId);
    if (q == null) {
      diag.warn(
        '取链',
        '指定档位 $qualityId 不在本次结果里'
            '（可用=[${describeQualities(ticket.qualities)}]），保留原画',
      );
      return ticket;
    }
    if (!q.isAvailable) {
      diag.warn('取链', '档位 $qualityId 没有地址，保留原画');
      return ticket;
    }
    return ticket.withQuality(q);
  }

  /// 读取小文件的原始字节。
  ///
  /// **本应用的用途是读字幕**（`.srt` / `.ass` 通常几十 KB）：
  /// 中文外挂字幕大量是 GBK，谁先把它解成字符串，非法字节就已经变成 `�`，
  /// 编码判定再也做不了 —— 所以必须拿到**原始字节**，解码交给调用方
  /// （见 `SubtitleResolver` 与 `decodeSubtitleBytes`）。
  ///
  /// 走 download 路由而不是 [resolveStream] 那条播放链：
  ///   1. download 的 50MiB 上限对字幕完全不是问题；
  ///   2. 这里要的是**字节**，不是播放直链。
  ///
  /// 两道体积闸门（声明体积 / 实际字节数）都保留：声明值可能缺失或不准，
  /// 只信其中一道都可能把一个大文件拉进内存。
  @override
  Future<Uint8List> readFileBytes(
    String fileId, {
    int maxBytes = 512 * 1024,
  }) async {
    final ticket = await _resolveViaDownload(fileId);
    if (ticket == null) {
      throw const DriveException(
        type: DriveErrorType.malformedResponse,
        message: '读取文件内容失败：取链响应里没有下载地址',
      );
    }

    final declared = ticket.contentLength;
    if (declared != null && declared > maxBytes) {
      throw DriveException(
        type: DriveErrorType.fileTooLarge,
        message: '文件声明体积 ${declared}B 超出读取上限 ${maxBytes}B，不按小文本文件读取',
      );
    }

    diag.info('读文件', '开始读取 fid=$fileId，声明体积=${declared ?? "未知"}');
    final bytes = await _http.getBytes(ticket.url.toString(), headers: ticket.headers);
    if (bytes == null) {
      throw const DriveException(
        type: DriveErrorType.network,
        message: '读取文件内容失败：网络层未返回响应',
      );
    }
    if (bytes.length > maxBytes) {
      throw DriveException(
        type: DriveErrorType.fileTooLarge,
        message: '文件实际体积 ${bytes.length}B 超出读取上限 ${maxBytes}B',
      );
    }

    diag.info('读文件', '读取完成 fid=$fileId，实际 ${bytes.length}B');
    return bytes;
  }

  @override
  Future<void> dispose() async {
    _credential = null;
    _account = null;
    _http.close();
  }

  // -------------------------------------------------------------------
  // 文件管理：创建目录 / 删除 / 上传
  // -------------------------------------------------------------------

  /// 在指定目录下创建文件夹。
  ///
  /// 同名重复创建幂等（夸克服务端返回已有 fid）。
  @override
  Future<String> createFolder({
    required String parentId,
    required String name,
  }) async {
    diag.info('文件', '创建目录「$name」于 parentId=$parentId');

    final result = await _request(
      () => _post(QuarkEndpoints.fileCreate, body: {
        'dir_init_lock': false,
        'dir_path': '',
        'file_name': name,
        'pdir_fid': parentId.isEmpty ? rootId : parentId,
      }),
      context: '创建目录',
    );

    final fid = QuarkMapper.parseFid(result.dataMap);
    if (fid == null || fid.isEmpty) {
      throw const DriveException(
        type: DriveErrorType.malformedResponse,
        message: '创建目录失败：响应中没有返回目录 ID',
      );
    }
    diag.info('文件', '目录已创建/已存在「$name」→ fid=$fid');
    return fid;
  }

  /// 删除文件/文件夹。
  ///
  /// ⚠️ 不可逆操作。调用方必须做 UI 二次确认。
  @override
  Future<List<String>> deleteFiles({required List<String> fileIds}) async {
    if (fileIds.isEmpty) return const [];

    diag.warn('文件', '删除 ${fileIds.length} 个文件：${fileIds.join(", ")}');

    final result = await _request(
      () => _post(QuarkEndpoints.fileDelete, body: {
        'action_type': 2, // 永久删除
        'filelist': fileIds,
        'exclude_fids': [],
      }),
      context: '删除文件',
    );

    diag.info('文件', '已删除 ${fileIds.length} 个文件');
    return fileIds;
  }

  /// 上传一个本地文件到夸克网盘。
  ///
  /// 流程（参考夸克 PC 客户端逆向 + quark-drive Python 实现）：
  /// 1. `POST /file/upload/pre` —— 预上传（含文件名、大小、目录）。
  ///    返回 `task_id` 与 COS 上传信息（`bucket`/`obj_key`/`upload_id`/`auth_info`）。
  /// 2. 计算全文件 SHA1 + MD5，调 `POST /file/update/hash` 做秒传判定。
  ///    `finish=1` → 秒传命中，直接返回 `fid`。
  /// 3. 秒传未命中时，分片 PUT 到 COS，逐片获取 ETag。
  /// 4. `POST /file/upload/finish` 提交 ETag 列表，服务端返回最终 `fid`。
  ///
  /// ⚠️ 小文件（<50MiB）走 `POST /file/download` 也能拿到直链，
  /// 但**上传**必须走预上传流程 —— 那是唯一能往网盘写入文件的路径。
  @override
  Future<String> uploadFile({
    required String parentId,
    required String fileName,
    required List<int> bytes,
    void Function(int sent, int total)? onProgress,
  }) async {
    final size = bytes.length;
    final nowMs = _clock().millisecondsSinceEpoch;
    final pdirFid = parentId.isEmpty ? rootId : parentId;

    diag.info('上传', '开始上传「$fileName」（$size B）到 parentId=$pdirFid');

    // ① 预上传
    final preResult = await _request(
      () => _post(QuarkEndpoints.uploadPre, body: {
        'ccp_hash_update': true,
        'dir_name': '',
        'file_name': fileName,
        'format_type': 'application/octet-stream',
        'l_created_at': nowMs,
        'l_updated_at': nowMs,
        'pdir_fid': pdirFid,
        'size': size,
      }),
      context: '上传预请求',
    );

    final preData = preResult.dataMap;
    if (preData == null) {
      throw const DriveException(
        type: DriveErrorType.malformedResponse,
        message: '上传预请求失败：响应中没有 data',
      );
    }

    final taskId = preData['task_id'] as String? ?? '';
    if (taskId.isEmpty) {
      throw const DriveException(
        type: DriveErrorType.malformedResponse,
        message: '上传预请求失败：没有返回 task_id',
      );
    }

    // ② 计算哈希，尝试秒传
    final sha1 = _computeSha1(bytes);
    final md5 = _computeMd5(bytes);

    diag.debug('上传', '文件哈希：sha1=${sha1.substring(0, 16)}…, '
        'md5=${md5.substring(0, 16)}…, task=$taskId');

    // 复用 _request 包装做业务码校验
    final hashResult = await _request(
      () => _post(QuarkEndpoints.uploadHash, body: {
        'md5': md5,
        'sha1': sha1,
        'task_id': taskId,
      }),
      context: '秒传判定',
    );

    final hashData = hashResult.dataMap;
    if (hashData != null && hashData['finish'] == true) {
      final fid = QuarkMapper.parseFid(hashData);
      if (fid != null && fid.isNotEmpty) {
        diag.info('上传', '秒传命中！「$fileName」→ fid=$fid');
        onProgress?.call(size, size);
        return fid;
      }
    }

    // ③ 分片上传到 COS
    //
    // 预上传响应中应包含 COS 上传信息（bucket / obj_key / upload_id /
    // auth_info / upload_url / part_size）。
    // 夸克服务端返回的 `part_size` 通常为 4MB。
    final partSize = QuarkMapper.asInt(preData['part_size']) ??
        QuarkMapper.asInt(preData['metadata'] is Map
            ? (preData['metadata'] as Map)['part_size']
            : null) ??
        4 * 1024 * 1024;

    final bucket = preData['bucket'] as String? ?? '';
    final objKey = preData['obj_key'] as String? ?? '';
    final uploadId = preData['upload_id'] as String? ?? '';
    final authInfo = preData['auth_info'];
    final uploadUrlBase = preData['upload_url'] as String? ?? '';

    if (bucket.isEmpty || objKey.isEmpty || uploadId.isEmpty) {
      throw DriveException(
        type: DriveErrorType.malformedResponse,
        message: '上传预请求未返回 COS 信息（bucket/obj_key/upload_id 缺失）'
            '—— 分片上传无法继续。响应键：${preData.keys.toList()}',
      );
    }

    // 构造 OSS 基地址
    final base = uploadUrlBase
        .replaceAll('http://', '')
        .replaceAll('https://', '');
    final ossBase = 'https://$bucket.$base/$objKey';

    final totalParts = (size / partSize).ceil();
    final etags = <Map<String, Object?>>[];

    diag.info('上传', '分片上传：$totalParts 片 × ${_formatBytes(partSize)}'
        '（OSS: $bucket/$objKey）');

    for (var pn = 1; pn <= totalParts; pn++) {
      final offset = (pn - 1) * partSize;
      final end = (offset + partSize > size) ? size : offset + partSize;
      final partData = bytes.sublist(offset, end);

      // 向夸克获取这片的上传授权
      final ts = _ossTimestamp();
      final metaStr = 'PUT\n\napplication/octet-stream\n$ts\n'
          'x-oss-date:$ts\nx-oss-user-agent:aliyun-sdk-js/6.6.1\n'
          '/$bucket/$objKey?partNumber=$pn&uploadId=$uploadId';

      final authResult = await _request(
        () => _post(QuarkEndpoints.uploadAuth, body: {
          'auth_info': authInfo,
          'auth_meta': metaStr,
          'task_id': taskId,
        }),
        context: '分片授权($pn/$totalParts)',
      );

      final authKey = authResult.dataMap?['auth_key'] as String? ?? '';

      // PUT 到 OSS
      final partUrl = '$ossBase?partNumber=$pn&uploadId=$uploadId';
      final etag = await _http.putBytes(
        partUrl,
        body: partData,
        headers: {
          'Authorization': authKey,
          'Content-Type': 'application/octet-stream',
          'Referer': QuarkEndpoints.referer,
          'x-oss-date': ts,
          'x-oss-user-agent': 'aliyun-sdk-js/6.6.1',
        },
      );

      etags.add({
        'part_number': pn,
        'etag': etag.replaceAll('"', ''),
      });

      onProgress?.call(end, size);
      diag.debug('上传', '分片 $pn/$totalParts 完成'
          '（${_formatBytes(end)}/${_formatBytes(size)}）');
    }

    // ④ 完成上传
    final finishResult = await _request(
      () => _post(QuarkEndpoints.uploadFinish, body: {
        'task_id': taskId,
        'part_info_list': etags,
      }),
      context: '完成上传',
    );

    final fid = QuarkMapper.parseFid(finishResult.dataMap);
    if (fid == null || fid.isEmpty) {
      throw const DriveException(
        type: DriveErrorType.malformedResponse,
        message: '上传完成响应中没有返回文件 ID',
      );
    }

    diag.info('上传', '「$fileName」上传完成 → fid=$fid');
    return fid;
  }

  /// 计算 SHA1（hex 小写）。
  ///
  /// 用 `package:crypto`（Flutter SDK 传递依赖，已在 pubspec.lock 中）。
  static String _computeSha1(List<int> bytes) {
    return crypto.sha1.convert(bytes).toString();
  }

  /// 计算 MD5（hex 小写）。
  static String _computeMd5(List<int> bytes) {
    return crypto.md5.convert(bytes).toString();
  }

  static String _ossTimestamp() {
    final now = DateTime.now().toUtc();
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${days[now.weekday - 1]}, ${now.day.toString().padLeft(2, '0')} '
        '${months[now.month - 1]} ${now.year} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')} GMT';
  }

  static String _formatBytes(int n) {
    if (n < 1024) return '${n}B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)}KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  // -------------------------------------------------------------------
  // 内部
  // -------------------------------------------------------------------

  /// 把票据的关键事实写进诊断日志。
  ///
  /// **直链地址本身绝不能进日志** —— 查询串里带着可用的签名令牌。
  /// 这里只留「协议+主机+路径」，足够看出是不是同一条 CDN 路由，
  /// 又不至于把播放权限泄露到磁盘上。
  static void _logTicket(String route, StreamTicket ticket) {
    diag.info(
      '取链',
      '路由 $route 签发票据：${ticket.redactedUrl}，'
      '声明体积=${ticket.contentLength ?? "未知"}，'
      '随票据请求头=${ticket.headers.isEmpty ? "无" : ticket.headers.keys.join(",")}，'
      '过期=${ticket.expiresAt ?? "未声明"}，'
      '档位=[${describeQualities(ticket.qualities)}]',
    );
  }

  /// 把 [DriveException] 拆成一行可读的诊断描述。
  static String _describe(DriveException e) =>
      'type=${e.type.name} needsReauth=${e.needsReauth} '
      'http=${e.httpStatus ?? "-"} providerCode=${e.providerCode ?? "-"} '
      'message=${e.message}'
      '${e.rawMessage == null ? "" : " raw=${e.rawMessage}"}';

  /// 拉取账号信息，顺带完成会话校验。
  Future<CloudAccount> _fetchMember() async {
    final result = await _request(
      () => _get(QuarkEndpoints.member, {'uc_param_str': ''}),
      context: '获取账号信息',
    );

    final base = CloudAccount(
      provider: DriveProvider.quark,
      authMode: _credential?.mode ?? AuthMode.browserCookie,
      authorizedAt: _credential?.capturedAt ?? _clock(),
    );

    final data = result.dataMap;
    if (data == null) return base;
    return QuarkMapper.mergeAccountInfo(base, data);
  }

  /// 统一请求包装：注入公共参数与请求头，校验业务码，归一化异常。
  Future<HttpResult> _request(
    Future<HttpResult> Function() call, {
    String? context,
  }) async {
    if (!hasSession) {
      diag.error('接口', '${context ?? "请求"}：尚未授权（没有 Cookie）');
      throw DriveException(
        type: DriveErrorType.unauthorized,
        message: '${context ?? "请求"}：尚未授权夸克账号',
      );
    }

    final result = await call();
    if (!isQuarkSuccess(result)) {
      final e = quarkExceptionFrom(result, context: context);
      diag.error('接口', '${context ?? "请求"} 业务失败', error: _describe(e));
      throw e;
    }
    _absorbRotatedCookies(result);
    return result;
  }

  /// 响应 Cookie 轮换回填（浏览器 cookie jar 的等价物）。
  ///
  /// 夸克服务端会在**每个** API 响应的 `Set-Cookie` 里轮换下发 `__puus`
  ///（参考项目实测：`/member`、`/file/sort`、`/file/audioplay` 每响应必带）。
  /// CDN 直链的防重放校验依赖**最新**的 `__puus` —— 缺它直链一律 412。
  /// 浏览器里 cookie jar 自动完成这件事；我们手动管理 Cookie，必须在
  /// 每个响应后把新值回填进内存凭证，下一个请求（尤其是直链）才能带上。
  ///
  /// ⚠️ 故意**不落库**：扫描时每页都轮换，逐次重写安全存储开销大且无意义 ——
  /// 重启后首次 API 响应就会下发新 `__puus`，本方法会立刻补上。
  void _absorbRotatedCookies(HttpResult result) {
    final credential = _credential;
    if (credential == null) return;

    final lines = result.setCookieLines;
    if (lines.isEmpty) return;

    final fresh = parseSetCookieLines(lines);
    if (fresh.isEmpty) return;

    final current = credential.cookies;
    final updates = <String, String>{};
    for (final name in QuarkEndpoints.knownCookieNames) {
      final v = fresh[name];
      if (v == null || v.isEmpty) continue;
      if (current[name] == v) continue;
      updates[name] = v;
    }
    if (updates.isEmpty) return;

    _credential = credential.copyWith(
      cookies: {...current, ...updates},
      capturedAt: DateTime.now(),
    );
    diag.debug('会话', '响应 Cookie 轮换回填：${updates.keys.toList()}');
  }

  Map<String, String> _headers() => {
        'User-Agent': QuarkEndpoints.userAgent,
        'Accept': QuarkEndpoints.accept,
        'Accept-Language': QuarkEndpoints.acceptLanguage,
        'Referer': QuarkEndpoints.referer,
        'Origin': QuarkEndpoints.origin,
        'Cookie': _cookieHeader,
      };

  /// 缩略图 / 预览图地址的归属判定。
  ///
  /// 夸克给的是绝对地址（`https://drive-pc.quark.cn/1/clouddrive/file/video/…`），
  /// 也可能来自备用网关。两个域都认。
  @override
  bool ownsUrl(String url) =>
      url.contains('quark.cn') || url.contains('drive-pc.quark.cn');

  /// 取缩略图时带的请求头。
  ///
  /// **每次现取**，不复用、不缓存 —— 夸克在每个 API 响应里轮换 `__puus`，
  /// 而 `_cookieHeader` 读的是内存里刚回填过的那份。实测用陈旧 Cookie 打
  /// `/file/video/thumbnail` 会拿到 `401 auth expired`，表现是海报墙上一片
  /// 灰块，且没有任何报错指向 Cookie。
  @override
  Map<String, String> imageHeaders() => _headers();

  Future<HttpResult> _get(String path, [Map<String, Object?>? params]) =>
      _http.get(
        '$_gateway$path',
        query: {...QuarkEndpoints.commonParams, ...?params},
        headers: _headers(),
      );

  Future<HttpResult> _post(
    String path, {
    Object? body,
    Map<String, Object?>? params,
  }) =>
      _http.post(
        '$_gateway$path',
        body: body,
        query: {...QuarkEndpoints.commonParams, ...?params},
        headers: {..._headers(), 'Content-Type': 'application/json'},
      );

  /// 分页游标解析。非法值回落到第 1 页。
  static int _parsePageToken(String? token) {
    if (token == null || token.isEmpty) return 1;
    final n = int.tryParse(token);
    if (n == null || n < 1) return 1;
    return n;
  }

  static int? _intOf(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}

/// 给 [StreamTicket] 补一个「带上档位」的复制方法。
///
/// 放在这里而不是实体里：实体不该知道「档位是适配器解析出来的」这件事，
/// 而 `withQuality` 是播放期的行为。
extension StreamTicketQualities on StreamTicket {
  StreamTicket copyWithQualities(List<QualityOption> qualities) => StreamTicket(
        url: url,
        headers: headers,
        expiresAt: expiresAt,
        contentLength: contentLength,
        supportsRange: supportsRange,
        contentType: contentType,
        qualities: qualities,
      );
}
