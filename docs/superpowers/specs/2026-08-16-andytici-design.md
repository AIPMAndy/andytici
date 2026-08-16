# Andy题词 v0.1 Design Spec

**Date**: 2026-08-16
**Author**: Claude (brainstorming session)
**Status**: Approved
**Upstream**: https://github.com/f/textream

---

## 1. Background

textream 是一个成熟的 macOS 提词器 app（MIT 开源），但面向通用场景（直播主、采访者、演讲者、播客）。中文口播创作者（小红书 / 抖音 / 视频号 / 公众号视频）的脚本节奏、平台字数、Hook 模板、语气标记等场景缺少针对性优化。

**Andy题词** = textream 的中文口播特化版，保留上游核心架构（Speech 框架、Dynamic Island 浮窗、BrowserServer 远程投屏），叠加中文 ASR 优化与口播差异化能力。

---

## 2. Goals & Non-Goals

### 2.1 v0.1 Goals
1. 中文口播创作者打开 Andy题词 → 粘贴脚本 → 选中平台预设 → 启动提词器 → 录制全程不卡词
2. 实时语速提示覆盖"快/正常/慢"三档
3. Hook 模板一键插入
4. 表情/语气标记渲染
5. 中文 ASR 默认优于 textream 英文优先
6. 沿用 textream 的远程投屏（手机/iPad 扫码即用）
7. 沿用 textream 的屏幕共享隐藏能力（录制时不漏提词器）
8. MIT 开源 + Homebrew 安装

### 2.2 v0.1 Non-Goals
- AI 改写 / Hook AI 生成（v0.2+）
- 一键导出 SRT 字幕（v0.2+）
- 录制后回顾 / 卡词标记（v0.2+）
- iOS 提词器 App（v0.3+）
- 跨平台（Windows/Linux）（不做）

---

## 3. Branding

| Item | Value |
|---|---|
| Display name (zh-CN) | Andy题词 |
| Display name (en) | Andy Tici |
| Bundle ID | `dev.andy.tici` |
| GitHub repo | `andy/andytici` |
| Homebrew tap | `andy/tici` |
| License | MIT |
| Brand palette | Black `#0A0A0A` + Gold `#FFD700` + Gold-muted `#C9A227` |
| Logo concept | Andy "A" 字 + 金色高光 + 麦克风符号 |

---

## 4. Architecture

### 4.1 Inheritance from textream

完整沿用以下模块（保留文件路径，必要时改命名空间）：
- `NotchOverlayController.swift` — Dynamic Island + 浮窗渲染
- `ExternalDisplayController.swift` — Sidecar / 外接屏
- `BrowserServer.swift` — HTTP + WebSocket 远程投屏
- `PresentationNotesExtractor.swift` — PPTX 导入
- `UpdateChecker.swift` — GitHub release 检测

### 4.2 Modifications（沿用但改造）

| File | Change |
|---|---|
| `TextreamApp.swift` → `AndyTiciApp.swift` | 启动强制 `zh-CN` ASR；替换 app name；URL scheme `andytici://` |
| `ContentView.swift` | 中文 Onboarding；Hook 模板入口；平台预设下拉；品牌色 |
| `SpeechRecognizer.swift` | 默认 locale `zh-CN`；口播常用词白名单（点赞、关注、扣1、上链接、橱窗、3、2、1、上链接…） |
| `NotchSettings.swift` | 增加 `PlatformPreset` / `PacingConfig` / `HookTemplate` 三个配置对象 |
| `MarqueeTextView.swift` | 表情/语气标记渲染层；语速高亮色（绿/红/黄） |
| `Info.plist` | 名称、Bundle ID、麦克风权限文案（中文）、URL scheme |
| `Assets.xcassets` | 替换 AppIcon、AccentColor |
| `README.md` → `README.zh-CN.md` | 中文使用文档 |

### 4.3 New Modules（新增）

| File | Responsibility |
|---|---|
| `PlatformPreset.swift` | 抖音 / 小红书 / 视频号 预设（字数目标、节奏阈值、ASR 语言、浮窗尺寸） |
| `PacingMonitor.swift` | 滑动窗口 5 秒计算「字/分钟」；与阈值比对输出"快/正常/慢"信号 |
| `HookTemplate.swift` | 10+ 爆款开场模板（痛点 / 反差 / 悬念 / 数字） |
| `ScriptTag.swift` | 解析 `🎯/⚡/⏸️/❗/💡` 等 emoji 标签为强调 / 暂停 / 重音 / 提示 |
| `WelcomeView.swift` | 中文首次启动引导页（选平台 → 试模板 → 调浮窗） |
| `KouboVocabulary.swift` | 口播常用词白名单（用于 SFSpeechRecognizer customWords 提示） |

