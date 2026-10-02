<div align="center">

# CloudCine · 云影

**把你散落在网盘里的影视文件，变成一个能直接播的媒体库**

不下载 · 不搬家 · 不建后端

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.29-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Android-lightgrey)](#平台支持)

</div>

---

> ⚠️ **使用前请先读 [法律声明](DISCLAIMER.md)。**
>
> 本项目是**第三方独立开源客户端**，与夸克、阿里云盘、百度网盘官方**均无关联，未获其授权或认可**。
> 仅供播放**你自己账号下、你有合法访问权**的文件。使用第三方客户端**可能违反网盘服务协议并导致账号受限**，
> 该风险由使用者自行承担。请勿用于账号共享、对外提供服务或任何商业化用途。

---

## 这是什么

你有没有过这种状态：几年攒下来的电影、剧集躺在网盘里，几百上千个文件，想看的时候得先下载、解压、拖进播放器，还得自己整理目录名。

**CloudCine 把这些活儿全省了。** 它直接连你的网盘，把影视文件扫成一个本地媒体库，点一下就在线播放 —— 文件始终留在网盘，不占本地空间。

它**没有服务端**。所有请求由客户端直接发往网盘接口与公开的元数据服务，你的文件列表、媒体库索引、播放记录、授权凭证全部只存在你自己的电脑 / 设备上。

## 核心特性

| 特性 | 说明 |
|---|---|
| **扫码 / 网页登录** | 应用内嵌浏览器打开网盘**官方登录页**，由你本人完成登录，**全程不接触账号密码** |
| **在线直连播放** | 不下载文件，边播边拉。支持拖动进度条（HTTP Range 断点请求） |
| **媒体库三轴** | 结构（`MediaKind`）、语义分类（`MediaCategory`）、「最近播放」视图，相互独立、互不推导 |
| **逐层遍历扫描** | 按目录递归识别视频文件，自动判定剧集 `SxxExx` 与电影；每页结果都会落库 |
| **断点续扫** | 中途退出、关掉应用都不丢进度，下次接着扫 |
| **海报墙与刮削** | 文件名本地解析兜底；可开启 TMDB / 豆瓣联网刮削补全海报、简介、分类（默认关闭，可审计） |
| **字幕** | 支持内嵌 / 网盘外挂 / 本地外挂字幕；可到 OpenSubtitles 搜索下载（用户主动触发） |
| **独立播放窗口（桌面端）** | 播放器跑在独立窗口，画面上方浮层显示标题、控制栏与字幕 / 音轨菜单 |
| **缓冲策略统一** | 两个播放器共用同一份缓冲配置（`core/utils/player_buffer_config.dart`） |
| **诊断日志** | 内置日志能力，出问题能看到原始异常（见[排查](#出问题了怎么办)） |
| **数据全本地** | 不上传文件、不上传播放记录、不上传授权凭证。联网刮削 / 字幕是唯一例外（只发查询词），且**默认关闭** |

## 平台支持

| 平台 | 状态 |
|---|---|
| **macOS** | ✅ 主要目标，已实测 |
| Windows | ⚠️ 代码已适配，播放后端与 macOS 同一条路（`media_kit` / mpv）；尚未在真机实测 |
| Android | ⚠️ 工程已就绪；未在真机实测 |
| iOS / Linux / Web | ❌ 暂未适配 |

网盘支持情况：

| 网盘 | 状态 |
|---|---|
| **夸克网盘** | ✅ 已接入。支持列目录遍历、关键词搜索、直链播放 |
| 阿里云盘 / 百度网盘 | 🚧 规划中 |

> 目前是**单网盘**实现。架构上已经把「网盘适配器」抽成接口（`lib/domain/adapters/`），接入新网盘不需要动上层。

## 安装

### 系统要求

| 项目 | 要求 |
|---|---|
| macOS | **10.15 (Catalina) 或更高** |
| Windows | **10 (x64) 或更高** |
| 其它 | 无。不需要装任何运行时，也不依赖服务端 |

### 方式一：下载安装包（推荐）

前往 [Releases](https://github.com/tanchang03/cloudcine/releases) 下载最新版本：

| 平台 | 文件 |
|---|---|
| macOS | `cloudcine-x.y.z-macos.dmg` |
| Windows | `cloudcine-x.y.z-windows-x64.msi` |

> 安装包**未做代码签名 / 公证**（需要付费开发者账号）。首次打开可能被系统拦截（macOS Gatekeeper、Windows SmartScreen），提示「无法验证开发者」或「Windows 已保护你的电脑」—— **这不是文件损坏，也不是中毒**，按系统提示「仍要打开」即可。

### 方式二：从源码构建

前置条件：Flutter 3.29+、对应平台的构建工具链（macOS 需 Xcode + CocoaPods；Windows 需 Visual Studio 2022「使用 C++ 的桌面开发」）。

```bash
git clone https://github.com/tanchang03/cloudcine.git
cd cloudcine
flutter pub get
```

- **macOS**：`(cd macos && pod install) && flutter build macos --release`，产物在 `build/macos/Build/Products/Release/CloudCine.app`
- **Windows**：`flutter build windows --release`，产物是 `build\windows\x64\runner\Release\`（exe + dll + data，整文件夹一起拷）
- **Android**：`flutter build apk --release`，产物在 `build/app/outputs/flutter-apk/`

> 仓库默认 **ad-hoc 签名**（不含任何真实证书名 / Team ID），任何人 clone 下来都能直接构建，不需要付费开发者账号。需要分发包时再用自己的 Developer ID / 签名证书。

## 快速上手

1. 打开应用，在登录页用网盘 App 扫码，或在应用内浏览器里完成官方登录。
2. 进入「扫描」，选一个目录开始遍历。扫描会自动识别电影 / 剧集、判定可播性。
3. 在媒体库里按「最近播放 / 分类 / 年代 / 类型」筛选；点开一部，海报墙与详情一目了然。
4. 点播放 —— 文件从网盘直连拉流，进度条可拖拽。

## 配置说明（隐私相关）

| 功能 | 默认 | 外部通信 |
|---|---|---|
| 本地文件名解析 | 开启 | 无（纯本机） |
| TMDB / 豆瓣 联网刮削 | **关闭** | 仅在设置开启后，向对应服务发送**查询词** |
| OpenSubtitles 字幕 | **关闭** | 仅在你主动搜索 / 下载时，向该服务发送**查询词** |

所有外部通信都**不发送**你的文件、文件列表、播放记录、凭证或任何账号标识。详见 [DISCLAIMER.md](DISCLAIMER.md)。

## 出问题了怎么办

先看法里的诊断日志：

- macOS：`~/Library/Application Support/com.cloudcine.cloudcine/logs/cloudcine-YYYY-MM-DD.log`
- Windows：`%APPDATA%\com.cloudcine.cloudcine\logs\`
- Android：`adb logcat` 或应用内诊断页

常见问题：

- **提示「已损坏，无法打开」**：未签名 + 文件来自网络的正常提示，按系统提示「仍要打开」即可，不要删除应用。
- **某些影片播不了 / 播到一半跳下一部**：设计行为 —— 遇不可播文件自动跳过而非卡死；详情见媒体库里的可播性徽标说明。
- **每次启动都要重新登录**：凭证存储在本机安全区（macOS 为应用支持目录下的加密文件）。如被手动清除或存储不可用，会降级为仅本次会话有效。

## 开源协议与声明

本项目以 **MIT 协议**开源，详见 [LICENSE](LICENSE)。
**使用前请务必阅读 [法律声明与免责声明](DISCLAIMER.md)** —— 它明确了项目性质、数据流向、使用限制与风险承担。

---

⭐ 如果这个项目对你有用，欢迎 Star / Fork / 提 Issue。
