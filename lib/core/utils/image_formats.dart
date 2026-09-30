/// 图片识别，以及「目录里哪张图是专辑封面」的判据。
///
/// 单独一个文件而不是塞进 `audio_formats.dart`：那个文件的主题是**音频**的
/// 格式分档与命名推断，图片跟它没有一条共同规则。唯一共用的是 [extensionOf]，
/// 直接 import 过来即可。
///
/// 这里只回答两个问题，都是纯函数、都可单测：
///   1. 这个文件是不是图片（[isImageFile]）；
///   2. 这张图**有多像**专辑封面（[coverNameRank]）—— 返回一个档位而不是
///      布尔值，因为真实音乐包里同目录常有 `cover.jpg` / `back.jpg` /
///      `disc1.jpg` 好几张，必须能排序而不是「是/不是」。
library;

import 'file_names.dart';

/// 常见图片扩展名。
///
/// 刻意不含 `svg` / `ico` / `psd`：前两个不是专辑封面会用到的格式，
/// `psd` 是设计源文件（几十 MB 且解不出来），混进来只会让扫描多认几个
/// 永远显示不了的「封面」。
const Set<String> kImageExtensions = {
  'jpg', 'jpeg', 'jpe', 'jfif',
  'png', 'webp', 'bmp', 'gif',
  'tif', 'tiff', 'avif', 'heic', 'heif',
};

/// 是否为图片文件。
///
/// 扩展名认不出时看 MIME —— 网盘对少数文件会给出正确的 `image/*`
/// 而没有扩展名（或扩展名被改坏）。
bool isImageFile(String fileName, {String? mimeType}) {
  if (kImageExtensions.contains(extensionOf(fileName))) return true;
  return (mimeType ?? '').toLowerCase().startsWith('image/');
}

// ---------------------------------------------------------------------------
// 文件名分档
// ---------------------------------------------------------------------------

/// 明确写着「这就是封面」：`cover.jpg`、`folder.jpg`、`front.jpg`、`封面.jpg`
const int kCoverRankNamed = 0;

/// 名字里带封面词但还夹着别的：`album_cover_hires.jpg`、`专辑封面1.png`
const int kCoverRankHinted = 1;

/// 认不出来的图片：`01.jpg`、`cdimage.png`
const int kCoverRankOther = 2;

/// 明确**不是**正面封面：封底 / 碟面 / 内页 / 歌词页
const int kCoverRankBackside = 3;

/// 归一化：小写、去掉所有非字母数字与汉字。
///
/// `Album_Cover (Hires).jpg` → `albumcoverhires`。
/// 保留下划线/空格会让「`cover.jpg` 与 `cover_1.jpg` 是不是同一档」
/// 变成两个分支，去掉之后一条正则就够。
final RegExp _coverNoise = RegExp(r'[^a-z0-9\u4e00-\u9fff]');

String normalizeCoverStem(String fileName) {
  var stem = fileName;
  final dot = stem.lastIndexOf('.');
  if (dot > 0) stem = stem.substring(0, dot);
  return stem.toLowerCase().replaceAll(_coverNoise, '');
}

/// 一眼就是封面的名字（归一化后完全匹配）。
final RegExp _coverNamed = RegExp(
  r'^(cover|coverart|coverfront|folder|front|frontcover|albumart|albumarts|'
  r'album|artwork|artworks|封面|专辑封面|封面图|正面)(\d*)$',
);

/// 名字里带封面词。
final List<String> _coverHints = [
  'cover', 'folder', 'front', 'album', 'artwork', '封面', '专辑', '正面',
];

