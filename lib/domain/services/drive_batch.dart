/// 一次网盘**批量写**请求最多带多少个 fid。
///
/// ## 为什么是这个数
///
/// 夸克没有公开删除 / 移动接口的规模上限。100 来自官方 `file/move` 文档里
/// `fid_list` 的上限；而本网关（PC 自用）的删除与移动是**同族接口**
/// （同一个 `action_type` + `filelist` 组合，见 `QuarkEndpoints.fileMove`），
/// 所以两者按同一个数走。
///
/// 定成 100 而不是「一次全带上」的理由是**失败时的爆炸半径**：一次带 3000 个
/// fid 的请求超时或被限流，用户得不到任何信息，只能全部重来；分成 30 个请求
/// 则能如实告诉他「动了 2900 个，100 个失败」。
///
/// ## 为什么单独一个文件
///
/// 删除（`DriveDeletePlan`）与移动（`DriveMovePlan`）各要切一次批次。这个数
/// 一旦两处各写一份，就会出现「删得动、移不动」这类查起来毫无头绪的差异 ——
/// 而两处都**不会报错**，只会让某一批静默失败。
const int driveMaxFidsPerRequest = 100;

/// 把 fid 列表按 [driveMaxFidsPerRequest] 切成批次。
///
/// 空列表返回空批次表（调用方据此走「什么都没做」的分支，而不是发一个
/// 带空 `filelist` 的请求 —— 那种请求网盘多半直接报错）。
List<List<String>> chunkFids(List<String> fids) {
  final out = <List<String>>[];
  for (var i = 0; i < fids.length; i += driveMaxFidsPerRequest) {
    final end = i + driveMaxFidsPerRequest;
    out.add(fids.sublist(i, end > fids.length ? fids.length : end));
  }
  return out;
}
