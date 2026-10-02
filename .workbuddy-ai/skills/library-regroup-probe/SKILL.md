---
name: library-regroup-probe
description: 在本项目（cloudcine / 网盘媒体库播放器）里改动「文件名解析 / 目录名归组 / 作品归组 / 刮削闸门」之后，用一次性探针在**真实媒体库**（2800+ 条）上量化改动效果时使用。单测用的是合成文件名，真实库里的形态千奇百怪 —— 单测全绿也可能把 2259 个作品并成 40 个、或产出叫「day01」的作品。触发词：回归、真实库、探针、probe、groupKey、归组、作品数、重扫、目录名、filename_parser、directory_title、work_builder、scrape_match、会不会刮错。
agent_created: true
---

# 在真实媒体库上做只读回归探针

## 何时用

动了下面任何一处，**在告诉用户「改完了」之前**都要跑一次：

| 文件 | 影响 |
| --- | --- |
| `lib/core/utils/filename_parser.dart` | 片名 / 季集 / `groupKey` |
| `lib/core/utils/directory_title.dart` | 目录名当不当系列名 |
| `lib/domain/services/work_builder.dart`（`WorkSeedBook`） | 作品归组 |
| `lib/domain/services/media_entry_classifier.dart` | 哪些条目算视频 |
| `lib/domain/services/scrape_match.dart` | 刮削闸门 |

**为什么单测不够**：单测里写的是 `Some.Show.S01E01.1080p.mkv` 这种规整名字；
真实库里有 `182.格力空调显示E6如何维修.mp4`、`day01`、`04_视频`、`来自：分享`、`[LoliHouse] xxx [1001]`。
一个改动可以让 1208 个单测全绿，同时把整库并成 40 个作品。**两个数字必须都看：作品数 + 垃圾标题。**

## 铁律

1. **绝不写用户的库。** 只用 `sqlite3 "file:${DB}?mode=ro"`（`mode=ro` 是必须的，漏了会写 WAL）。
2. **探针是一次性的。** 放 `tool/probe_*.dart`，跑完 `rm`。`tool/` 里只留长期有用的脚本
   （现在是 `build_android.sh`、`gen_tv_banner.py`）。
3. **探针必须 import 真实类**（`package:cloudcine/...`），不能抄一份解析逻辑 —— 抄的那份永远不会和产品代码一起漂移。
4. **断言的是「垃圾标题」，不是「作品数」。** 作品数变少可能是对的（合并教程合集），也可能是错的（把不同片子并了）。
   垃圾标题（`day01` / `电影` / `来自：分享` / 纯数字）出现就是**一定**错。

## 步骤

### 1. 定位库文件

```
~/Library/Application Support/com.cloudcine.cloudcine/cloudcine.sqlite
```

（同目录还有 `credentials.enc`、`posters/`、`logs/` —— **日志在 `logs/cloudcine-YYYY-MM-DD.log`**，
查刮削现场先看它。`logs/` 是应用写的，只读看即可。）

### 2. 只读导出条目

```bash
DB="$HOME/Library/Application Support/com.cloudcine.cloudcine/cloudcine.sqlite"
sqlite3 "file:${DB}?mode=ro" -header -noquote \
  "select id, name, dir_path, group_key, kind, title, year, season, episode, container
   from media_items;" > /tmp/cloudcine_items.tsv
```

⚠️ `sqlite3` 的 `glob '*/[0-9]*/'` 这类带斜杠的模式在 shell 里会被吃掉，**别用 glob 判目录形态**，
改用 `substr` / `like`，或者在 Dart 里判。

表结构（`media_items` 关键列）：`name` `dir_path` `group_key` `kind` `title` `year` `season` `episode`
`episode_end` `container` `is_sample_or_extra`。
`media_works` 关键列：`key` `title` `category` `item_count` `source` `category_manual` `genres_manual`。

### 3. 写探针

