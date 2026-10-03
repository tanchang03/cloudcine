import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/adapters/cloud_drive_adapter.dart';
import '../../domain/entities/drive_entry.dart';
import '../../domain/services/request_throttle.dart';
import '../../domain/services/scan_service.dart';
import '../providers/app_providers.dart';
import '../providers/download_providers.dart';
import '../providers/drive_browse_providers.dart';
import '../providers/settings_providers.dart';
import '../theme/app_theme.dart';

/// 「把网盘上的东西存到本地」—— 目录视图里那个下载动作。
///
/// ## 它只负责**决定存哪儿**，然后入队
///
/// 真正下载的是 `DownloadQueue`（并发调度、暂停 / 继续、断点续传、持久化）。
/// 这里做的是下载之前那一步：问用户存到哪、把路径算出来、把任务丢进队列。
///
/// 分成两件事的好处是**所有下载都出现在同一个地方**（侧栏「下载」那一页），
/// 不管它是从目录视图点的、还是整目录批量下的。以前这里自己起一个模态框
/// 把它下完，那个模态框一旦被关掉（按 Esc、切页），这次下载就再也没有
/// 任何界面能暂停或取消它了。
///
/// ## 保存位置：桌面弹系统对话框，其余平台落到下载目录
///
///   - **桌面**（macOS / Windows / Linux）：单个文件弹 `getSaveLocation`
///     （可改名换目录），整个目录弹 `getDirectoryPath`（选一个目标文件夹）。
///     这是「下载」这件事在桌面上的默认预期，替他决定反而要多一步
///     「去 Finder 里找」。
///   - **其余平台**（Android / TV）：没有系统面板这回事，落到应用自己的
///     外部存储目录，并在提示条里给出**完整路径**。
///
/// 判据用 [defaultTargetPlatform] 而不是 `dart:io` 的 `Platform`：
/// 项目里所有「按平台分叉」都走前者（`flutter test` 下默认是 `android`，
/// 可以用 `debugDefaultTargetPlatformOverride` 精确控制）。
Future<void> downloadDriveEntry(
  BuildContext context,
  WidgetRef ref, {
  required DriveEntry entry,
  required String dirPath,
}) async {
  final String? savePath;
  try {
    savePath = await resolveSavePath(ref, entry.name);
  } catch (e) {
    if (context.mounted) _snack(context, '打不开保存位置：$e');
    return;
  }
  // `null` = 用户在系统面板里点了取消。**静默返回**：这不是失败，
  // 弹一句「已取消」只会打断他。
  if (savePath == null) return;
  if (!context.mounted) return;

  await ref.read(downloadQueueProvider.notifier).enqueue(
        provider: browseProvider.name,
        fileId: entry.id,
        name: entry.name,
        savePath: savePath,
        dirPath: dirPath,
        sizeBytes: entry.sizeBytes,
      );
  if (!context.mounted) return;
  _queuedSnack(context, '「${entry.name}」已加入下载队列');
}

