# 法律声明与免责声明

> 最后更新：2026-10-02
> 适用于 CloudCine（云影）项目及其全部源码、构建产物与文档。

**请在使用、复制、修改或分发本项目之前，完整阅读本声明。** 使用本项目即表示你已理解并接受以下全部内容。

---

## 0. 一句话概括

CloudCine（云影）是一个**第三方独立开源客户端**，与任何网盘服务商**均无关联、未获授权、未获认可**。它只做一件事：用你自己的账号，播放并管理你自己网盘里的影视文件。

---

## 1. 项目性质

- 本项目是**第三方独立客户端**，**不是**任何网盘服务商（包括但不限于夸克网盘、阿里云盘、百度网盘）的官方产品、关联产品、合作产品或经其授权的产品。
- 本项目与上述服务商之间**不存在**任何隶属、投资、合作、赞助、认证或背书关系。
- 本项目是**开源、非商业**项目，不提供任何形式的商业服务。
- 本项目**不是网盘服务**，不提供存储、不提供内容、不提供下载服务、不提供对外分享能力。它只是把你**自己的**网盘文件，组织成一个可播放的本地媒体库。

---

## 2. 授权方式与数据流向（技术事实，可审计）

本节所述均为可由源码验证的事实。任何使用者都可以自行审计 `lib/data/remote/quark/`、`lib/data/scrape/`、`lib/data/auth/`、`lib/domain/adapters/credential_store.dart` 等文件。

| 环节 | 实际做法 |
|---|---|
| **登录** | 应用内嵌浏览器打开网盘**官方登录页**（`pan.quark.cn`），由用户本人完成登录。项目不代替、不代理、不伪造登录过程。 |
| **凭证来源** | 仅从**本应用自身**的 WebView Cookie 存储读取登录态。 |
| **不读取什么** | **不**读取本机其它应用的私有凭据；**不**读取任何浏览器的 Cookie 数据库；**不**读取系统钥匙串中其它应用的条目；**不**尝试解密任何加密存储。 |
| **凭证存储** | 按平台写入各自的安全存储：iOS/Android 用 Keychain / Keystore；Windows 用 DPAPI；Linux 用 libsecret；**macOS 因仓库使用 ad-hoc 签名、钥匙串 ACL 永远对不上，改用应用支持目录下的加密文件**（`credentials.enc`，由 `lib/data/auth/secret_cipher.dart` 派生密钥）。不写入日志、不写入数据库、不上传。 |
| **数据传输** | 客户端**直连**网盘官方接口与公开的元数据服务。**本项目没有自建服务器**，不存在任何第三方中转、代理或镜像。 |
| **用户数据** | 文件列表、媒体库索引、播放记录、收藏**全部只存本机**，不上报、不外发。 |
| **日志** | 诊断日志中的签名直链只保留 `scheme + host + path`，请求头只记录键名，Cookie 值全部打码。 |

### 2.1 联网刮削与字幕：本应用会向网盘之外的第三方发送数据的功能

除直接播放你在网盘里的文件外，以下两类功能会向外部服务发送**查询词**（通常是从文件名推断出的片名/季集信息），用于匹配元数据或字幕：

