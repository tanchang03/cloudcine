import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/cloud_account.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/entities/quality_option.dart';
import '../providers/app_providers.dart';
import '../providers/auth_providers.dart';
import '../providers/library_providers.dart';
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
  bool _keyLoaded = false;
  bool _keyDirty = false;

  /// 海报缓存占用的字节数。`null` 表示还在算。
  int? _cacheBytes;

  /// 清空索引库的忙碌标记（清库是异步的，期间要禁用按钮）。
  bool _wiping = false;

  @override
  void dispose() {
    _tmdbKey.dispose();
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
    if (s != null && !_keyLoaded) {
      _keyLoaded = true;
      _tmdbKey.text = s.tmdbApiKey;
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
                _storageSection(stats),
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
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '联网刮削（TMDB）',
                      style: TextStyle(fontSize: 12.5, color: AppTheme.text),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      s.canScrapeOnline
                          ? '已启用。扫描结束后会为还没刮过的作品查询 TMDB。'
                          : '未启用。开启后还需要填入 API Key。',
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.6,
                        color: AppTheme.dim,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: s.onlineScrape,
                activeColor: AppTheme.accent,
                onChanged: (v) => unawaited(
                  ref.read(settingsProvider.notifier).set(onlineScrape: v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _tmdbKey,
            onChanged: (_) => setState(() => _keyDirty = true),
            style: AppTheme.mono.copyWith(color: AppTheme.text),
            decoration: InputDecoration(
              isDense: true,
              labelText: 'TMDB API Key',
              labelStyle: const TextStyle(fontSize: 12, color: AppTheme.muted),
              hintText: 'v3 的 API Key，或 v4 的 Read Access Token',
              hintStyle: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
              suffixIcon: _keyDirty
                  ? TextButton(
                      onPressed: () {
                        unawaited(
                          ref
                              .read(settingsProvider.notifier)
                              .set(tmdbApiKey: _tmdbKey.text),
                        );
                        setState(() => _keyDirty = false);
                      },
                      child: const Text('保存'),
                    )
                  : null,
              filled: true,
              fillColor: AppTheme.panel2,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.line, width: 0.5),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.line, width: 0.5),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.accent, width: 0.8),
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Key 存在本地数据库里（与索引库同一份数据），不会外传。'
            '没有 Key 也能正常使用，只是没有海报。',
            style: TextStyle(fontSize: 11, height: 1.7, color: AppTheme.dim),
          ),
        ],
      ),
    );
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