```dart
// tool/probe_regroup.dart —— 用完即删
import 'dart:io';
import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/media_work.dart';   // ScrapeQuery 在这里

void main() {
  final parser = MediaFilenameParser();
  final lines = File('/tmp/cloudcine_items.tsv').readAsLinesSync();
  final groups = <String, List<String>>{};
  var ungrouped = 0;

  for (final line in lines.skip(1)) {
    final f = line.split('\t');
    if (f.length < 3) continue;
    final name = f[1], dirPath = f[2];
    final p = parser.parse(name, dirPath: dirPath);   // ← 参数要和产品代码逐字一致
    // 「不归组」的判据必须照抄 WorkSeedBook.add：ScrapeQuery 为空即不归组，
    // 而不是 title 为空 —— 两者的差别正是「目录名兜底」这类改动的着力点。
    if (ScrapeQuery.fromParsed(p) == null) { ungrouped++; continue; }
    groups.putIfAbsent(p.groupKey, () => []).add(name);   // groupKey 是 getter，非空
  }

  print('总条目 ${lines.length - 1}');
  print('新作品数 ${groups.length} / 不归组 $ungrouped');

  // 关键检查：垃圾标题
  final junk = groups.keys.where((k) =>
      RegExp(r'^(day\s*\d+|\d+_?视频|第\d+[章节讲]|电影|电视剧|动漫|来自：分享|\d+)$')
          .hasMatch(k.trim()));
  print('=== 疑似垃圾标题 === ${junk.isEmpty ? '（无）' : junk.join(' | ')}');

  // 抽查：挑几个已知的大合集看有没有被并成一个
  // ⚠️ 必须拿**作品键**匹配，不能只拿文件名 —— 姜松那 222 个文件叫
  // 「182.格力空调显示E6如何维修.mp4」，文件名里根本没有「姜松」，
  // 只匹配文件名会得到「姜松 → 0」，看起来像规则没生效。
  for (final probe in ['姜松', '尚硅谷', '沧元图', '天龙八部']) {
    final hit = groups.entries
        .where((e) =>
            e.key.contains(probe) || e.value.any((n) => n.contains(probe)))
        .toList();
    print('$probe → ${hit.length} 个作品  ${hit.map((e) => e.key).take(3).join(' | ')}');
  }
}
```

跑：

```bash
cd /Users/tandy/workbuddy-ai/网盘媒体库播放器 && dart run tool/probe_regroup.dart
```

### 4. 判读

| 现象 | 结论 |
| --- | --- |
| 垃圾标题非空 | **一定错**，回去改 |
| 作品数暴跌（比如 2259 → 40） | 多半是过度合并，抽查几个不同片子是不是被并了 |
| 作品数暴涨（比如 2259 → 3000） | 归组键变碎了，多半是 `groupKey` 里混进了易变字段 |
| 已知大合集（姜松 / 尚硅谷）→ 1 个作品 | 对 |
| 带显式 `S01E` 的剧（仙逆 / 牧神记）→ 多个作品 | **对**，这是「独立发行物」豁免，不是 bug |

### 5. 清理

```bash
rm -f tool/probe_regroup.dart /tmp/cloudcine_items.tsv
```

## 基线数字（2026-10-02，改完「目录名作为系列名」之后，已实测复现）

```
总条目 2847 / 新作品数 180 / 不归组（ScrapeQuery 为空） 16
疑似垃圾标题：（无）
姜松 → 1 个作品（姜松家电维修视频教程）      222 个文件
尚硅谷 → 23 个作品（各章节）                合并前是一堆 day01
沧元图 → 1 个作品
天龙八部 → 1 个作品
```

下次改完解析/归组，拿这几个数字比 —— 大幅偏离就要解释清楚为什么。
（库内 `media_works` 表仍是旧的 2259 行，那是**未重扫**的正常状态，不是 bug。）

## ⚠️ 三个最容易忘的点

1. **探针里的 `parse(...)` 参数必须和产品代码逐字一致。** 产品代码是 `dirPath:`，
   探针写成 `dirName:` 就会得出一份**看起来合理但完全不同**的数字。
2. **别用 `$HOME` 拼库路径。** 本机沙箱里 `$HOME` 指向
   `/Users/tandy/.workbuddy-ai-5-home`，拼出来的路径打不开库文件
   （报 `unable to open database file`）。**写绝对路径** `/Users/tandy/Library/...`。
3. **规则改了不会自动重排已有分组。** 库里的 `media_works` 还是旧的，
   **必须让用户跑一次全盘重扫**才生效 —— 这一步要明确告诉用户，否则他会以为「改了没用」。

## 命令行小抄（踩过的坑）

```bash
# ✅ 对
sqlite3 -header -separator $'\t' "file:${DB}?mode=ro" "select ... from media_items;"

# ❌ -noquote 不是 sqlite3 CLI 的选项（它是 dot-command 的参数）→ unknown option
# ❌ .mode tabs 里的 glob '*/[0-9]*/' 这种带斜杠的模式会被 shell 吃掉
```