/// 整个目录（含子目录）批量下载。
///
/// ## 为什么要先「统计」再入队
///
/// 列目录是有网络代价的（一个几百项的目录要好几秒，夸克还有 QPS 限制），
/// 而用户点下按钮之后如果什么都不发生，他会以为功能坏了、再点一次 ——
/// 于是两遍遍历同时打过去。所以先弹一个**有进度、可取消**的统计框。
///
/// ## 目标路径保留网盘上的目录结构
///
/// `电影/2024/a.mkv` 会落到 `<目标根>/2024/a.mkv`。拍平的话，不同子目录里
/// 同名的 `cover.jpg` / `CD1.mkv` 会互相覆盖 —— 而那种覆盖**不报错**，
/// 用户只会发现「少下了几个文件」。
///
/// ## 重复下载会覆盖
///
/// 不像单个文件那条路会 `dedupePath` 加 `(1)` 后缀：批量下载几十个文件时
/// 每个都加后缀会得到一整个 `xxx (1)` 的目录，而那显然不是用户要的。
/// 所以这里**直接覆盖**（下载服务本来就写 `.part` 再 rename，覆盖是原子的）。
Future<void> downloadDriveFolder(
  BuildContext context,
  WidgetRef ref, {
  required DriveCrumb crumb,
  required DriveEntry dir,
}) async {
  final String? root;
  try {
    root = await resolveFolderSaveRoot(ref, dir.name);
  } catch (e) {
    if (context.mounted) _snack(context, '打不开保存位置：$e');
    return;
  }
  if (root == null) return;
  // ⚠️ 别在下面的闭包里直接用 `root`。它是在 `try` 里赋值的，而类型提升
  // **不会传进闭包**（分析器在闭包体里只认声明类型 `String?`），直接传会报
  // 「String? 不能赋给 String」。先抄一份非空的出来给闭包用。
  final saveRoot = root;
  if (!context.mounted) return;

  final adapter =
      ref.read(adapterRegistryProvider).requireAdapter(browseProvider);
  final settings = ref.read(settingsProvider).valueOrNull;

  // 与扫描共用同一个节流间隔：批量下载的遍历同样是「每个目录一次请求」，
  // 用更激进的间隔只是把自己送进夸克的风控。
  final throttle = RequestThrottle(
    minInterval: Duration(milliseconds: settings?.scanIntervalMs ?? 350),
    clock: DateTime.now,
  );

  final found = ValueNotifier<int>(0);
  final cancel = ScanCancellation();
  final navigator = Navigator.of(context, rootNavigator: true);

  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _FolderScanDialog(
      folderName: dir.name,
      root: saveRoot,
      found: found,
      onCancel: cancel.cancel,
    ),
  ));

  List<_PlannedFile> plan;
  try {
    plan = await _planFiles(
      adapter,
      crumb.child(dir),
      throttle: throttle,
      cancel: cancel,
      onFound: (n) => found.value = n,
    );
  } catch (e) {
    found.dispose();
    if (navigator.mounted) navigator.pop();
    if (context.mounted) _snack(context, '读取目录失败：$e');
    return;
  }
  found.dispose();
  if (navigator.mounted) navigator.pop();
  if (!context.mounted) return;

  if (plan.isEmpty) {
    _snack(context, '「${dir.name}」里没有可下载的文件');
    return;
  }

  final queue = ref.read(downloadQueueProvider.notifier);
  for (final item in plan) {
    await queue.enqueue(
      provider: browseProvider.name,
      fileId: item.entry.id,
      name: item.name,
      // ⚠️ 只拼**子目录相对路径**，不再拼一遍目录名：桌面那条路上
      // 用户选的就是「下到哪个文件夹」，再套一层 `电影/` 会变成
      // `.../电影/电影/...` —— 而如果他自己新建了一个同名文件夹，
      // 那个重复会显得像是 bug。
      savePath: p.join(root, item.relativeDir, item.name),
      dirPath: item.driveDirPath,
      sizeBytes: item.entry.sizeBytes,
    );
  }
  if (!context.mounted) return;
  _queuedSnack(context, '「${dir.name}」的 ${plan.length} 个文件已加入下载队列');
}

/// 递归列出 [start] 下面所有**文件**，算出它们的本地相对路径。
///
/// 只返回文件：目录本身不下载（空目录也不需要在本地下出来）。
///
/// [maxFiles] 是防御性上限 —— 用户对着一整个网盘根目录点「下载全部」时，
/// 没有上限的话会把几万个文件一次性塞进队列，而队列会把它全部写进
/// SQLite（几万行）并开始几十 GB 的下载。上限到了就停，界面会如实说出
/// 「只统计到 N 个」。
Future<List<_PlannedFile>> _planFiles(
  CloudDriveAdapter adapter,
  DriveCrumb start, {
  required RequestThrottle throttle,
  required ScanCancellation cancel,
  required void Function(int found) onFound,
  int maxFiles = 3000,
}) async {
  final out = <_PlannedFile>[];
  final pending = <({String id, String path})>[(id: start.id, path: '')];

  while (pending.isNotEmpty && !cancel.isCancelled) {
    final current = pending.removeAt(0);
    String? pageToken;
    do {
      if (cancel.isCancelled) break;
      await throttle.wait();
      final page = await adapter.listDirectory(
        dirId: current.id,
        pageToken: pageToken,
        pageSize: 100,
      );
      for (final entry in page.entries) {
        if (cancel.isCancelled) break;
        if (entry.isDirectory) {
          pending.add((
            id: entry.id,
            path: current.path.isEmpty
                ? entry.name
                : p.join(current.path, entry.name),
          ));
          continue;
        }
        out.add(_PlannedFile(
          entry: entry,
          relativeDir: current.path,
          driveDirPath: current.path.isEmpty ? '/' : '/${current.path}',
        ));
        if (out.length >= maxFiles) break;
      }
      onFound(out.length);
      pageToken = page.nextPageToken;
    } while (pageToken != null && out.length < maxFiles);
    if (out.length >= maxFiles) break;
  }

  return _dedupeNames(out);
}