---

## 5. Feature Spec (v0.1)

### 5.1 Platform Preset（平台预设）

用户启动 app 时或在设置中切换平台，下方参数自动生效：

| Platform | 字数目标 | 节奏阈值 (字/分) | 浮窗宽度 | ASR 语言 |
|---|---|---|---|---|
| 抖音 | 200-400 (60s 内) | 180-240 | 320 px | zh-CN |
| 小红书 | 300-600 (90s 内) | 160-220 | 320 px | zh-CN |
| 视频号 | 200-400 (60s 内) | 180-220 | 320 px | zh-CN |
| 自定义 | 用户填写 | 用户填写 | 用户填写 | 用户选 |

实现：
- `PlatformPreset` 是 enum，关联元数据
- `NotchSettings` 持有当前 `selectedPreset`
- 切换时广播 `Notification` 让 `PacingMonitor` / `SpeechRecognizer` / `MarqueeTextView` 重新加载

### 5.2 Pacing Monitor（实时语速）

算法：
- 滑动窗口 5 秒
- 从 `SpeechRecognizer` 拿到每个词的起始时间戳
- 累计窗口内"已说出"的字数
- 输出 `wordsPerMinute: Double` + `status: .slow / .normal / .fast`

UI 反馈：
- 浮窗右上角微型指示器
- 绿（180-220）/ 黄（< 180 或 > 220）/ 红（> 240 或 < 150）
- 数字直接显示"200 字/分"

边界：
- 静音 > 2 秒 → 重置窗口
- 暂停状态 → 不计入

### 5.3 Hook Template（开场模板）

内置 10+ 模板，按类别组织：

```
痛点型：
  - 你是不是也 _____
  - 为什么 _____
  - 说实话 _____

反差型：
  - 99% 的人不知道 _____
  - 99% 的人都做错了 _____
  - 别再 _____

数字型：
  - 3 秒告诉你 _____
  - 一句话讲清楚 _____
  - 一个公式 _____

悬念型：
  - 接下来这个 _____
  - 最近我发现 _____
```

实现：
- `HookTemplate` struct：含 `category`、`template`、`exampleFilled`
- UI：侧边栏 `TemplateList`，点击 → 在脚本编辑器光标位置插入
- 数据源：写在 `HookTemplate.swift` 静态数组里（v0.2 改为 JSON / 文件）

### 5.4 Script Tag（表情/语气标记）

支持的标签：
- `🎯` 关键词强调（高亮 + 字号 +1）
- `⚡` 重点句（高亮 + 暂停提示）
- `⏸️` 强制停顿（浮窗显示 ... 1 秒）
- `❗` 感叹（高亮 + 标红）
- `💡` 提示（主播旁注，斜体小字）
- `🔥` 情绪高潮（高亮 + 闪烁一次）

解析：
- 正则匹配 emoji
- 不删除 emoji，渲染时套样式
- `KouboTextTokenizer` 输出 `(text, tag?)` 元组

### 5.5 Chinese ASR Optimization

- 默认 locale `zh-CN`
- `SFSpeechRecognizer.supportsOnDeviceRecognition` 检测，优先 on-device
- `KouboVocabulary` 提供常用口播词热词提权（在 recognition request 之前注入 contextualStrings）
- 列表：`点赞、关注、扣1、上链接、橱窗、3、2、1、福利、专属、链接、口令、福利价、上新、首发`

### 5.6 Screen Share Hiding
沿用 textream 的 `Hide from screen share`：
- macOS NSWindowSharingNone / NSScreen setAllowedScreen
- 录制时（Zoom、FaceTime、OBS）提词器不出现

### 5.7 Browser Server / Remote
沿用 `BrowserServer.swift`：
- 启动 HTTP + WebSocket on port 7373（可调）
- 暴露 QR code 给用户扫码
- 手机浏览器实时显示提词器内容
- v0.1 增量：浮窗宽度自适应（手机更窄）

### 5.8 PPTX Import
沿用 `PresentationNotesExtractor.swift`：
- 拖入 .pptx → 解压 → 提取 presenter notes
- 多页脚本自动拆分
- v0.1 增量：notes 第一段作为 Hook 提示

### 5.9 Multi-Page Script
沿用：
- `.textream` → `.andytici` 文件格式（JSON，page 数组）
- 多页导航（自动 / 手动）

### 5.10 URL Scheme
```
andytici://read?text=...
```
- 注册在 Info.plist
- 启动 app 并打开浮窗
- 与 textream 行为一致

---

## 6. Data Flow

