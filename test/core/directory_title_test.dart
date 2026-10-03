import 'package:cloudcine/core/utils/directory_title.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「目录名什么时候才是作品名」的判据 —— 2026-10-02。
///
/// ## 为什么判定单元必须是目录，不是文件名
///
/// 事故现场：`/来自：分享/姜松《家电维修视频教程》/182.格力空调显示E6如何维修.mp4`
/// 被拆成了一个叫「182 格力空调显示」的作品，还刮成了希腊纪录片
/// 《1821: Οι Ήρωες》。而 `/我的电影/01.流浪地球2.mp4` 这种「编号片单」
/// **文件名形态与它一模一样** —— 单看文件名永远分不开这两者。
///
/// ## 为什么要有「向上回溯」
///
/// 实测用户网盘：2847 个视频里 **118 个目录（1291 个视频）** 的末级目录名是
/// 容器名，几乎全部来自 `尚硅谷嵌入式全套教程`：
///
///   `/…/01_尚硅谷嵌入式技术之C语言/4.视频/day01/`   ← 有意义的名字在**上两级**
///
/// 只取末级会得到 118 个叫「day01」「04_视频」的作品。所以规则是
/// **从末级往上找，第一个像名字的那一级**。
///
/// ## 两条必须同时成立的判据
///
///   1. 目录名本身得像「名字」（排容器名）；
///   2. 这个目录得像「一集一个文件」的容器。
///
/// 第 2 条由调用方（`MediaFilenameParser`）用「文件自身是不是独立发行物」
/// 来保证：文件名自带年份/季集结构时，说明它自己就说得清楚，轮不到目录名。
void main() {
  group('容器名：必须跳过（否则作品会叫「day01」）', () {
    test('dayNN / day_NN —— 尚硅谷那一大片', () {
      for (final s in ['day01', 'Day18', 'day_01', 'day 3', 'DAY25']) {
        expect(DirectoryTitle.isContainerSegment(s), isTrue, reason: s);
      }
    });

    test('「NN_视频」这类纯序号+介质名', () {
      for (final s in ['04_视频', '3.视频', '4.视频', '02 视频', '1_视频']) {
        expect(DirectoryTitle.isContainerSegment(s), isTrue, reason: s);
      }
    });

    test('纯编号 —— `day02/1/` 这种里层目录', () {
      expect(DirectoryTitle.isContainerSegment('1'), isTrue);
      expect(DirectoryTitle.isContainerSegment('02'), isTrue);
    });

    test('章节序号 + 篇名', () {
      for (final s in ['02 进阶篇', '01 基础篇', '3 高级篇', '第2章', '第 12 节']) {
        expect(DirectoryTitle.isContainerSegment(s), isTrue, reason: s);
      }
    });

    test('分享路径噪音 —— 用户的每一层都在 `来自：分享` 底下', () {
      for (final s in ['来自：分享', '来自分享', '我的分享', '分享', '转存', '新建文件夹', '新建文件夹 (2)']) {
        expect(DirectoryTitle.isContainerSegment(s), isTrue, reason: s);
      }
    });

    test('栏目名 / 整理态', () {
      for (final s in ['电影', '电视剧', '动漫', '综艺', '纪录片', '未分类', '待整理', '我的资源', '合集', '4K', '1080p']) {
        expect(DirectoryTitle.isContainerSegment(s), isTrue, reason: s);
      }
    });

    test('日期 / 分辨率这种「不是名字」的串', () {
      for (final s in ['2026-10-02', '2026.10.2', '1080p', '2160P', '4k']) {
        expect(DirectoryTitle.isContainerSegment(s), isTrue, reason: s);
      }
    });

    test('⚠️ 含「合集」二字但不是容器的长名字要放行 —— 不能按子串判', () {
      expect(DirectoryTitle.isContainerSegment('姜松家电维修合集'), isFalse);
      expect(DirectoryTitle.isContainerSegment('电影天堂经典合集'), isFalse);
    });
  });

  group('像名字：要放行', () {
    test('真实作品名（2 个汉字起）', () {
      for (final s in ['沧元图', '牧神记', '仙逆', '凡人', 'Z 遮.天', '斩神2', '吞噬星空.']) {
        expect(DirectoryTitle.isContainerSegment(s), isFalse, reason: s);
      }
    });

    test('课程 / 剧集目录名', () {
      for (final s in [
        '姜松《家电维修视频教程》',
        '彭老师英语外刊精读课',
        '01_尚硅谷嵌入式技术之C语言',
        '10_尚硅谷嵌入式项目之畜牧牛羊定位器',
        '新能源汽车BMS开发工程师',
        '天龙八部 (1997) 4K 60帧 国语',
        '【极客时间-100026801】Web 协议详解与抓包实战',
      ]) {
        expect(DirectoryTitle.isContainerSegment(s), isFalse, reason: s);
      }
    });
  });

  group('seriesTitleOf：向上回溯到最近的非容器祖先', () {
    test('末级就是名字 → 用它', () {
      expect(
        DirectoryTitle.seriesTitleOf('/来自：分享/姜松《家电维修视频教程》/'),
        '姜松 家电维修视频教程',
      );
    });

    test('末级是容器 → 回溯两级（day01 → 4.视频 → 章节名）', () {
      expect(
        DirectoryTitle.seriesTitleOf(
          '/来自：分享/尚硅谷嵌入式全套教程/01_尚硅谷嵌入式技术之C语言/4.视频/day01/',
        ),
        '01 尚硅谷嵌入式技术之C语言',
      );
    });

    test('末级是容器 → 回溯一级（04_视频 → 章节名）', () {
      expect(
        DirectoryTitle.seriesTitleOf(
          '/来自：分享/尚硅谷嵌入式全套教程/10_尚硅谷嵌入式项目之畜牧牛羊定位器/04_视频/',
        ),
        '10 尚硅谷嵌入式项目之畜牧牛羊定位器',
      );
    });

    test('一路都是容器 → null（退回逐文件解析，不许硬凑一个名字）', () {
      expect(DirectoryTitle.seriesTitleOf('/来自：分享/'), isNull);
      expect(DirectoryTitle.seriesTitleOf('/电影/'), isNull);
      expect(DirectoryTitle.seriesTitleOf('/'), isNull);
      expect(DirectoryTitle.seriesTitleOf(''), isNull);
    });

    test('`day02/1/` 这种里层目录也回溯得出来', () {
      expect(
        DirectoryTitle.seriesTitleOf(
          '/来自：分享/尚硅谷嵌入式全套教程/12_尚硅谷嵌入式项目之平衡车/04_视频/day02/1/',
        ),
        '12 尚硅谷嵌入式项目之平衡车',
      );
    });

    test('去掉书名号与括号噪音 —— 它同时是 TMDB 的查询词', () {
      expect(
        DirectoryTitle.seriesTitleOf('/x/姜松《家电维修视频教程》/'),
        '姜松 家电维修视频教程',
      );
      expect(DirectoryTitle.seriesTitleOf('/x/【极客时间】Web 协议详解/'), '极客时间 Web 协议详解');
    });

    test('尾斜杠可有可无（归一化只在 drive_paths，这里自己容错）', () {
      expect(
        DirectoryTitle.seriesTitleOf('/来自：分享/沧元图'),
        DirectoryTitle.seriesTitleOf('/来自：分享/沧元图/'),
      );
    });
  });

  group('ancestorNames：全部候选目录名（2026-10-03）', () {
    // 在线刮削的兜底词来源。与 `seriesTitleOf` 是**同一套判据的两个出口**：
    // 那个只要第一级（归组用），这个要全部（刮削还有哪些词可以试）。
    // 两处各写一遍循环的话，「什么算容器」迟早会漂移，而漂移的表现是
    // 「目录名明明是对的，为什么不用它搜」—— 只在刮不到时才暴露。

    test('第一级必须与 seriesTitleOf 一致', () {
      const paths = [
        '/来自：分享/仙逆/',
        '/来自：分享/尚硅谷嵌入式全套教程/01_尚硅谷嵌入式技术之C语言/4.视频/day01/',
        '/x/姜松《家电维修视频教程》/',
        '/来自：分享/',
        '/电影/',
      ];
      for (final p in paths) {
        final names = DirectoryTitle.ancestorNames(p);
        expect(
          names.isEmpty ? null : names.first,
          DirectoryTitle.seriesTitleOf(p),
          reason: '$p —— 两个出口一旦不一致，归组用的是 A、刮削去搜的是 B',
        );
      }
    });

    test('从末级往上，跳过容器名', () {
      expect(
        DirectoryTitle.ancestorNames('/来自：分享/仙逆/'),
        ['仙逆'],
        reason: '`来自：分享` 是分享路径噪音，拿它去搜只会搜到一堆无关条目',
      );
      expect(
        DirectoryTitle.ancestorNames(
          '/来自：分享/尚硅谷嵌入式全套教程/01_尚硅谷嵌入式技术之C语言/4.视频/day01/',
        ),
        ['01 尚硅谷嵌入式技术之C语言', '尚硅谷嵌入式全套教程'],
        reason: '`4.视频`、`day01` 都是容器，要跳过；再往上的两级都是真名字',
      );
    });

    test('季目录也是容器 —— 否则会冒出一部叫「第三季」的作品', () {
      expect(DirectoryTitle.isContainerSegment('第三季'), isTrue);
      expect(DirectoryTitle.isContainerSegment('第2季'), isTrue);
      expect(DirectoryTitle.isContainerSegment('Season 1'), isTrue);
      expect(DirectoryTitle.isContainerSegment('S02'), isTrue);

      expect(
        DirectoryTitle.ancestorNames('/来自：分享/日漫精选/进击的巨人/第三季/'),
        ['进击的巨人', '日漫精选'],
        reason: '拿「第三季」去搜 TMDB 是白花一个搜索词，'
            '而且前缀档必然把它配到某个同名条目上',
      );
    });

    test('一路都是容器 → 空列表（调用方据此不发兜底请求）', () {
      expect(DirectoryTitle.ancestorNames('/来自：分享/'), isEmpty);
      expect(DirectoryTitle.ancestorNames('/电影/'), isEmpty);
      expect(DirectoryTitle.ancestorNames(''), isEmpty);
    });

    test('顺序是「从近到远」—— 越近的目录越可能是这一集所属的作品', () {
      expect(
        DirectoryTitle.ancestorNames('/来自：分享/日漫精选/进击的巨人/'),
        ['进击的巨人', '日漫精选'],
      );
    });
  });
}
