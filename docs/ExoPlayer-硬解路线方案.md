# 在云影上接入 Media3 ExoPlayer（方案 1：自建 Android 播放内核）

> 起草日期：2026-10-05
> 背景：小米 MiTV 上 fvp/libmdk 的 MediaCodec 链在 MiTV 硬解不成功（`VDEC Exit` / 300% CPU），
> 而夸克（ExoPlayer 路线）播同片源 4K 仅 30% CPU。本方案规划用 Media3 ExoPlayer 替换 fvp 在
> Android TV 上的位置。macOS 的 DV 路不动。

---

## 0. 目标和验收

| # | 指标 | 目标 |
|---|---|---|
| 1 | `[资源]` CPU | 小米 TV 4K 从 300% 降到华为同等水平（100~160%） |
| 2 | 画面 | 4K 原画有画面、音画同步、不掉帧 |
| 3 | 路由 | TV 4K 走 ExoPlayer；其他档位 / macOS 不变 |

---

## 1. 阶段切分

```
P0 探针/路由：PlaybackController + Router 增加 ExoPlayer 候选线（和现有 DV 判据并列）
P1 实现 ExoPlaybackEngine：open/seek/volume/rate/track/subtitle/events/disposal
P2 UI 对接：PlaybackSurface 新增 ExoPlayer 分支（SurfaceView/TextureView）
P3 测试和真机：analyze + test + MiTV 4K/1080p + 华为对比
```

---

## 2. 细化清单

### 2.1 依赖
- `media3-exoplayer`（google Media3 1.x）
- `media3-ui`（可选，控制栏用 ExoPlayer 自带）
- 带库 `media3-exoplayer-dash`/`media3-exoplayer-hls`/`media3-extractor`

### 2.2 `PlaybackEngine` 新实现 `ExoPlaybackEngine`
- 位置：`lib/data/playback/exo_playback_engine.dart`
- 必须满足契约全部字段：playing/buffering/position/duration/bufferEnd/volume/rate/tracks/activeAudioTrackId/activeSubtitleTrackId/completed/error/log/videoSize/bufferingPercentage/networkSpeed/chapters()
- chapters() 先返回空（fvp 路已有空缺口子，UI 置灰）
- 字幕：外挂 SRT/ASS 通过 Media3 的 `SubtitleConfiguration`；样式无法与 mpv 对齐，保持 libass 那条不能烧，对外按 fvp 处理
- 音效/rawLog/networkSpeed/rawProperty：直接返回 EngineCapabilities.mdk 等价，UI 置灰

### 2.3 `PlaybackSurface`
- 新增 `ExoPlaybackEngine` 分支 → `PlayerView`
- 同 fvp 那样，StatefulWidget 缓存子树避免 position tick 重建
- 不接 `fit` 之外的逻辑，用 `SurfaceView` 路（skip `AspectRatio`）

### 2.4 路由
- `PlaybackEngineRouter` 把当前 `dolbyVisionEngine`（fvp）工厂和 TV 4K 目标分开：TV 4K 切 ExoPlayer，DV P5 切 fvp
- `highResTvRoute=true && height>=2160 && Platform.isAndroid → ExoPlaybackEngine`
- DV P5 && Platform.isAndroid → FvpPlaybackEngine（不变，macOS 也不变）

### 2.5 `EngineCapabilities`
- `ExoPlaybackEngine.capabilities` = `SurfaceOutput.platformView` + mdk 的缺项（audioEffects/networkSpeed/rawLog/rawProperty 都 false，与 fvp 一致）

### 2.6 原生配置
- `AndroidManifest`：`usesCleartextTraffic=true`（夸克直链是 http）
- `android/app/build.gradle.kts`：加 Media3 依赖、NDK 26（已锁）

---

## 3. 风险 / 回退

| 风险 | 缓解 |
|---|---|
| DV 判据被 ExoPlayer 抢走 | DV 判据在 ExoPlayer 线之前，电视 DV 还是 fvp |
| SRT 样式 / 外挂字幕展示和 mpv 不一致 | 文档明告 4K TV 档位字幕样式走 Android 端默认 |
| Media3 版本兼容（API 不稳定） | 固定 Media3 1.x 版本不升 |
| MiTV 硬件对 Exo 播放的支持同样差 | 阶段 P3 验不通就 revert 阈值 |

**回退点**（保持一句话能回滚）：
- `playback_engine_router.dart` 阈值恢复 2160
- `playback_engine_router.dart` 电视高分辨率分支不进 ExoPlayer
- `app_providers.dart` 的 Android TV 分支去掉 exo 工厂

---

## 4. 工期估计

±1 天（1 个开发日）：依赖+线路由验通 0.5 天、ExoPlaybackEngine 实现 0.5 天、UI 接入 0.5 天、真机对比 0.5 天。

---

## 5. 验证步骤

1. `flutter analyze` + `flutter test`
2. `flutter build apk --release` 装 MiTV
3. 播同一个 4K HEVC 片源：
   - `[资源]` CPU 是否跌到 100~160%
   - `FvpPlugin`/`ExoPlayer` logcat 是否有独立解码线程
   - 画面流畅度对比夸克
4. 如果不通过，执行第 3 节的回退点
