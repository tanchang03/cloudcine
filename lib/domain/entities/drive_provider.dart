/// 网盘服务商标识。
///
/// 新增一家网盘只需两步：
///   1. 在这里追加一个枚举值；
///   2. 在 data 层实现一个 `CloudDriveAdapter`。
/// UI、播放引擎、索引库、扫描调度器均不需要改动。
enum DriveProvider {
  quark(
    id: 'quark',
    displayName: '夸克网盘',
    shortName: '夸克',
    hasOfficialOpenPlatform: false,
    notes: '当前走 PC 端自用接口（drive-pc.quark.cn），官方开放平台未对接',
  ),
  aliyun(
    id: 'aliyun',
    displayName: '阿里云盘',
    shortName: '阿里',
    hasOfficialOpenPlatform: true,
    notes: '官方开放平台 openapi.alipan.com，OAuth + 直链',
  ),
  baidu(
    id: 'baidu',
    displayName: '百度网盘',
    shortName: '百度',
    hasOfficialOpenPlatform: true,
    notes: '官方开放平台 pan.baidu.com/union，OAuth + 直链',
  );

  const DriveProvider({
    required this.id,
    required this.displayName,
    required this.shortName,
    required this.hasOfficialOpenPlatform,
    required this.notes,
  });

  /// 稳定标识，用于持久化与日志，**不要随意改动**
  final String id;

  final String displayName;
  final String shortName;

  /// 是否有可用的官方开放平台。没有则只能走自用/逆向接口。
  final bool hasOfficialOpenPlatform;

  final String notes;

  static DriveProvider? fromId(String id) {
    for (final p in values) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 用 [name] **或** [id] 解析。
  ///
  /// ## 为什么需要它（而不是统一用 `fromId`）
  ///
  /// 落库时用的不一定是同一个字面量：`DownloadTask.provider` 存的是
  /// **枚举名**（`DownloadTask.idFor` 拿的是 `provider.name`），
  /// 而 `media_items.id` 的前缀用的是 **`id`**。两者目前逐字相同
  /// （`quark` / `baidu`），但那是**巧合**，不是契约 ——
  /// 哪天有人给某个枚举值写成 `id: 'aliyun-drive'`，`fromId` 就解不出
  /// 那些下载任务，表现是「任务卡在排队、永远不开始」而**不报错**。
  ///
  /// 先按 `id` 再按 `name`，两条都试，所以两种来源都能读。
  static DriveProvider? fromNameOrId(String value) {
    final byId = fromId(value);
    if (byId != null) return byId;
    for (final p in values) {
      if (p.name == value) return p;
    }
    return null;
  }

  /// 严格解析，解析失败抛 [ArgumentError]，用于读取本地库时快速暴露脏数据。
  static DriveProvider parse(String id) {
    final p = fromId(id);
    if (p == null) {
      throw ArgumentError.value(id, 'id', '未知的网盘标识');
    }
    return p;
  }
}