/// 同一个相对路径撞名时给后面的加 `(1)` 后缀。
///
/// 网盘允许同目录下同名文件（不同时间上传的两次 `cover.jpg`）。不去重的话
/// 两个任务会往**同一个本地文件**里写 —— 表现是下完之后文件内容随机是其中
/// 一个，而体积校验对两边都「通过」。这类损坏最难查。
List<_PlannedFile> _dedupeNames(List<_PlannedFile> files) {
  final seen = <String>{};
  final out = <_PlannedFile>[];
  for (final item in files) {
    var name = item.name;
    var key = p.join(item.relativeDir, name);
    if (!seen.add(key)) {
      final base = p.basenameWithoutExtension(name);
      final ext = p.extension(name);
      for (var i = 1; i < 1000; i++) {
        name = '$base ($i)$ext';
        key = p.join(item.relativeDir, name);
        if (seen.add(key)) break;
      }
    }
    out.add(_PlannedFile(
      entry: item.entry,
      relativeDir: item.relativeDir,
      driveDirPath: item.driveDirPath,
      overrideName: name == item.entry.name ? null : name,
    ));
  }
  return out;
}

/// 计划下载的一个文件。
class _PlannedFile {
  const _PlannedFile({
    required this.entry,
    required this.relativeDir,
    required this.driveDirPath,
    this.overrideName,
  });

  final DriveEntry entry;

  /// 相对目标根的子目录（可能是空串 = 直接放在根下）。
  final String relativeDir;

  /// 网盘上的目录路径（展示用）。
  final String driveDirPath;

  /// 撞名时改过的文件名。`null` = 用原来的。
  final String? overrideName;

  String get name => overrideName ?? entry.name;
}

/// 决定单个文件存到哪。返回 `null` 表示**用户在系统面板里取消了**。
///
/// 公开是为了让「桌面弹面板 / 其余平台落目录」这条分叉能被单测直接钉住 ——
/// 它是这个功能里唯一一处平台相关、且做错了不报错的地方（默默存到别处）。
Future<String?> resolveSavePath(WidgetRef ref, String fileName) async {
  if (_usesSavePanel) {
    final location = await getSaveLocation(
      suggestedName: fileName,
      confirmButtonText: '下载',
    );
    return location?.path;
  }

  final dir = await defaultDownloadDir(ref);
  return dedupePath(p.join(dir, fileName));
}

/// 决定批量下载存到哪个根目录。返回 `null` = 用户取消了。
///
/// 与 [resolveSavePath] 的差别是这里选的是**目录**而不是文件名：
/// 批量下载时用户心里想的是「下到哪个文件夹」，而让他为几十个文件
/// 各改一次名字是不可能的。
Future<String?> resolveFolderSaveRoot(WidgetRef ref, String folderName) async {
  if (_usesSavePanel) {
    return getDirectoryPath(confirmButtonText: '下载到此处');
  }
  final dir = await defaultDownloadDir(ref);
  // 没有目录选择面板时按**目录名**建一个子目录：全丢进同一个下载夹的话，
  // 两次批量下载的内容会混在一起，而用户没有任何办法分开它们。
  return dedupeDirPath(p.join(dir, folderName));
}

/// 本平台有没有系统保存面板。
bool get _usesSavePanel => switch (defaultTargetPlatform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux =>
        true,
      _ => false,
    };

