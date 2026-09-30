# 云影（cloudcine）项目长期约定

Flutter 3.29.0 / Dart 3.7.0 的 macOS 网盘媒体库播放器，对接夸克网盘。
参考项目：`/Users/tandy/workbuddy-ai/夸克音乐播放器`（授权与取流方案复刻自它）。

## 目录职责

| 目录 | 职责 |
|---|---|
| `lib/core/` | 无依赖的纯工具：诊断日志、脱敏、文件名/格式识别、文件名解析 |
| `lib/domain/` | 实体 + 服务 + 适配器抽象。**不 import Flutter、不 import drift** |
| `lib/data/` | 夸克适配器、HTTP、drift 索引库、刮削器、凭证存储 |
| `lib/ui/` | Riverpod 组合根（`providers/`）、go_router、页面与组件 |

## 不可动摇的设计约束

1. **本地解析永远可用，在线刮削是增强**。`LocalFilenameScraper` 必须排在
   `ScraperPipeline` 最后，保证没有 TMDB Key / 断网时媒体库不为空。
2. **取流走四路由降级链**：`play/info` → `v2/play` → `audioplay` → `download`。
   任何一条成功即停。这样「未验证路由不通」只损失清晰度切换，不损失播放能力。
3. **`Capabilities.maxSingleFileBytes` 刻意不声明**。50 MiB 只是 `download`
   路由的限制，写进能力会让能播的文件被误判（参考项目踩过：43.9% 曲目被误判）。
4. **`ScanPolicy.audioOnly` 默认 `true`**（继承自音频项目）。视频库必须在
   `buildScanService` 里显式 `audioOnly: false`，否则**扫完一条不剩且不报错**。
5. **直链必须带 Cookie**（缺则 `412`）；`__puus` 每个响应轮换，要回填内存凭证。
6. **字幕必须自取字节**：`media_kit` 的 `SubtitleTrack.uri/.data` **都没有请求头参数**，
   而夸克直链缺 Cookie 一律 412。取回后用 `decodeTextBytes`（先严格 UTF-8 后 GBK）
   解码再交给播放器 —— 这是「中文不乱码」的根治手段。
7. **扫描期不下载字幕正文**，只写引用（夸克有 QPS 限制，几千部片子会多出几千次请求）。
8. **落库通过 `PlaybackController.onPositionTick` 回调在组合根接**，
   `PlaybackController` 不暴露 `Player`。
9. **`ScanPhase` 只有 `walking/scraping/finishing`，没有 `idle`** ——
   「没在扫描」用 `ScanPhase?` 表达。

## 本机构建环境（踩过的坑）

- flutter 命令必须：`dangerouslyDisableSandbox: true` + 先 source gvm +
  `unset http_proxy https_proxy all_proxy` + `export no_proxy=127.0.0.1,localhost`。
  沙箱会拒绝 `~/.pub-cache/_temp/` 写入，`flutter pub get` 会 `Operation not permitted`。
- `flutter test` 输出用 `sed -e 's/\r/\n/g'` 展开回车，否则失败详情被进度行挤掉。
- **同一个文件不能在同一条消息里发两个 `Edit`**：后写的会静默覆盖先写的，两次都报 success。
- `rm -rf` 一次删超过 50 个文件会被 safe-delete 拦下（`SAFE_DELETE_BULK_CONFIRM_REQUIRED`）。
  删 `macos/Pods` 这类生成目录不必手动删 —— 改过 Podfile 就会触发 `pod install` 重建。

### macOS 三条必踩的坑（都已在 Podfile / entitlements 里修好，别回退）

1. **entitlements 必须含 `com.apple.security.network.client`**。Flutter 模板默认只给
   `app-sandbox` + `network.server`，缺了它应用**发不出任何网络请求** ——
   扫码、列目录、取流、海报、TMDB 全废，而且报错不会指向权限。
   Debug 与 Release 两个文件都要加。
2. **部署目标必须 10.15**（`macos/Podfile` 的 `platform` + pbxproj 的
   `MACOSX_DEPLOYMENT_TARGET`）。硬下限来自 `media_kit_video` → `wakelock_plus`
   的 podspec；设 10.14 时 `pod install` 直接失败，报错不提 media_kit。
   而且 `platform :osx, '10.15'` **只作用于 Runner 目标**，每个 pod 仍按自己
   podspec 里写的版本编译（media_kit 写 10.9、flutter_inappwebview 写 10.14），
   所以 Podfile 的 `post_install` 里必须**逐个 target 覆盖** `MACOSX_DEPLOYMENT_TARGET`。
   不覆盖的后果：`flutter_inappwebview_macos` 以 10.14 编译时报
   `protocol 'ASWebAuthenticationPresentationContextProviding' requires
   'presentationAnchor(for:)' to be available in macOS 10.14 and newer` ——
   报错指向 inappwebview，很容易误判成那个插件坏了。
3. **media_kit 的 mpv 框架符号链接要自己补**（Podfile 里的
   `cloudcine_fix_media_kit_symlinks`）。`media_kit_video` 用
   `-framework Mpv` + 手写的 `FRAMEWORK_SEARCH_PATHS`，指向
   `media_kit_libs_macos_video/macos/Frameworks/.symlinks/mpv/macos`；
   那条链接由 upstream 的 `create_framework_symlinks.sh` 生成，而该脚本在 pub 包里
   **带 CRLF 行尾**，`sh` 一跑就 `set: -: invalid option` 退出 → 目录为空 →
   `ld: framework 'Mpv' not found`。Makefile 里本来有 `sed 's/\r$//'` 去 CR，
   但构建期 PATH 上的 `sed` 被工具链 brokered shim 顶掉，静默失效。
   **别用 sed/make 修，用纯 Ruby。**

首次 macOS 构建耗时约 5~20 分钟（要下 libmpv xcframework + 编译十几个 pod）。

## 测试取向

纯函数优先（格式识别、文件名解析、质量档位排序、播放信息解析、作品合并、字幕配对），
因为它们不需要网络也不需要数据库，却能钉住最容易在重构中悄悄退化的规则。
断言要写「为什么这条规则重要」，而不只是「结果等于什么」。