| 功能 | 默认 | 实际做法 |
|---|---|---|
| **本地文件名解析**（兜底） | 开启 | 仅在本机解析文件名，**不向任何外部服务发送数据**。 |
| **TMDB / 豆瓣 联网刮削** | **关闭** | 仅在用户于「设置」中明确配置并开启后生效。向 [TMDB](https://api.themoviedb.org/3)（`api.themoviedb.org`，可选自备反代）或 [豆瓣](https://m.douban.com/rexxar/api/v2) 发送片名/季集等查询词，用于补全海报、简介、分类等元信息。 |
| **OpenSubtitles 字幕** | **关闭** | 仅在用户于播放页明确搜索/下载字幕时生效。向 [OpenSubtitles](https://api.opensubtitles.com/api/v1)（`api.opensubtitles.com`）发送片名/季集等查询词以匹配字幕。 |

- **不发送**：视频文件本身、网盘文件列表、播放记录、收藏、授权凭证，以及任何可用于定位你网盘账号的标识。
- **不经过本项目作者控制的任何服务器** —— 上述请求均由客户端直接发往对应服务商。
- 上述服务的可用性、内容正确性、以及其各自的服务条款，由对应服务商负责，本项目不提供担保。
- **不开启相应开关，本应用不会与 TMDB、豆瓣或 OpenSubtitles 发生任何通信。** 相关设置均可在 `lib/data/db/settings_store.dart` 中审计。

> 元数据与字幕文本的著作权归其权利人所有。本项目不提供、不缓存分发、不转码任何受版权保护的内容；仅在用户自己的设备上展示其自己选择获取的文本，用户应自行确保其使用符合适用法律。

---

## 3. 技术中立与不规避声明

- 本项目**不破解、不绕过**任何技术保护措施：未破解任何加密的 Cookie 存储，未规避任何付费、会员或权限控制，未篡改任何客户端完整性校验。
- 本项目**不提供、不缓存、不转码、不分发**任何影视内容。所有媒体数据始终存放在用户自己的网盘中，由网盘服务器直接向用户的播放器传输。
- 播放功能使用的服务端端点与官方客户端相同，属于**使用同一服务提供的不同端点**，而非破解或伪造身份。但这并不意味着获得了服务商的授权 —— 见 §6 风险提示。
- 部分网盘接口对单文件大小、并发、频度存在限制，本项目**如实呈现**给用户，不作为规避对象。

---

## 4. 使用限制（禁止用途）

本项目**仅允许**用于播放**你自己账号下、你拥有合法访问权**的文件。以下行为被明确禁止：

- ❌ 使用**他人**的账号凭证，或搭建、参与任何形式的账号共享、账号池、代登录服务
- ❌ 将本项目（或其修改版）作为**服务对外提供**，或用于任何商业化运营
- ❌ 用于**分发、传播**任何未经授权的内容，或规避任何内容的版权保护
- ❌ 对网盘服务进行**批量抓取、高频轮询**或其他影响其正常运行的行为
- ❌ 移除、隐藏或篡改本项目中的版权声明、来源信息与本法律声明后再分发
- ❌ 将本项目用于任何违反所在国家或地区法律法规的目的

---

## 5. 商标与标识

- 「夸克」「夸克网盘」「阿里云盘」「百度网盘」「TMDB」「豆瓣」「OpenSubtitles」等名称、商标与标识，归各自权利人所有。
- 本项目仅在**描述兼容性的必要范围内**提及这些名称，属于指示性合理使用。
- 本项目**不使用、不模仿**任何网盘官方的图标、商标或视觉识别系统。项目拥有独立的品牌名称（CloudCine / 云影）与独立的视觉设计（圆角渐变方块 + 云朵播放标）。
- 本项目**不暗示**任何形式的官方授权、合作、认证或背书。在提及上述名称时，均不意味着与权利人存在任何关系。

---

## 6. 风险提示与责任限制

**请在使用前充分理解以下风险：**

1. **账号风险（最现实的风险）** —— 使用第三方客户端可能违反你所使用网盘的服务协议。可能的后果包括但不限于：账号被限流、部分功能受限、账号被临时或永久封禁。**该风险由使用者自行承担。**
2. **接口失效风险** —— 项目使用的部分服务端端点属于未公开接口，可能随服务商调整而随时变更、限流或关闭，导致功能不可用。本项目不承诺任何可用性。
3. **第三方服务风险** —— TMDB、豆瓣、OpenSubtitles 等元数据的可用性、准确性与各自的服务条款由对应服务商负责；本项目不对因依赖外部服务导致的结果负责。
4. **内容合法性风险** —— 你所播放内容的合法性由你本人负责。本项目只是技术工具，不审查、不判断、不干预你播放的内容。
5. **无担保** —— 本项目按 **MIT 协议**「按原样（AS IS）」提供，不附带任何明示或默示的担保，包括但不限于对适销性、特定用途适用性及不侵权的担保。
6. **责任限制** —— 在适用法律允许的最大范围内，项目作者与贡献者不对因使用或无法使用本项目而产生的任何直接、间接、附带、特殊、惩罚性或后果性损失承担责任（包括但不限于数据丢失、账号损失、利润损失、业务中断）。
7. **免责条款的边界** —— 上述免责与责任限制不适用于法律强制规定不得免除或限制的责任。

---

## 7. 权利人的通知与处理

本项目作者**无意侵犯**任何主体的合法权益。

如权利人认为本项目的内容、代码或文档侵犯了其合法权益，请通过 **tanchang03@163.com** 联系，并说明：

- 具体涉及的内容（文件、代码位置或功能）
- 你所主张的权利及依据
- 期望的处理方式

作者承诺在合理期限内核实，并采取必要且适当的措施，**包括但不限于修改、移除相关代码或功能、或停止项目分发**。

---

## 8. 合规提示

使用者应**自行确认**其使用行为符合所在国家或地区的法律法规，以及所使用网盘的服务条款与用户协议。本项目不构成、也不替代任何法律意见。

使用联网刮削 / 字幕功能时，你还应遵守对应第三方服务（TMDB、豆瓣、OpenSubtitles）的服务条款。

---

## 9. 本声明的性质

本声明是项目作者为**明确使用边界、表达善意、降低误用风险**而作出的说明，**不构成法律意见**，也不构成对任何法律责任的承认。

如你计划将本项目或其修改版用于**商业用途**，请务必在实施前咨询专业律师。

---

## English Version

**CloudCine (Yunying) is a third-party, independent, non-commercial open-source client. It is NOT affiliated with, authorized by, endorsed by, or sponsored by any cloud drive provider (including Quark, Aliyun Drive, or Baidu Netdisk).**

- **Login:** you sign in to the provider's **official login page** inside the app. Your credentials are read only from **this app's own WebView cookie store** — never from other applications, browser databases, or system keychain entries.
- **Storage:** credentials are kept in each platform's secure store only (Keychain/Keystore on mobile, DPAPI on Windows, libsecret on Linux; on macOS, an encrypted file in the app-support directory — by design, to avoid the keychain prompt under ad-hoc signing). Nothing is written to logs, databases, or any server.
- **No backend:** this project has **no server of its own**. The client connects directly to the provider's endpoints and to public metadata services. No third-party relay, proxy, or mirror exists.
- **External data (only when enabled):** metadata scraping (TMDB / Douban) and subtitle lookup (OpenSubtitles) send only **search terms derived from filenames** to the respective services. Local filename parsing sends nothing. All such features are **off by default**. The client never sends your files, file list, play history, credentials, or any account-identifying data.
- **No circumvention:** the project does **not** crack, decrypt, or bypass any technical protection measure, paywall, or permission control.
- **Permitted use:** playing files **you own and have lawful access to**, in **your own** account, only.
- **Prohibited use:** using anyone else's credentials, account sharing/pooling, offering this as a service, commercial operation, distributing unauthorized content, scraping, or removing this notice.
- **Risk:** using a third-party client may violate the provider's Terms of Service and may result in rate limiting, feature restrictions, or account suspension. **You bear this risk.** Endpoints used may change or stop working at any time.
- **Trademarks:** "Quark", "TMDB", "Douban", "OpenSubtitles", and other names are trademarks of their respective owners. They are referenced only as necessary to describe compatibility. This project uses its own independent branding (CloudCine / 云影) and **does not** imitate any official icon or visual identity.
- **License:** MIT, provided **"AS IS"**, without warranty of any kind. To the maximum extent permitted by law, the authors are not liable for any damages arising from its use.
- **Rights holders:** if you believe this project infringes your rights, please contact **tanchang03@163.com** with details. The author will verify and take appropriate action, including modification, removal, or discontinuation.

**This document is a good-faith statement of usage boundaries, not legal advice.**
