import '../entities/media_item.dart';
import '../entities/media_work.dart';

/// 「已入库文件」→「它在媒体库里属于哪部作品」的映射（纯函数）。
///
/// ## 它回答的是「已在库」后面那句
///
/// 目录视图的行上原先只有一个「已在库」标签 —— 那回答的是**在不在**
/// （`media_items` 里有没有这一行）。用户看到它之后的下一句话是
/// *「那我上哪儿找它？」*，而答案只有本地索引知道：这条文件的
/// `group_key` 指向哪一部作品。
///
/// 2026-10-17 现场（《仙逆剧场版：弑仙之战》）：两个电影文件被
/// `DirectoryAnchorIndex` 归到了上一层目录的剧集《仙逆》名下，行上写着
/// 「已在库」，而海报墙上既没有《弑仙之战》这部作品、搜「弑仙之战」也
/// 搜不到（搜索只匹配作品标题与文件名，不匹配目录路径）—— 用户于是
/// 认为「库里没有这个文件」。把「属于《仙逆》」直接写在行上，
/// 那趟白找就省掉了。
///
/// ## 为什么是「标题」而不是 `group_key`
///
/// `group_key` 是归一化后的内部键（`仙逆renegadeimmortal`、
/// `z遮天`），拿给用户看等于什么都没说。海报墙上认的是作品标题。
///
/// ## 别名行要走到归一目标
///
/// `group_key` 可能是一个**已被折叠走**的源作品（`mergedInto != null`）。
/// 海报墙显示的是目标那一部（列表过滤掉别名行、文件按并集并进目标），
/// 所以这里也必须报目标标题 —— 否则用户照着「已在库 · 遮天(别名)」去墙上
/// 找，那部根本不存在。归一**不允许成链**（见 `MediaWork.mergedInto` 的
/// 文档），所以一跳就够，不做循环跟随。
///
/// ## 查不到作品行时**照样返回这个 id**
///
/// 值是空串（而不是丢掉这个键）。两件事必须分开：
///
///   - **在不在库** —— 判据是「这条文件在索引里」，键在就是**在**；
///   - **在哪部作品下** —— 值是空串表示「查不到作品行」。
///
/// 丢掉这个键会把「在库但作品行缺失」（续扫中间态、旧备份恢复）的文件
/// 显示成「未入库」，用户会去点「加入媒体库」，而那条记录本来就在库里。
Map<String, String> indexedWorkTitles({
  required Iterable<MediaItem> items,
  required Iterable<MediaWork> works,
}) {
  final byKey = <String, MediaWork>{};
  for (final w in works) {
    byKey[w.key] = w;
  }

  String titleOf(String groupKey) {
    final own = byKey[groupKey];
    if (own == null) return '';
    final target = own.mergedInto;
    if (target != null && target.isNotEmpty) {
      final t = byKey[target];
      if (t != null) return t.title.trim();
    }
    return own.title.trim();
  }

  final out = <String, String>{};
  for (final item in items) {
    out[item.id] = titleOf(item.groupKey);
  }
  return out;
}
