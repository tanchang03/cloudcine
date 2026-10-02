## 下载

本版本同时提供 macOS、Windows 与 Android 交付物，按你的系统选一个：

| 平台 | 文件 | 系统要求 |
|---|---|---|
| macOS | `cloudcine-x.y.z-macos.dmg`（或 `.zip`） | macOS 10.15 (Catalina) 或更高，Apple Silicon / Intel 均可 |
| Windows | `cloudcine-x.y.z-windows-x64.msi`（或 `.zip`） | Windows 10 (x64) 或更高 |
| Android | `cloudcine-x.y.z-android.apk` | Android 5.0 (API 21) 或更高；手机 / 平板 |

---

## macOS 安装

1. 下载 `cloudcine-x.y.z-macos.dmg`，双击打开，把 **云影 CloudCine** 拖进「应用程序」窗口。
   （也有 `.zip` 版本，解压后同样拖进「应用程序」。）

2. **首次打开一定会被系统拦住** —— 安装包是 ad-hoc 签名、**未做 Apple 公证**
   （公证需要每年 99 美元的付费开发者账号）。提示「无法验证开发者」或
   「Apple 无法验证…是否包含可能危害 Mac 安全或泄漏隐私的恶意软件」都是这个原因，
   **不是中毒，也不是安装包损坏，请不要删除应用。**

3. 按你的 macOS 版本放行一次：

   **macOS 26 (Tahoe) 及以上** —— 系统已移除「右键 → 打开」旁路，隐私与安全性里也可能
   不出现「仍要打开」按钮。打开「终端」执行：

   ```bash
   xattr -rd com.apple.quarantine /Applications/CloudCine.app
   ```

   **macOS 15 (Sequoia)** —— 在「应用程序」里右键点 云影 CloudCine → 打开 → 弹窗里再点一次「打开」。

   **macOS 14 及更早** —— 右键点 云影 CloudCine → 打开 → 再点「打开」。

4. 之后就可以正常双击启动了。

---

## Windows 安装

1. 下载 `cloudcine-x.y.z-windows-x64.msi`，双击，按向导走完即可。

   安装位置是 `%LOCALAPPDATA%\Programs\CloudCine`（即
   `C:\Users\<你>\AppData\Local\Programs\CloudCine`）。
   **按用户安装，不需要管理员权限，不会弹 UAC。** 装完在开始菜单里能找到它。

2. 双击开始菜单里的 云影 CloudCine 启动。程序未做代码签名，SmartScreen 首次运行可能
   提示「Windows 已保护你的电脑」—— 点「更多信息」→「仍要运行」即可，
   **不是文件损坏，也不含恶意代码。**

3. 卸载走「设置 → 应用 → 云影 CloudCine → 卸载」。
   卸载**不会**删除媒体库索引、播放记录与登录凭证（它们在
   `%APPDATA%\com.cloudcine.cloudcine`）；想连数据一起清掉，卸载后手动删掉
   `%APPDATA%\com.cloudcine.cloudcine` 即可。

> 安装包已随包携带 VC++ 运行库，目标机器**不需要**另外安装任何运行时。

**不想安装？** 也可以用 `cloudcine-x.y.z-windows-x64.zip`：**整个解压**得到一个
`cloudcine\` 文件夹，双击里面的 `CloudCine.exe` 直接用。

⚠️ 不要只把 `CloudCine.exe` 拖出来 —— 同目录下的 `flutter_windows.dll`、`data\`
以及各插件 dll 都是运行必需的，缺一个就起不来。

---

## Android 安装（手机 / 平板）

1. 下载 `cloudcine-x.y.z-android.apk`。**这是通用包**：`arm64-v8a`、`armeabi-v7a`、
   `x86`、`x86_64` 四种架构都在里面，不用挑，手机和不同架构的设备装的是同一个文件。

2. 用文件管理器点开这个 APK。系统会提示「未知来源应用」，
   在弹窗里允许一次（各家叫法不同：允许安装未知应用 / 允许来自此来源）。

3. 装好后桌面上显示为 **云影 CloudCine**。

> **签名说明**：本版本使用 **debug 密钥**签名（尚未配置正式发布密钥）。侧载使用完全正常，
> **但请不要上传到 Google Play**。
>
> ⚠️ 另外，**签名不同的包不能互相覆盖安装**：如果你之前装过自己编译的版本
> （比如 `flutter run` 或 Android Studio 装上去的），装这个包时可能提示「应用未安装」。
> 先卸载旧版再装即可 —— 卸载**不会**删除登录凭证与媒体库索引。

---

完整说明（系统要求、源码构建、常见问题、签名校验）见
[README 的「安装」章节](https://github.com/tanchang03/cloudcine#安装)。

> ⚠️ **使用前请先读 [法律声明](https://github.com/tanchang03/cloudcine/blob/main/DISCLAIMER.md)。**
> 本项目是第三方独立开源客户端，与夸克、阿里云盘、百度网盘官方均无关联、未获其授权或认可。
> 仅供播放**你自己账号下、你有合法访问权**的文件，请勿用于账号共享、对外提供服务或商业化用途。

---

## 本次更新
