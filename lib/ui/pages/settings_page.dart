import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/remote/subtitle/opensubtitles_client.dart';
import '../../data/scrape/douban_client.dart';
import '../../data/scrape/tmdb_client.dart';
import '../../domain/entities/cloud_account.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/entities/quality_option.dart';
import '../../domain/services/library_backup_service.dart';
import '../providers/app_providers.dart';
import '../providers/auth_providers.dart';
import '../providers/library_providers.dart';
import '../providers/library_refresh_providers.dart';
import '../providers/settings_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/app_logo.dart';
import '../widgets/common_widgets.dart';

/// 版本号。**必须与 `pubspec.yaml` 的 `version` 保持一致。**
///
/// 没有引入 `package_info_plus`：它为了一个字符串拖进来一条平台通道，
/// 而这条通道在单元测试里必须被 mock 掉。多一处 mock 就多一处
/// 「测试里是好的、真机上是空的」。
const String _kAppVersion = '0.1.0';

/// 设置页。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final TextEditingController _tmdbKey = TextEditingController();
  final TextEditingController _tmdbApiBase = TextEditingController();
  final TextEditingController _tmdbImageBase = TextEditingController();
  final TextEditingController _doubanCookie = TextEditingController();
  final TextEditingController _opensubtitlesKey = TextEditingController();
  final TextEditingController _opensubtitlesBase = TextEditingController();

  /// 输入框是否已经从设置里填过一次。
  ///
  /// 只填一次、之后**不再覆盖** —— 否则用户正在输入时，
  /// 任何一次设置变更都会把输入框重置回去。
  bool _fieldsLoaded = false;

  /// 「测试连接」的结果文案与忙碌标记。
  String? _probeResult;
  bool _probeOk = false;
  bool _probing = false;

  /// 在线字幕那一个「测试连接」。**与 TMDB 那个分开**：两件事互不影响，
  /// 共用一个状态会让「TMDB 探测失败」把字幕那边的结果也清掉。
  String? _subsProbeResult;
  bool _subsProbeOk = false;
  bool _subsProbing = false;

  /// 豆瓣的「测试连接」。同样独立一份状态，理由同上。
  String? _doubanProbeResult;
  bool _doubanProbeOk = false;
  bool _doubanProbing = false;

  /// 海报缓存占用的字节数。`null` 表示还在算。
  int? _cacheBytes;

  /// 清空索引库的忙碌标记（清库是异步的，期间要禁用按钮）。
  bool _wiping = false;

  @override
  void dispose() {
    _tmdbKey.dispose();
    _tmdbApiBase.dispose();
    _tmdbImageBase.dispose();
    _doubanCookie.dispose();
    _opensubtitlesKey.dispose();
    _opensubtitlesBase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final stats = ref.watch(libraryStatsProvider).valueOrNull;

    // 设置读出来之后填一次输入框。之后**不再覆盖** ——
    // 否则用户正在输入时，任何一次设置变更都会把输入框重置回去。
    final s = settings.valueOrNull;
    if (s != null && !_fieldsLoaded) {
      _fieldsLoaded = true;
      _tmdbKey.text = s.tmdbApiKey;
      _tmdbApiBase.text = s.tmdbApiBase;
      _tmdbImageBase.text = s.tmdbImageBase;
      _doubanCookie.text = s.doubanCookie;
      _opensubtitlesKey.text = s.opensubtitlesApiKey;
      _opensubtitlesBase.text = s.opensubtitlesBase;
    }

    if (settings.isLoading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final current = s ?? const AppSettings();

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: '设置'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _AccountCard(
                  account: auth?.account,
                  canPersist: auth?.canPersist ?? true,
                  onSignOut: () => _confirmSignOut(),
                ),
                const SizedBox(height: 14),
                _scanSection(current),
                const SizedBox(height: 14),
                _scrapeSection(current),
                const SizedBox(height: 14),
                _playbackSection(current),
                const SizedBox(height: 14),
                _subtitleSection(current),
                const SizedBox(height: 14),
                _storageSection(stats),
                const SizedBox(height: 14),
                _backupSection(current),
                const SizedBox(height: 14),
                _aboutSection(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------
  // 扫描
  // -------------------------------------------------------------------

  Widget _scanSection(AppSettings s) {
    return SectionCard(
      title: '扫描',
      description: '全盘遍历会真实打网盘接口，配额与风控都是硬约束。'
          '间隔调小能让扫描更快，但更容易被限流。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SliderRow(
            label: '请求间隔',
            valueLabel: '${s.scanIntervalMs} ms '
                '（约 ${(1000 / s.scanIntervalMs).toStringAsFixed(1)} QPS）',
            value: s.scanIntervalMs.toDouble(),
            min: 0,
            max: 1500,
            divisions: 15,
            onChanged: (v) => unawaited(
              ref
                  .read(settingsProvider.notifier)
                  .set(scanIntervalMs: v.round()),
            ),
          ),
          const SizedBox(height: 6),
          _SliderRow(
            label: '最大递归深度',
            valueLabel: '${s.scanMaxDepth} 层',
            value: s.scanMaxDepth.toDouble(),
            min: 2,
            max: 30,
            divisions: 28,
            onChanged: (v) => unawaited(
              ref.read(settingsProvider.notifier).set(scanMaxDepth: v.round()),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '夸克实测约 3 QPS 安全，默认 350ms 就是照这个定的。'
            '调成 0 会关闭节流，只建议在目录很少时用。',
            style: TextStyle(fontSize: 11, height: 1.7, color: AppTheme.dim),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------
  // 刮削
  // -------------------------------------------------------------------

  Widget _scrapeSection(AppSettings s) {
    return SectionCard(
      title: '刮削',
      description: '本地文件名解析**永远可用**，不需要联网。'
          '联网刮削只是把它增强成海报与简介。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ToggleRow(
            label: '联网刮削',
            hint: s.canScrapeOnline
                ? '已启用。作品详情页会出现「刮削」按钮。'
                : '未启用。打开后还需要至少配一个数据源（TMDB Key 或豆瓣 Cookie）。',
            value: s.onlineScrape,
            onChanged: (v) => unawaited(
              ref.read(settingsProvider.notifier).set(onlineScrape: v),
            ),
          ),
          const SizedBox(height: 4),
          _ToggleRow(
            label: '扫描后自动刮削',
            hint: s.canAutoScrape
                ? '扫描结束后会自动为还没刮过的作品查一遍。'
                    '豆瓣匿名额度很小，全盘自动刮容易被限流。'
                : '默认关闭。刮削改由作品详情页的「刮削」按钮按需触发 —— '
                    '豆瓣匿名额度实测只有约 10 个搜索词，全盘自动刮会中途耗尽。',
            value: s.autoScrapeOnScan,
            onChanged: (v) => unawaited(
              ref.read(settingsProvider.notifier).set(autoScrapeOnScan: v),
            ),
          ),

          const SizedBox(height: 16),
          const Divider(height: 1, color: AppTheme.line),
          const SizedBox(height: 14),

          const Text(
            'TMDB（首选）',
            style: TextStyle(fontSize: 12.5, color: AppTheme.text),
          ),
          const SizedBox(height: 4),
          const Text(
            '元数据最全：简介、类型、原始标题都有。'
            '境内直连 api.themoviedb.org 与 image.tmdb.org 通常会被 DNS 污染，'
            '不通的话填一个可达的反代地址，或者只用下面的豆瓣。',
            style: TextStyle(fontSize: 11, height: 1.7, color: AppTheme.dim),
          ),
          const SizedBox(height: 12),
          _savableField(
            controller: _tmdbKey,
            label: 'TMDB API Key',
            hint: 'v3 的 API Key，或 v4 的 Read Access Token',
            saved: s.tmdbApiKey,
            onSave: () => ref
                .read(settingsProvider.notifier)
                .set(tmdbApiKey: _tmdbKey.text),
          ),
          const SizedBox(height: 12),
          _savableField(
            controller: _tmdbApiBase,
            label: 'API 地址',
            hint: TmdbScraper.defaultBaseUrl,
            saved: s.tmdbApiBase,
            onSave: () => ref
                .read(settingsProvider.notifier)
                .set(tmdbApiBase: _tmdbApiBase.text),
          ),
          const SizedBox(height: 10),
          _savableField(
            controller: _tmdbImageBase,
            label: '图片地址',
            hint: TmdbScraper.defaultImageBaseUrl,
            saved: s.tmdbImageBase,
            onSave: () => ref
                .read(settingsProvider.notifier)
                .set(tmdbImageBase: _tmdbImageBase.text),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              OutlinedButton.icon(
                onPressed: _probing ? null : () => unawaited(_probeTmdb()),
                icon: _probing
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering_rounded, size: 15),
                label: const Text('测试连接'),
              ),
              const SizedBox(width: 12),
              if (_probeResult != null)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _probeResult!,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.6,
                        color: _probeOk ? AppTheme.ok : AppTheme.warn,
                      ),
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 16),
          const Divider(height: 1, color: AppTheme.line),
          const SizedBox(height: 14),

          const Text(
            '豆瓣（境内可达，补国产剧 / 国漫 / 综艺）',
            style: TextStyle(fontSize: 12.5, color: AppTheme.text),
          ),
          const SizedBox(height: 4),
          const Text(
            'TMDB 最弱的一块恰好是国产内容，而豆瓣两者都强、境内直连就能用。'
            '但它的匿名额度实测只有约 10 个搜索词，耗尽后接口直接返回'
            '「需要登录」，所以必须填登录后的 Cookie。',
            style: TextStyle(fontSize: 11, height: 1.7, color: AppTheme.dim),
          ),
          const SizedBox(height: 12),
          _cookieHelp(),
          const SizedBox(height: 12),
          _savableField(
            controller: _doubanCookie,
            label: '豆瓣 Cookie',
            hint: '从 `ll=` 或 `bid=` 开始那一段，必须含 dbcl2',
            saved: s.doubanCookie,
            onSave: () => ref
                .read(settingsProvider.notifier)
                .set(doubanCookie: _doubanCookie.text),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              OutlinedButton.icon(
                onPressed:
                    _doubanProbing ? null : () => unawaited(_probeDouban()),
                icon: _doubanProbing
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering_rounded, size: 15),
                label: const Text('测试连接'),
              ),
              const SizedBox(width: 12),
              if (_doubanProbeResult != null)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _doubanProbeResult!,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.6,
                        color: _doubanProbeOk ? AppTheme.ok : AppTheme.warn,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            '它存在本地数据库里，不会外传，也**不会**用来下载海报'
            '（豆瓣图片只要 Referer）。',
            style: TextStyle(fontSize: 11, height: 1.7, color: AppTheme.dim),
          ),

          const SizedBox(height: 16),
          const Text(
            '两个源**同时**生效，按优先级取结果：TMDB 优先，它没命中才用豆瓣，'
            '两个都没命中就退回文件名解析。',
            style: TextStyle(fontSize: 11, height: 1.7, color: AppTheme.dim),
          ),
        ],
      ),
    );
  }

  /// 「豆瓣 Cookie 怎么拿、长什么样」的折叠说明。
  ///
  /// ## 为什么必须写这一段
  ///
  /// 豆瓣的 rexxar 接口不认「只填 dbcl2 就够了」这种简化说法：**少了 `bid`
  /// 会退化成匿名额度**（约 10 个搜索词），而失败表现是服务端回 103 ——
  /// 看起来跟「被限流」一模一样。用户拿不到正确的格式就只能靠猜，猜错的
  /// 代价是「填了 Cookie 还是刮不到」。
  ///
  /// 折叠而不是直接铺开：这段有七八行，常驻会把「填哪、填完点哪」这两件
  /// 正事埋掉。
  Widget _cookieHelp() {
    const step = TextStyle(fontSize: 11, height: 1.7, color: AppTheme.dim);

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.panel2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.line, width: 0.5),
      ),
      child: Theme(
        // ExpansionTile 默认给子节点加一条分隔线，在深色卡片里很脏。
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          iconColor: AppTheme.muted,
          collapsedIconColor: AppTheme.muted,
          title: const Text(
            '怎么拿到 Cookie？格式是什么样？',
            style: TextStyle(fontSize: 12, color: AppTheme.text),
          ),
          children: [
            const Text(
              '1. 浏览器登录 https://movie.douban.com\n'
              '2. 按 F12 → Network（网络）→ 刷新页面\n'
              '3. 点任意一条发往 douban.com 的请求 → '
              'Request Headers（请求标头）→ 找到 `Cookie:` 那一行\n'
              '4. 复制**冒号后面**的整段值，粘到上面的输入框',
              style: step,
            ),
            const SizedBox(height: 10),
            const Text(
              '必须包含 `dbcl2="数字:字母"`（登录令牌）。'
              '**只贴 `bid` 是匿名态**，额度只有约 10 个搜索词。\n'
              '`__utma` / `__utmb` / `__utmz` / `_vwo_uuid_v2` 是统计字段，'
              '带不带都行。',
              style: step,
            ),
            const SizedBox(height: 10),
            const Text('示例（值已替换成假值）：', style: step),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.bg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppTheme.line, width: 0.5),
              ),
              child: Text(
                'll="108304"; bid=AbCdEfGhIj; dbcl2="188770628:XyZ1234567"; '
                'frodotk_db="17edbcbd7780692347c9363866813b69"',
                style: AppTheme.mono.copyWith(
                  fontSize: 11,
                  height: 1.7,
                  color: AppTheme.text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「改了才出现保存按钮」的输入框。
  ///
  /// 抽出来是因为 Key / API 地址 / 图片地址三个字段长得完全一样 ——
  /// 复制三份的话，以后改一次配色要改三处。
  ///
  /// 脏值判断直接拿 `controller.text` 与已保存的值比，**不另设标志位**：
  /// 标志位需要在保存成功时手工复位，一旦漏了就会出现
  /// 「明明保存过了、按钮还挂着」。
  Widget _savableField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required String saved,
    required VoidCallback onSave,
  }) {
    final dirty = controller.text.trim() != saved.trim();

    return TextField(
      controller: controller,
      // 只为重算上面的 `dirty`。
      onChanged: (_) => setState(() {}),
      style: AppTheme.mono.copyWith(color: AppTheme.text, fontSize: 12),
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        labelStyle: const TextStyle(fontSize: 12, color: AppTheme.muted),
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
        suffixIcon: dirty
            ? TextButton(
                onPressed: () {
                  onSave();
                  setState(() {});
                },
                child: const Text('保存'),
              )
            : null,
        filled: true,
        fillColor: AppTheme.panel2,
        border: _fieldBorder(AppTheme.line, 0.5),
        enabledBorder: _fieldBorder(AppTheme.line, 0.5),
        focusedBorder: _fieldBorder(AppTheme.accent, 0.8),
      ),
    );
  }

  static OutlineInputBorder _fieldBorder(Color color, double width) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: color, width: width),
      );

  /// 探一次 TMDB，把「地址通不通、Key 对不对」直接告诉用户。
  ///
  /// ## 为什么必须有这个按钮
  ///
  /// 2026-10-01 实测：境内直连官方地址会被 DNS 污染，表现为请求一直挂到超时。
  /// 没有它的话，用户填完地址只能「等下次扫描看有没有海报」—— 而扫描要跑几分钟，
  /// 且「地址不通」与「Key 无效」两种失败混在一起，从结果上根本分不出来。
  ///
  /// 打的是 `/configuration`：它不需要任何查询词，只要地址与 Key 都对就返回 200，
  /// 是能区分这两类失败的最小请求。
  Future<void> _probeTmdb() async {
    final key = _tmdbKey.text.trim();
    final base = _tmdbApiBase.text.trim().isEmpty
        ? TmdbScraper.defaultBaseUrl
        : _tmdbApiBase.text.trim();

    setState(() {
      _probing = true;
      _probeResult = null;
    });

    String message;
    var ok = false;
    try {
      if (key.isEmpty) {
        message = '请先填入 API Key。';
      } else {
        // v4 的 Read Access Token 是 JWT（`eyJ` 开头），走 Bearer 头；
        // v3 的短 Key 走 `api_key` 查询参数。与 `TmdbScraper._get` 同一套判据。
        final isJwt = key.startsWith('eyJ');
        final res = await ref.read(httpClientProvider).get(
              '$base/configuration',
              headers: {
                'Accept': 'application/json',
                if (isJwt) 'Authorization': 'Bearer $key',
              },
              query: isJwt ? null : <String, Object?>{'api_key': key},
              timeout: const Duration(seconds: 10),
            );

        if (res.isNetworkFailure) {
          message = '连不上 $base —— 地址不可达。'
              '境内直连官方地址多为 DNS 污染，请填一个可达的反代地址。';
        } else if (res.isSuccessStatus) {
          ok = true;
          message = '连接正常，地址与 Key 都可用。';
        } else if (res.statusCode == 401) {
          message = '地址可达，但 Key 被拒绝（401）—— 检查 Key 是否填错或已失效。';
        } else {
          message = '地址可达，但返回 HTTP ${res.statusCode}。';
        }
      }
    } catch (e) {
      message = '测试失败：$e';
    }

    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeOk = ok;
      _probeResult = message;
    });
  }

  /// 探一次豆瓣，把「接口通不通 / Cookie 是不是登录态 / 有没有被限流」
  /// 直接告诉用户。
  ///
  /// ## 为什么 TMDB 有按钮豆瓣却没有，是说不通的
  ///
  /// 2026-10-01 实测：用户填完 Cookie 之后唯一的验证方式是「刮一部看看」，
  /// 而那要先等 TMDB 超时 20 秒，最后只给一句「未命中」。三种完全不同的
  /// 原因 —— 地址不通、Cookie 不是登录态、出口 IP 被限流 —— 在结果上
  /// 长得一模一样，用户只能反复试。
  ///
  /// 这里**直接用输入框里当前的值**（不读已保存的设置）：用户改完还没点
  /// 「保存」就想先试试，是最自然的操作顺序。
  Future<void> _probeDouban() async {
    final cookie = _doubanCookie.text.trim();

    setState(() {
      _doubanProbing = true;
      _doubanProbeResult = null;
    });

    var ok = false;
    String message;
    try {
      // 常见的两种贴错方式，先拦下来 —— 它们都会让服务端回 103，
      // 而 103 看起来像「被限流」，用户会往完全错误的方向查。
      if (DoubanScraper.looksLikeRawHeader(cookie)) {
        message = '看起来把 `Cookie: ` 这个前缀也一起贴进来了。'
            '只要冒号后面的内容 —— 从 `ll=` 或 `bid=` 开始那一段。';
      } else {
        final result = await DoubanScraper(
          http: ref.read(httpClientProvider),
          cookie: cookie,
        ).probe();
        ok = result.ok;
        message = result.message;
      }
    } catch (e) {
      message = '测试失败：$e';
    }

    if (!mounted) return;
    setState(() {
      _doubanProbing = false;
      _doubanProbeOk = ok;
      _doubanProbeResult = message;
    });
  }

  // -------------------------------------------------------------------
  // 播放
  // -------------------------------------------------------------------

  Widget _playbackSection(AppSettings s) {
    return SectionCard(
      title: '播放',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 110,
                child: Text(
                  '默认清晰度',
                  style: TextStyle(fontSize: 12.5, color: AppTheme.text),
                ),
              ),
              Expanded(
                child: DropdownButton<String>(
                  value: s.defaultQuality,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  dropdownColor: AppTheme.panel2,
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.text),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('原画优先')),
                    for (final id in _qualityPresets)
                      DropdownMenuItem(
                        value: id,
                        child: Text(QualityLabels.labelFor(id)),
                      ),
                  ],
                  onChanged: (v) => unawaited(
                    ref
                        .read(settingsProvider.notifier)
                        .set(defaultQuality: v ?? ''),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '只在服务端提供了对应档位时生效；没有该档位会自动降级到最接近的一档。',
            style: TextStyle(fontSize: 11, height: 1.7, color: AppTheme.dim),
          ),
          const SizedBox(height: 10),
          _ToggleRow(
            label: '自动加载字幕',
            hint: '打开时优先选中文轨；关闭后要手动在播放器里选。',
            value: s.autoLoadSubtitles,
            onChanged: (v) => unawaited(
              ref.read(settingsProvider.notifier).set(autoLoadSubtitles: v),
            ),
          ),
          _ToggleRow(
            label: '记住播放进度',
            hint: '记录「最近播放」与续播位置。',
            value: s.rememberPosition,
            onChanged: (v) => unawaited(
              ref.read(settingsProvider.notifier).set(rememberPosition: v),
            ),
          ),
        ],
      ),
    );
  }

  /// 常见档位标识。**不是**固定梯度表 —— 只是给用户一个下拉可选的范围，
  /// 实际有没有这一档由服务端决定（见 `QualityOption` 的类文档）。
  static const List<String> _qualityPresets = [
    '4k',
    '2k',
    'super',
    'high',
    'normal',
    'low',
  ];

  // -------------------------------------------------------------------
  // 在线字幕
  // -------------------------------------------------------------------

  /// 字幕这一节。
  ///
  /// ## 为什么单独一节，而不是塞进「刮削」
  ///
  /// 它不是刮削源：刮削改的是**库里的元数据**（海报、简介），而这里配的是
  /// 播放器里的「去网上搜一条字幕」。混在一起会让人以为「关了联网刮削就搜不到
  /// 字幕」—— 而实际上两条路完全独立。
  ///
  /// 另外三路字幕（内嵌轨、网盘同目录、本地文件）**都不需要配置**，所以这一节
  /// 在开头就写明它只管第四路，免得用户以为「不填这个就没有字幕」。
  Widget _subtitleSection(AppSettings s) {
    return SectionCard(
      title: '在线字幕',
      description: '内嵌字幕轨、网盘同目录的字幕**不需要任何配置**，'
          '播放器的「字幕」菜单里直接就有。这里配的是第四路：'
          '去互联网上的字幕站搜一条。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'OpenSubtitles（api.opensubtitles.com）',
            style: TextStyle(fontSize: 12.5, color: AppTheme.text),
          ),
          const SizedBox(height: 4),
          const Text(
            '在 opensubtitles.com 注册后，到账号设置里生成一个 Api-Key 填在这里。'
            '**搜索不占额度**，只有「真的下载一条字幕」才消耗 —— 免费档的下载额度'
            '很小（实测个位数 / 天），用完要等第二天。',
            style: TextStyle(fontSize: 11, height: 1.7, color: AppTheme.dim),
          ),
          const SizedBox(height: 12),
          _savableField(
            controller: _opensubtitlesKey,
            label: 'Api-Key',
            hint: '留空 = 关闭在线字幕',
            saved: s.opensubtitlesApiKey,
            onSave: () => ref
                .read(settingsProvider.notifier)
                .set(opensubtitlesApiKey: _opensubtitlesKey.text),
          ),
          const SizedBox(height: 10),
          _savableField(
            controller: _opensubtitlesBase,
            label: 'API 地址',
            hint: OpenSubtitlesConfig.defaultBaseUrl,
            saved: s.opensubtitlesBase,
            onSave: () => ref
                .read(settingsProvider.notifier)
                .set(opensubtitlesBase: _opensubtitlesBase.text),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              OutlinedButton.icon(
                onPressed: _subsProbing ? null : () => unawaited(_probeSubtitles()),
                icon: _subsProbing
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering_rounded, size: 15),
                label: const Text('测试连接'),
              ),
              const SizedBox(width: 12),
              if (_subsProbeResult != null)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _subsProbeResult!,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.6,
                        color: _subsProbeOk ? AppTheme.ok : AppTheme.warn,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            s.canSearchOnlineSubtitles
                ? '已配置。播放器 →「字幕」→「搜索在线字幕…」即可。'
                : '未配置：播放器里的「搜索在线字幕」会提示先来这里填 Api-Key。',
            style: TextStyle(
              fontSize: 11,
              height: 1.7,
              color: s.canSearchOnlineSubtitles ? AppTheme.ok : AppTheme.dim,
            ),
          ),
        ],
      ),
    );
  }

  /// 探一次 OpenSubtitles。
  ///
  /// ## 为什么必须有这个按钮
  ///
  /// 这套接口的错误码**不能按常识读**（2026-10-01 实测）：
  /// 不带 `User-Agent` 是 `403`，Key 填错**也是 `403`**，
  /// 而 `/download` 对无效 Key 返回的却是 `503`。也就是说，用户从「搜不到」
  /// 这个结果上完全分不出「Key 错了」和「服务不可用」——
  /// 与 TMDB 那套熔断是同一个形状。
  ///
  /// 所以这里把两类原因分开报：地址不通 → 网络；能连上但被拒 → Key。
  Future<void> _probeSubtitles() async {
    final key = _opensubtitlesKey.text.trim();
    final base = _opensubtitlesBase.text.trim().isEmpty
        ? OpenSubtitlesConfig.defaultBaseUrl
        : _opensubtitlesBase.text.trim();

    setState(() {
      _subsProbing = true;
      _subsProbeResult = null;
    });

    String message;
    var ok = false;
    try {
      if (key.isEmpty) {
        message = '请先填入 Api-Key。';
      } else {
        await OpenSubtitlesClient(
          http: ref.read(httpClientProvider),
          config: OpenSubtitlesConfig(apiKey: key, baseUrl: base),
        ).probe();
        ok = true;
        message = '连接正常，Api-Key 可用。';
      }
    } on OpenSubtitlesException catch (e) {
      // `e.message` 已经是给用户看的中文（见 `_messageFor`），直接用。
      message = '${e.message}${e.statusCode == null ? '' : '（HTTP ${e.statusCode}）'}';
    } catch (e) {
      message = '探测失败：$e';
    }

    if (!mounted) return;
    setState(() {
      _subsProbing = false;
      _subsProbeOk = ok;
      _subsProbeResult = message;
    });
  }

  // -------------------------------------------------------------------
  // 存储
  // -------------------------------------------------------------------

  Widget _storageSection(({int items, int works})? stats) {
    if (_cacheBytes == null) {
      unawaited(_loadCacheSize());
    }

    return SectionCard(
      title: '存储',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KeyValueRow(
            label: '库内视频',
            value: stats == null ? '统计中…' : '${stats.items} 个',
          ),
          KeyValueRow(
            label: '作品数',
            value: stats == null ? '统计中…' : '${stats.works} 部',
          ),
          KeyValueRow(
            label: '海报缓存',
            value: _cacheBytes == null
                ? '统计中…'
                : formatBytes(_cacheBytes!),
          ),
          KeyValueRow(
            label: '缓存目录',
            value: ref.read(posterCacheDirProvider),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: () => unawaited(_clearPosterCache()),
                icon: const Icon(Icons.cleaning_services_rounded, size: 16),
                label: const Text('清理海报缓存'),
              ),
              OutlinedButton.icon(
                onPressed: _wiping ? null : () => unawaited(_confirmWipe()),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.danger,
                  side: const BorderSide(color: AppTheme.danger, width: 0.6),
                ),
                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                label: Text(_wiping ? '正在清空…' : '清空索引库'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            '清空索引库只删本地记录，**不会动网盘上的任何文件**。'
            '登录凭证也不受影响。清空后需要重新扫描。',
            style: TextStyle(fontSize: 11, height: 1.7, color: AppTheme.dim),
          ),
        ],
      ),
    );
  }

  Future<void> _loadCacheSize() async {
    final bytes = await ref.read(posterCacheProvider).sizeOnDisk();
    if (!mounted) return;
    setState(() => _cacheBytes = bytes);
  }

  Future<void> _clearPosterCache() async {
    final removed = await ref.read(posterCacheProvider).clear();
    if (!mounted) return;
    setState(() => _cacheBytes = 0);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已清理 $removed 张缓存图片')),
    );
  }

  Future<void> _confirmWipe() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.panel2,
        title: const Text('清空索引库？', style: TextStyle(fontSize: 15)),
        content: const Text(
          '本地的媒体索引、字幕引用与扫描进度都会被删除。\n'
          '网盘上的文件不受影响，但需要重新扫描才能看到内容。',
          style: TextStyle(fontSize: 12.5, height: 1.7, color: AppTheme.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _wiping = true);
    try {
      await ref.read(databaseProvider).wipeIndex();
      if (!mounted) return;
      ref.invalidate(workListProvider);
      ref.invalidate(libraryStatsProvider);
      // 索引库清空后「最近播放」必然是空的 —— 不重取的话角标会一直挂着
      // 一个已经不存在的数字。
      ref.invalidate(playedCountProvider);
      // 同理，筛选面板上的年代 / 类型也是从库里数出来的：清空之后
      // 它们必须变成空列表，否则用户点一个「2020 年代 · 37 部」会发现
      // 一部都没有。
      ref.invalidate(decadeCountsProvider);
      ref.invalidate(genreCountsProvider);
      ref.invalidate(categoryCountsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('索引库已清空')),
      );
    } finally {
      if (mounted) setState(() => _wiping = false);
    }
  }

  Future<void> _confirmSignOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.panel2,
        title: const Text('退出登录？', style: TextStyle(fontSize: 15)),
        content: const Text(
          '本机保存的夸克凭证会被删除，下次需要重新扫码。'
          '已经扫好的媒体库会保留。',
          style: TextStyle(fontSize: 12.5, height: 1.7, color: AppTheme.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(authControllerProvider.notifier).signOut();
  }

  // -------------------------------------------------------------------
  // 备份与同步
  // -------------------------------------------------------------------

  /// 备份同步的忙碌标记。
  bool _backingUp = false;
  bool _restoring = false;
  bool _syncing = false;
  String? _backupMessage;
  bool _backupOk = false;

  Widget _backupSection(AppSettings s) {
    return SectionCard(
      title: '备份与同步',
      description: '将媒体库索引、刮削元数据、海报缓存和设置打包备份到'
          '夸克网盘的指定目录，支持跨机同步。'
          '⚠️ 网盘凭证不会备份 —— 新机器需要重新扫码登录。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_backupMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                _backupMessage!,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.6,
                  color: _backupOk ? AppTheme.ok : AppTheme.warn,
                ),
              ),
            ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: _backingUp
                    ? null
                    : () => unawaited(_doBackup()),
                icon: _backingUp
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_upload_rounded, size: 16),
                label: Text(_backingUp ? '备份中…' : '上传备份'),
              ),
              OutlinedButton.icon(
                onPressed: _syncing
                    ? null
                    : () => unawaited(_doSync()),
                icon: _syncing
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded, size: 16),
                label: Text(_syncing ? '同步中…' : '同步'),
              ),
              OutlinedButton.icon(
                onPressed: _restoring
                    ? null
                    : () => unawaited(_doRestore()),
                icon: _restoring
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_download_rounded, size: 16),
                label: Text(_restoring ? '恢复中…' : '从网盘恢复'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            '「上传备份」会将当前媒体库完整打包上传到网盘的'
            '「云影备份」目录，覆盖同名的旧备份。\n'
            '「同步」会比对本地与远程备份的时间戳：'
            '本地新则上传，远程新则下载恢复，相同则不操作。\n'
            '「从网盘恢复」用于新机器：先在这里挑一份远程备份拉下来，'
            '再让它接管后续同步。\n'
            '两台设备在 60 秒内同时备份会触发冲突提示。',
            style: TextStyle(fontSize: 11, height: 1.7, color: AppTheme.dim),
          ),
        ],
      ),
    );
  }

  Future<void> _doBackup() async {
    setState(() {
      _backingUp = true;
      _backupMessage = null;
    });

    String message;
    var ok = false;
    try {
      final service = ref.read(libraryBackupServiceProvider);
      final bytes = await service.exportBackup(
        includePosters: true,
        includeSettings: true,
      );
      await service.uploadBackupToDrive(bytes);
      ok = true;
      message = '备份已上传到网盘「${LibraryBackupService.defaultBackupDir}」目录'
          '（${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB）';
    } catch (e) {
      message = '备份失败：$e';
    }

    if (!mounted) return;
    setState(() {
      _backingUp = false;
      _backupOk = ok;
      _backupMessage = message;
    });
  }

  Future<void> _doSync() async {
    setState(() {
      _syncing = true;
      _backupMessage = null;
    });

    String message;
    var ok = false;
    try {
      final service = ref.read(libraryBackupServiceProvider);
      final result = await service.sync();
      ok = result.action != SyncAction.conflict;
      message = result.message;

      // 如果恢复了远程备份，需要刷新列表
      if (result.action == SyncAction.restored) {
        _refreshLibraryViews();
      }
    } catch (e) {
      message = '同步失败：$e';
    }

    if (!mounted) return;
    setState(() {
      _syncing = false;
      _backupOk = ok;
      _backupMessage = message;
    });
  }

  /// 手动从网盘恢复：列出远程备份，让用户挑一份下载并覆盖本地。
  ///
  /// 这条通道是**新机器**的正路：新机器本地库是空的，`sync()` 会把刚导出
  /// 的空库当成「比远程新」而反向覆盖，所以必须先手动拉一份下来。
  Future<void> _doRestore() async {
    setState(() {
      _restoring = true;
      _backupMessage = null;
    });

    try {
      final service = ref.read(libraryBackupServiceProvider);
      final entries = await service.listRemoteBackups();
      if (!mounted) return;

      if (entries.isEmpty) {
        setState(() {
          _restoring = false;
          _backupOk = false;
          _backupMessage = '网盘「${LibraryBackupService.defaultBackupDir}」'
              '目录里还没有任何备份。';
        });
        return;
      }

      final picked = await showDialog<RemoteBackupEntry>(
        context: context,
        builder: (ctx) => _RemoteBackupPickerDialog(entries: entries),
      );
      if (picked == null) {
        if (mounted) setState(() => _restoring = false);
        return;
      }

      final bytes = await service.downloadBackup(picked);
      final manifest = await service.importBackup(bytes);
      if (!mounted) return;

      _refreshLibraryViews();
      setState(() {
        _restoring = false;
        _backupOk = true;
        _backupMessage = '已从「${manifest.deviceName}」的备份恢复'
            '（${manifest.createdAt.toLocal().toString().split('.').first}）。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _restoring = false;
        _backupOk = false;
        _backupMessage = '恢复失败：$e';
      });
    }
  }

  /// 媒体库被整体替换后，把所有读取它的视图全部作废。
  ///
  /// 四个 provider 一个都不能少：列表、统计、两个角标计数。
  /// 只作废列表的话，筛选面板上的「年代 / 类型」角标会停留在旧库的数字上。
  void _refreshLibraryViews() {
    ref.read(libraryWriteSignalProvider.notifier).bump();
    ref.invalidate(workListProvider);
    ref.invalidate(libraryStatsProvider);
    ref.invalidate(decadeCountsProvider);
    ref.invalidate(genreCountsProvider);
  }

  // -------------------------------------------------------------------
  // 关于
  // -------------------------------------------------------------------

  Widget _aboutSection() {
    return SectionCard(
      title: '关于',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const KeyValueRow(label: '应用', value: AppLogo.appName),
          const KeyValueRow(label: '版本', value: _kAppVersion),
          const KeyValueRow(label: '播放后端', value: 'mpv（media_kit）'),
          const KeyValueRow(label: '对接网盘', value: '夸克网盘（PC 自用接口）'),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => context.push('/diagnostics'),
            icon: const Icon(Icons.receipt_long_rounded, size: 16),
            label: const Text('打开诊断日志'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 小组件
// ---------------------------------------------------------------------------

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.account,
    required this.canPersist,
    required this.onSignOut,
  });

  final CloudAccount? account;
  final bool canPersist;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final acc = account;
    if (acc == null) {
      return const SectionCard(
        title: '账号',
        child: Text(
          '当前没有登录任何网盘账号。',
          style: TextStyle(fontSize: 12.5, color: AppTheme.muted),
        ),
      );
    }

    final used = acc.storageUsedBytes;
    final total = acc.storageTotalBytes;

    return SectionCard(
      title: '账号',
      trailing: TextButton.icon(
        onPressed: onSignOut,
        icon: const Icon(Icons.logout_rounded, size: 15),
        label: const Text('退出登录'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KeyValueRow(label: '账号', value: acc.label),
          KeyValueRow(label: '网盘', value: acc.provider.displayName),
          KeyValueRow(label: '登录方式', value: acc.authMode.displayName),
          if (acc.memberLabel != null)
            KeyValueRow(label: '会员', value: acc.memberLabel!),
          if (used != null && total != null && total > 0)
            KeyValueRow(
              label: '空间',
              value: '${formatBytes(used)} / ${formatBytes(total)}',
            ),
          if (!canPersist)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                '当前平台的凭证存储不是安全存储，凭证只在本次会话有效。',
                style: TextStyle(fontSize: 11, height: 1.7, color: AppTheme.warn),
              ),
            ),
        ],
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.text),
                ),
                const SizedBox(height: 3),
                Text(
                  hint,
                  style: const TextStyle(
                    fontSize: 11,
                    height: 1.6,
                    color: AppTheme.dim,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch(
            value: value,
            activeColor: AppTheme.accent,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 12.5, color: AppTheme.text),
            ),
            const Spacer(),
            Text(
              valueLabel,
              style: const TextStyle(fontSize: 11.5, color: AppTheme.muted),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// 远程备份选择对话框。
///
/// 只展示「名字 / 大小 / 时间」三件事 —— manifest 里的设备名要下载整个包
/// 才能读到，而列表可能有很多份，逐份下载代价太大。用户靠时间和体积
/// 就能认出该挑哪一份（最新最大的那份通常就是）。
class _RemoteBackupPickerDialog extends StatelessWidget {
  const _RemoteBackupPickerDialog({required this.entries});

  final List<RemoteBackupEntry> entries;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择要恢复的备份'),
      content: SizedBox(
        width: 460,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: entries.length,
          itemBuilder: (context, i) {
            final e = entries[i];
            final at = e.modifiedAt?.toLocal();
            return ListTile(
              dense: true,
              leading: const Icon(Icons.inventory_2_outlined, size: 18),
              title: Text(
                e.name,
                style: const TextStyle(fontSize: 12.5),
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${_formatSize(e.sizeBytes)}'
                '${at == null ? '' : ' · ${at.toString().split('.').first}'}',
                style: const TextStyle(fontSize: 11, color: AppTheme.muted),
              ),
              onTap: () => Navigator.of(context).pop(e),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
  }
}
