# Andy题词

> **口播创作者提词器** · 抖音 / 小红书 / 视频号 专用 · 黑金高级感

> ⚠️ **v0.1 状态：源码已就绪，无 DMG 发布包** — 代码完成度已通过 `swiftc -typecheck` + 静态校验全部通过，但当前**未上传签名 `.dmg` 到 GitHub Release**。Homebrew Cask `brew install --cask andytici` 与「手动下载」均暂不可用。请在带 **Xcode 16+ / macOS 13+** 的机器上自行 `open Textream.xcodeproj` 构建，或等待 v0.1.1 正式发布。

Andy题词 是一款面向中文口播创作者的 macOS 原生提词器 App。基于 [textream](https://github.com/f/textream) fork，针对中文创作者场景做了深度增强：实时语速提示、平台预设、开场 Hook 模板、口播表情/语气标记。

![AppIcon](Textream/Textream/Assets.xcassets/AppIcon.appiconset/icon_128x128.png)

---

## 为什么是 Andy题词

| 维度 | 通用提词器 | Andy题词 |
| --- | --- | --- |
| 识别语种 | 多语种通用 | **中文优先**（on-device zh-CN ASR 默认）|
| 口播词库 | 无 | **35 个常用词自动注入**（点赞/关注/上链接/扣1/福利…）|
| 平台预设 | 无 | **抖音 / 小红书 / 视频号** 语速自适应 |
| 实时语速 | 无 | **5 秒滑窗**判断慢/正常/快，颜色提示 |
| Hook 模板 | 无 | **11 个中文开场模板**（痛点/对比/数字/悬念）|
| 脚本标记 | 无 | **🎯/⚡/⏸/❗/💡/🔥** emoji 标记关键词/停顿/高潮 |
| 视觉风格 | 单色 | **黑金 #FFD700 + #0A0A0A** 高级感 |

---

## 功能特性（v0.1）

### 🎙️ 中文优先

- 默认开启本地语音识别（macOS 13+ on-device）
- 中文 ASR locale `zh-CN` 自动注入
- 口播常用词（点赞、关注、扣 1、上链接、福利、家人们、姐妹们…）作为 `contextualStrings`，识别准确率显著提升

### 📱 平台预设

工具栏右上方直接切换平台（抖音 / 小红书 / 视频号 / 自定义），每个预设自带：
- 推荐语速（字/分钟）
- 推荐滚动延迟
- 推荐静音阈值

切换后即时生效，无需重启。

### 🎯 实时语速提示

打开麦克风后，App 会基于最近 5 秒的朗读量评估语速：
- 🟢 **正常**（绿色）
- 🟡 **偏慢**（黄色，可能拖节奏）
- 🔴 **偏快**（红色，可能吃字）
- ⚪ **未检测**（灰色，未开口或静音超过 2 秒）

### ✨ Hook 模板

工具栏新增 **✨ Hook** 按钮，弹出 11 个中文开场模板分类浏览：
- **痛点型**：「你是不是也遇到过 ___？」
- **对比型**：「同样做 ___，为什么别人 ___ 而你 ___？」
- **数字型**：「学会这 3 招 / 5 个步骤 / 7 天 ___」
- **悬念型**：「最后一条最关键 / 99% 的人不知道 / 我赌你没听过」

选中后自动插入到脚本顶部。

### 🎭 脚本 emoji 标记

在脚本里用 emoji 标记语气/重点，App 自动渲染不同样式：

| Emoji | 含义 | 渲染 |
| --- | --- | --- |
| 🎯 | 关键词 | 粗体 + 金色 |
| ⚡ | 重点句 | 黄底黑字 |
| ⏸ | 停顿 | 灰色斜体 |
| ❗ | 感叹 | 红色粗体 |
| 💡 | 提示 | 小一号灰斜 |
| 🔥 | 情绪高潮 | 橙色 heavy |

写稿时直接打 emoji 即可，无需切换工具。

---

## 安装

### Homebrew（推荐）

```bash
brew install --cask andytici
```

### 手动下载

1. 前往 [Releases](https://github.com/AIPMAndy/andytici/releases) 下载最新 `.dmg`
2. 拖入 `Applications` 文件夹
3. 首次启动需在「系统设置 → 隐私与安全性 → 麦克风」中允许

### 自行构建

```bash
git clone https://github.com/AIPMAndy/andytici.git
cd andytici/Textream
open Textream.xcodeproj
# Xcode → Product → Archive → Distribute App
```

需要 Xcode 16+ / Swift 6+ / macOS 13+。

---

## 使用入门

1. **首次启动**：弹出欢迎页，选择你的主要平台（抖音 / 小红书 / 视频号）
2. **新建脚本**：在主编辑器输入或粘贴文案
3. **加入标记**：在重点词前后加 🎯 / ⚡ / ⏸ 等 emoji
4. **打开口播**：点击右上 `▶︎ 启动`，提词器悬浮在屏幕上方
5. **开始朗读**：麦克风识别后自动滚动，未读文字高亮，已读文字变暗

更多进阶设置（外接显示器镜像、远程浏览器控制、Director 模式）见应用内 `设置 →` 菜单。

---

## 项目结构

```
andytici/
├── Textream/
│   ├── Textream/
│   │   ├── PlatformPreset.swift     ← 新增：平台预设
│   │   ├── PacingMonitor.swift      ← 新增：语速监测
│   │   ├── ScriptTag.swift          ← 新增：emoji 标记
│   │   ├── HookTemplate.swift       ← 新增：Hook 模板
│   │   ├── KouboVocabulary.swift    ← 新增：口播词库
│   │   ├── WelcomeView.swift        ← 新增：首次启动
│   │   ├── ContentView.swift        ← 改造：中文 + Hook 入口
│   │   ├── MarqueeTextView.swift    ← 改造：emoji 渲染
│   │   ├── NotchSettings.swift      ← 改造：默认 zh-CN
│   │   ├── SpeechRecognizer.swift   ← 改造：注入词库
│   │   └── …其余继承自 textream
│   └── TextreamTests/               ← 新增：5 套单元测试
└── docs/superpowers/
    ├── specs/2026-08-16-andytici-design.md
    └── plans/2026-08-16-andytici-v0.1.md
```

---

## 与 textream 的关系

Andy题词 是 [textream](https://github.com/f/textream) 的 fork，本项目完全开源（MIT）。

| | textream | Andy题词 |
| --- | --- | --- |
| 核心提词器 | ✅ | ✅（继承） |
| 多语种 ASR | ✅ | ✅（继承 + 中文优先）|
| Notch / 悬浮 / 全屏 | ✅ | ✅（继承）|
| 外接显示器镜像 | ✅ | ✅（继承）|
| 远程浏览器控制 | ✅ | ✅（继承）|
| 平台预设 | ❌ | ✅（新增）|
| 实时语速提示 | ❌ | ✅（新增）|
| Hook 模板 | ❌ | ✅（新增）|
| 脚本 emoji 标记 | ❌ | ✅（新增）|
| 口播词库 | ❌ | ✅（新增）|

如果你的使用场景是英文 / 多语种，建议用上游 [textream](https://github.com/f/textream)。
如果你是中文创作者，希望提词器更懂你，欢迎使用 Andy题词。

---

## 路线图

- **v0.1** ✅ 纯提词器增强（平台预设 + 语速 + Hook + emoji + 词库）
- **v0.2** 计划：脚本片段库（收藏常用口播段落）、多平台一键分发文案改写
- **v0.3** 计划：AI 辅助（生成开场 / 改写口语化 / 自动生成 emoji 标记）
- **v1.0** 计划：跨端（iPad / iPhone 远程遥控 + Apple Watch 翻页）

---

## 致谢

- 上游 [textream](https://github.com/f/textream) — Fatih Kadir Akın / Semih Kışlar — MIT
- 本项目作者：Andy（个人项目）
- 反馈渠道：[GitHub Issues](https://github.com/AIPMAndy/andytici/issues)

## 许可证

MIT — 见 [LICENSE](LICENSE) 文件。
