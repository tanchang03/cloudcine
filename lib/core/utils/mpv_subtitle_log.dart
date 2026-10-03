/// 判定一条 mpv 日志是不是「字幕解码」相关。
///
/// ## 为什么必须单独开一条路（实测踩过）
///
/// 2026-10-03，`The Glory S01E01`（内封 PGS 图形字幕）：菜单里轨道**列得出来、
/// 也打得勾**，画面上却一个字都没有；而诊断日志里**一条线索都没有**。
///
/// 原因不是 mpv 没说，是**我们把它丢了**。mpv 的原话是：
///
/// ```
/// Could not find subtitle decoder for format 'hdmv_pgs_subtitle'.
/// ```
///
/// 这句话被**两条过滤同时挡掉**：
///
///   1. `_onPlayerError` 只收含 `failed` / `error` 的消息 —— 这句两个词都没有；
///   2. `stream.error` 根本收不到它。media_kit 只把**特定 prefix** 的 error
///      转发到 `stream.error`（`media_kit-1.2.6` 的 `real.dart`：`file`、
///      `ffmpeg`（且 text 必须以 `tcp:` 开头）、`vd`、`ad`、`cplayer`、`stream`），
///      而报这句话的是字幕解码器封装 `sd_lavc` —— **不在白名单里**。
///
/// 所以唯一通路是 `stream.log`，而它此前只放行 HTTP 4xx（见 `isHttp4xxLog`）。
/// 不在这里放行，唯一的直接证据就永远看不到。
///
/// ## 这句话意味着什么
///
/// 它是「**本机 libmpv 里没有 `pgssub` 解码器**」的症状描述：
/// macOS 的预编译包（`media_kit_libs_macos_video`）给 FFmpeg 用的是
/// `--disable-all` + 显式白名单，白名单里有 `srt`/`ass`/`ssa`/`webvtt`/
/// `dvdsub`/`dvbsub`，**唯独漏了 `pgssub`**。解复用器知道这个 codec
/// （所以轨道能列出来、能选中），但没有解码器 —— 于是「能选中、不显示」。
///
/// ## 为什么按正文而不是按 prefix
///
/// 报这句话的模块是 `sd_lavc`，而 mpv 给它的 prefix 会随 av_log 的 context 名
/// 变。`subtitle` 这个词一定在正文里，按正文判两种布局都命中 ——
/// 与 `isHttp4xxLog` 同一个理由。
///
/// 同时放行 VobSub / DVB：它们是同一类位图字幕，真出问题时报的话一模一样。
///
/// 放在 `core/` 而不是 `ui/windows/` 的原因：内置播放页走
/// `PlaybackController`（`domain/` 层），那一层不能 import Flutter。
library;

bool isSubtitleDiagnosticLog(String text) {
  final t = text.toLowerCase();
  return t.contains('subtitle') ||
      t.contains('hdmv_pgs') ||
      t.contains('dvd_subtitle') ||
      t.contains('dvb_subtitle');
}
