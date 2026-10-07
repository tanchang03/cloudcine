/// 追更检查要扫的一个网盘目录，**以及它覆盖到哪些在追的作品**。
///
/// ## 为什么是一个独立类型，而不是 `(String, String)` 或复用 `PendingDir`
///
///   - 用裸 record 的话，「第一个是 fid、第二个是 path」这条约定只能靠
///     调用点记住，而**两个都是 `String`** —— 传反了编译器一句话都不说，
///     表现是「追更检查列了一个不存在的目录、静默失败」；
///   - `PendingDir` 是**全盘扫描游标**的一部分，它多带一个 `depth`
///     （决定要不要继续往下走），而追更检查的目录集合是**扁平**的：
///     每一个都要 `recursive = true` 地走完整棵子树。共用一个类型会让
///     「这个 depth 到底有没有用」变成一个每次都要重新想的问题。
///
/// ## `dirPath` 必须带尾斜杠
///
/// 与 `LibraryScanner.normalizeDirPath` / `drivePathWithTrailingSlash` 同口径。
/// 它是 `groupKey` 的组成部分（`MediaNameParser` 拿它算归组键），
/// 少了尾斜杠会让同一个文件在追更检查里算出**另一个** groupKey ——
/// 表现是「检查完多出一部重复的作品」，而扫描器那边一切正常。
///
/// ## [workKeys] 为什么挂在这里，而不是另开一张「作品 → 目录」表
///
/// 检查回写要回答的是「**这个目录**列成功之后，哪些作品的水位线可以推进」
/// —— 一个目录可能覆盖**多部**作品（`/电影/` 是平铺的，一个目录几十部片子）。
/// 把归属关系挂在目录上，正好是回写循环的形状：
///
/// ```
/// for (dir in dirs) if (dir 成功) for (key in dir.workKeys) 允许推进(key)
/// ```
///
/// ⛔ 反过来「一部作品 → 它的目录」也要能反推出来（判「这部作品的目录是不是
///    **全部**成功了」）—— 由 `FollowPlan` 在内存里求逆，不需要再查一次库。
class FollowDir {
  const FollowDir({
    required this.dirId,
    required this.dirPath,
    required this.workKeys,
  });

  /// 目录的网盘 fid（列目录要用的就是它）。
  final String dirId;

  /// 完整目录路径，**带尾斜杠**（`/动漫/进击的巨人/`；根是 `/`）。
  final String dirPath;

  /// 这个目录**覆盖到的在追作品 key**。
  ///
  /// ⛔ 含**被折叠进它们的源作品**：跨目录归一从不改写
  /// `media_items.group_key`，所以「这部作品的文件在哪些目录」的正确答案
  /// 是并集 —— 只算目标自己的 key，会让合并过的剧永远收不到更新提醒。
  /// 这里已经把这些源作品的文件归到**目标 key** 上（不暴露源 key），
  /// 因为水位线只写在目标行上。
  final Set<String> workKeys;

  /// ⚠️ 刻意**不实现 `==` / `hashCode`**：`workKeys` 是集合，
  /// 按值比较要引 `SetEquality`，而按 `dirId` 比较是个谎言
  /// （两个 `dirId` 相同、`workKeys` 不同的对象会被判成相等）。
  /// 需要去重的地方一律用 `Map<String, FollowDir>` 按 `dirId` 做键 ——
  /// 那也正是调用点的形状。

  @override
  String toString() => 'FollowDir($dirPath, $dirId, ${workKeys.length} 部)';
}