/// 明确不是正面封面的词。
///
/// 这里只放**没有歧义**的词。刻意不含 `scan` / `扫描` / `side`：
///   - `scan` 在真实音乐包里两边都出现 —— `Scans/scan001.jpg` 是内页扫描，
///     而 `front-cover-scan.jpg` 恰恰**就是**正面封面的扫描件。
///     把它当反证据会白白丢掉第二种情况；不认它则退到「普通图片」档，
///     仍然能被选中，只是不再额外加分。
///   - `side` 同理（`front-side.jpg` 是封面），真正要拦的是 `inside`。
///
/// `back` 必须排在 `cover` 前面判断 —— `backcover.jpg` 同时命中两边，
/// 而它显然是封底（见 [coverNameRank] 的判定顺序）。
final List<String> _backsideHints = [
  'back', 'inlay', 'matrix', 'booklet', 'lyric', 'tray', 'obi', 'spine',
  'inside',
  '封底', '背面', '碟面', '内页', '歌词', '曲目',
];

/// `cd1.jpg` / `disc2.png` / `dvd.jpg` 这类「第几张碟」的图。
///
/// 用锚定匹配而不是子串：`disc` 出现在 `discovery.jpg` 里纯属巧合。
final RegExp _discLike = RegExp(r'^(cd|disc|dvd|vinyl)(\d*)$');

/// 这张图有多像专辑封面。**数字越小越像**。
///
/// 判定顺序是有意的，不是随意排列：
///   1. 先认「明确就是封面」的名字 —— 这一类没有歧义；
///   2. **再排掉封底/碟面/内页** —— 必须在「带封面词」之前判，
///      否则 `backcover.jpg` 会因为含 `cover` 被当成正面封面，
///      用户看到的封面就是反的；
///   3. 然后才是「带封面词但夹了别的」；
///   4. 剩下的一律当普通图片，交由体积与目录位置去分胜负。
int coverNameRank(String fileName) {
  final n = normalizeCoverStem(fileName);
  if (n.isEmpty) return kCoverRankOther;
  if (_coverNamed.hasMatch(n)) return kCoverRankNamed;
  if (_discLike.hasMatch(n)) return kCoverRankBackside;
  for (final word in _backsideHints) {
    if (n.contains(word)) return kCoverRankBackside;
  }
  for (final word in _coverHints) {
    if (n.contains(word)) return kCoverRankHinted;
  }
  return kCoverRankOther;
}

// ---------------------------------------------------------------------------
// 目录名分档（「同目录 + 一层子目录」找图时的判据）
// ---------------------------------------------------------------------------

/// 目录名本身就在说「这里放的是封面」。
const Set<String> _coverDirExact = {
  'cover', 'covers', 'artwork', 'artworks', 'albumart', 'albumarts',
  'front', 'frontcover', 'folder', 'cdcover',
  '封面', '专辑封面', '封面图', '专辑图片',
};

/// 目录名只说「这里放的是图片」，可能是封面也可能是扫描内页。
const Set<String> _imageDirExact = {
  'art', 'image', 'images', 'img', 'imgs', 'pic', 'pics', 'picture',
  'pictures', 'photo', 'photos', 'scan', 'scans', 'jpg', 'jpeg', 'png',
  '图片', '照片', '图', '插图', '扫描', '内页',
};

/// 目录名是不是在说「这里是封面」。
bool isCoverDirName(String dirName) {
  final n = normalizeCoverStem(dirName);
  if (n.isEmpty) return false;
  return _coverDirExact.contains(n) ||
      n.contains('cover') ||
      n.contains('artwork') ||
      n.contains('封面');
}

/// 目录名是不是在说「这里是图片」。
///
/// 刻意用**精确匹配 + 少数几个安全的子串**，不做通用子串匹配：
/// `contains('art')` 会连 `cartoon`、`party` 一起命中。
bool isImageDirName(String dirName) {
  if (isCoverDirName(dirName)) return true;
  final n = normalizeCoverStem(dirName);
  if (n.isEmpty) return false;
  return _imageDirExact.contains(n) ||
      n.contains('image') ||
      n.contains('图片') ||
      n.contains('照片') ||
      n.contains('scan');
}

/// 值不值得为了找封面去列这个子目录。
bool isArtworkDirName(String dirName) =>
    isCoverDirName(dirName) || isImageDirName(dirName);