```
[用户粘贴脚本] 
  → ContentView 编辑器
  → ScriptTag 解析 (生成 token 数组)
  → 保存 .andytici (JSON)

[用户按播放]
  → 浮窗 controller 创建 NSPanel
  → SpeechRecognizer.start() (zh-CN, on-device)
  → PacingMonitor.start() (订阅 speech stream)
  → MarqueeTextView 渲染 token (应用 tag 样式 + 节奏高亮)

[SpeechRecognizer 输出词]
  → 更新 currentTokenIndex
  → 更新 PacingMonitor.wordsPerMinute
  → MarqueeTextView 滚动到当前词
  → PacingMonitor 输出 status → 浮窗右上角指示器变色

[切换平台预设]
  → Notification
  → PacingMonitor 更新阈值
  → SpeechRecognizer 更新 locale (如切换到粤语/英文)
  → NotchSettings 更新浮窗尺寸

[用户切到下一段]
  → ContentView 通知 ScriptController
  → 浮窗自动加载新 page
  → Word index 重置
```

---

## 7. Error Handling

| Failure | Behavior |
|---|---|
| 麦克风权限拒绝 | 弹窗引导到系统设置；fallback 到 classic 模式 |
| on-device ASR 不可用 | 降级到网络 ASR；UI 提示"网络识别" |
| WebSocket 客户端断开 | 5s 重试，3 次失败后提示用户 |
| App 被屏幕共享捕捉 | 检测 → 自动隐藏浮窗 + Toast 提示 |
| 浮窗渲染卡顿 | MarqueeTextView 限帧 30 fps |

---

## 8. Testing Strategy

### 8.1 Unit Tests（XCTest）
- `PacingMonitorTests`：窗口计算、阈值边界、静音重置
- `PlatformPresetTests`：所有枚举 case 参数完整
- `ScriptTagTests`：emoji 解析边界（连续 emoji、空字符串、长文）
- `HookTemplateTests`：模板可插入、所有模板字数 < 30
- `KouboVocabularyTests`：词表去重、不重复

### 8.2 UI Tests
- `WelcomeViewUITests`：首次启动 → 选平台 → 进入主界面
- `PacingIndicatorUITests`：注入 sample stream → 验证指示器变色
- `HookInsertUITests`：点击模板 → 验证插入位置与文本

### 8.3 Manual Smoke
- 跑 5 分钟完整口播脚本，验证 10 个功能点
- 录制视频验证 屏幕共享隐藏
- 在 iPhone Safari 扫码验证远程投屏

---

## 9. Release Plan

### 9.1 v0.1.0 (Week 1-2)
- 上述所有 v0.1 能力
- GitHub Release + DMG
- Homebrew Cask
- README.zh-CN 文档
- 录屏 demo (60s)

### 9.2 v0.2.0 (Optional)
- AI 改写（OpenAI / Anthropic / 自托管）
- 一键 SRT 字幕导出
- 录制后回顾 / 卡词时间轴

### 9.3 v0.3.0 (Future)
- iOS 提词器 App
- 多账号 / 团队协作

---

## 10. Open Questions

| # | Question | Resolution |
|---|---|---|
| 1 | 是否需要粤/英 ASR 支持？ | v0.1 只做 zh-CN，v0.2+ 扩展 |
| 2 | Hook 模板来源？ | v0.1 内置静态数组；v0.2 改为 JSON 可编辑 |
| 3 | 数据统计 / 用户行为采集？ | v0.1 不做（隐私优先） |
| 4 | 开发者 ID 签名？ | v0.1 不签名（ad-hoc 引导）；v0.1.1 加签名 |
| 5 | 是否支持 Apple Watch 远程控制？ | v0.2+ |

---

## 11. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| textream 上游重写 API 变化 | 锁 commit hash；只在本地 fork；不主动同步 |
| macOS Speech 框架中文识别率不稳 | 注入常用词白名单；fallback 网络 ASR |
| NSPanel 跨屏 bug | 沿用 textream 已修复路径，仅调样式 |
| GitHub Actions macOS runner 不可用 | 本地 xcodebuild 验证；release 手动打 DMG |
| 用户误关闭浮窗 | `Esc` 退出保留；增加 `Cmd + .` 全局快捷键 |

---

## 12. Success Metrics

| Metric | Target (v0.1) |
|---|---|
| 首次启动 → 浮窗就绪 | < 10s |
| ASR 词高亮延迟 | < 200ms |
| 语速提示刷新 | < 500ms |
| 浮窗 CPU 占用 | < 5% on M1 |
| App 包大小 | < 30 MB |
| 安装后 7 日留存 | > 30%（如有公开数据） |

---

**Spec 锁定，进入 writing-plans 与实现阶段。**