/// 没有保存面板时文件落到哪个目录。
///
/// 三条候选按「用户找得到」排序：
///   1. 系统下载目录（桌面端的 `~/Downloads`）—— 用户的第一直觉就在这；
///   2. Android 的**应用私有**外部目录 —— 不需要任何存储权限，
///      卸载时随应用一起清掉，也不会污染用户的公共下载夹；
///   3. 应用支持目录兜底 —— 保证这条链**永远有结果**。
///
/// 每个候选都要 try：`getDownloadsDirectory` 在 Android 上直接抛
/// `UnsupportedError`，`getExternalStorageDirectory` 在桌面上同理。
Future<String> defaultDownloadDir(WidgetRef ref) async {
  try {
    final dir = await getDownloadsDirectory();
    if (dir != null) return dir.path;
  } catch (_) {
    // 该平台没有「系统下载目录」这个概念。
  }
  try {
    final dir = await getExternalStorageDirectory();
    if (dir != null) return dir.path;
  } catch (_) {
    // 非 Android。
  }
  return p.join(ref.read(appSupportDirProvider), 'downloads');
}

/// 目标路径已存在时换一个不撞的名字（`片子 (1).zip`）。
///
/// 只在**没有保存面板**的那条路上用：有面板时覆盖与否由系统面板自己问过了，
/// 我们再改一次名字反而违背用户的选择。
String dedupePath(String path) {
  if (!File(path).existsSync()) return path;

  final dir = p.dirname(path);
  final base = p.basenameWithoutExtension(path);
  final ext = p.extension(path);
  for (var i = 1; i < 1000; i++) {
    final candidate = p.join(dir, '$base ($i)$ext');
    if (!File(candidate).existsSync()) return candidate;
  }
  // 一千个同名文件…… 与其死循环，不如加时间戳让它一定不撞。
  return p.join(dir, '$base (${DateTime.now().millisecondsSinceEpoch})$ext');
}

/// 目录版本的 [dedupePath]（批量下载的目标根用）。
String dedupeDirPath(String path) {
  if (!Directory(path).existsSync()) return path;
  for (var i = 1; i < 1000; i++) {
    final candidate = '$path ($i)';
    if (!Directory(candidate).existsSync()) return candidate;
  }
  return '$path (${DateTime.now().millisecondsSinceEpoch})';
}

/// 「已加入下载队列」提示 + 一个「去下载页」。
///
/// 只提示不跳转是刻意的：用户点下载时多半还在挑别的文件，把他弹到下载页
/// 等于打断他。但**必须给出入口** —— 否则「东西去哪了」这个问题没有答案
/// （以前那个模态框至少还看得见）。
void _queuedSnack(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 5),
      content: Text(text),
      action: SnackBarAction(
        label: '去下载页',
        onPressed: () => context.go('/downloads'),
      ),
    ),
  );
}

void _snack(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(behavior: SnackBarBehavior.floating, content: Text(text)),
  );
}

/// 批量下载前的「正在统计」框。
///
/// 它**不是**进度条 —— 统计阶段只知道找到了几个文件，不知道总量
/// （总量要等遍历完才知道）。所以这里显示的是「已找到 N 个」，
/// 而不是一个假的百分比。
class _FolderScanDialog extends StatelessWidget {
  const _FolderScanDialog({
    required this.folderName,
    required this.root,
    required this.found,
    required this.onCancel,
  });

  final String folderName;
  final String root;
  final ValueNotifier<int> found;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.panel,
      title: const Text('正在统计要下载的文件', style: TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '目录：$folderName',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, color: AppTheme.text),
            ),
            const SizedBox(height: 4),
            Text(
              '保存到：$root',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: AppTheme.dim),
            ),
            const SizedBox(height: 14),
            ValueListenableBuilder<int>(
              valueListenable: found,
              builder: (_, value, __) => Row(
                children: [
                  const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '已找到 $value 个文件…',
                    style: const TextStyle(fontSize: 12, color: AppTheme.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: onCancel,
          child: const Text('取消', style: TextStyle(fontSize: 12.5)),
        ),
      ],
    );
  }
}

/// 把一段路径复制到剪贴板。
Future<void> copyPathToClipboard(BuildContext context, String path) async {
  await Clipboard.setData(ClipboardData(text: path));
  if (!context.mounted) return;
  _snack(context, '已复制路径');
}
