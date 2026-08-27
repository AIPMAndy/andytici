<p align="center">
  <img src="Textream/Textream/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="112" alt="Andy题词 App 图标">
</p>


<h1 align="center">Andy题词</h1>

<p align="center">
  <strong>会听你读稿的提词器。</strong><br>
  中文口播创作者的 macOS 原生工作台 —— 一边写脚本，一边听你说话，稿子的高亮跟着声音走。
</p>

<p align="center">
  <a href="https://github.com/AIPMAndy/andytici/releases/latest"><strong>下载最新版</strong></a>
  &nbsp;·&nbsp;
  <a href="README.md">English</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/AIPMAndy/andytici/issues">提交反馈</a>
</p>

<p align="center">
  <a href="https://github.com/AIPMAndy/andytici/releases"><img src="https://img.shields.io/github/v/release/AIPMAndy/andytici?style=flat&label=release&color=F5C542" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-111111?style=flat&logo=apple&logoColor=white" alt="macOS 15 或更高版本">
  <img src="https://img.shields.io/badge/license-MIT-111111?style=flat" alt="MIT 许可证">
</p>

<br>

<p align="center">
  <img src="docs/screenshots/hero-editor.png" width="100%" alt="Andy题词 主编辑界面，载入了一篇中文口播稿">
</p>

<p align="center"><sub>一个窗口写稿，一个窗口出镜，应用在中间把两边连起来。</sub></p>

---

## 为什么要「会听」

普通提词器按时间轴滚动。说快了，高亮跑在声音前面三行；停下来想一下，稿子又从眼前溜走。创作者最后变成了读屏幕，而不是看镜头。

Andy题词不靠计时器。它用系统自带的中文语音识别听你读完一段，把高亮拖到你**真正念到的那个词**。你临时改词、停顿、跳过一段，稿子都在等你，眼睛可以一直在镜头附近，语感也保持自然。

## 实际用起来什么样

下面三张图都是从真实运行的版本截下来的，没有渲染图。

**载入脚本后的主编辑界面。** 左侧是页面侧栏，中间是正文编辑器，控制条贴在底部。编辑器里是一段短口播稿，emoji 标记和金色高亮都标在你想要突出的句子上。

<img src="docs/screenshots/hero-editor.png" width="100%" alt="Andy题词 主编辑界面，已经载入了一篇口播稿">

**第一次打开时的空状态。** ⌘V 从剪贴板粘贴、⌘O 打开本地脚本、或者直接把 `.pptx` 拖进窗口。底下金色的提示告诉你 —— 不确定怎么开头时，可以试试「金句」模板。

<img src="docs/screenshots/quick-start.png" width="100%" alt="Andy题词 空状态，提供粘贴 / 打开 / PPTX 拖入三个入口">

**设置面板 —— 高亮看不看得清，全靠这里调。** 一共六个 tab，下面这张是「外观」：字体、字号、当前词的高亮色、下一句的提示色，每行六个色块，深色浅色背景都覆盖。

<img src="docs/screenshots/settings.png" width="100%" alt="Andy题词 设置面板的外观 tab，可以调字体字号和颜色">

---

## 为中文创作者做的取舍

Andy题词的功能设计都围绕中文口播的实际情况：短 Hook、emoji 提示、重复的引导话术、稿子本来就是要念出来的，不是用来默读的。

- **中文优先识别**：用系统 locale 跑识别，同时喂一个小型创作者词库（`KouboVocabulary.swift`）—— 点赞、关注、扣 1、上链接 —— 让高频口播词不会因为不在通用词典里就被听错。
- **Hook 模板与提示标记**：工具栏一键插入 Hook 模板、引导关注块、emoji 项目符号和三种常用「金句」句式。`ScriptTag.swift` 把强调、停顿、金句这些标记在提词浮窗里用不同颜色画出来。
- **多页脚本**：长稿可以拆页，侧栏能拖动排序、改名、跳转。整本脚本保存成可移植的 `.andytici` 包，方便在不同机器之间搬运。
- **对着镜头都能用的版式**：主窗口编辑器、悬浮浮窗（`FloatingOverlayView`）、MacBook 刘海覆盖（`NotchOverlayController`）、外接显示器独占渲染（`ExternalDisplayController`）。挑一个把稿子放在离镜头最近的位置。
- **局域网浏览与导演模式**：打开 `BrowserServer`，同 Wi-Fi 下的另一台设备可以用手机大小的视图跟着看；打开 `DirectorServer`，手机可以远程暂停、跳转、翻页。
- **macOS 服务与 URL Scheme**：在「快捷指令」、Raycast、Alfred 或者任何 app 里选中文字，通过 Services 菜单或者 `andytici://read?text=...` 直接推过来。多行内容记得 URL 编码 `text=` 后面的部分。

### URL Scheme 怎么用

```text
andytici://read?text=%E4%BB%8A%E5%A4%A9%E6%88%91%E4%BB%AC%E8%81%8A%E4%B8%80%E8%81%8A%E5%BC%80%E5%A4%A7%E5%B8%88%E7%9A%84%E6%96%B0%E4%B9%A6
```

处理逻辑在 `TextreamService.swift`：打开 Andy题词、把编码后的文本灌进新页面、起提词浮窗。

---

## 安装

去 [GitHub Releases](https://github.com/AIPMAndy/andytici/releases/latest) 下载最新的 dmg，打开之后把 **Andy题词.app** 拖进 `/Applications` 就行。

当前 release 用的是 ad-hoc 签名。第一次启动 Gatekeeper 会问：

1. 在 Finder 里右键点 **Andy题词.app**，选 **打开**。
2. 再确认一次 **打开**。
3. 打开「跟着声音走」模式时，会请求麦克风和语音识别权限。

这三个确认只需要一次，之后就能正常启动。

## 从源码构建

不用装完整的 Xcode，脚本只依赖 Xcode Command Line Tools。

```bash
git clone https://github.com/AIPMAndy/andytici.git
cd andytici/Textream

# Apple Silicon 本机构建 —— 日常开发用，最快
./build_no_xcode.sh
open build/release/Andy题词.app

# 通用构建 —— 发布用的胖二进制
./build_no_xcode.sh --universal
```

环境要求：

- macOS 15 或更高版本
- Xcode Command Line Tools（`xcode-select --install`）
- 只有用 `Textream.xcodeproj` 打开时才需要 Xcode 16+

脚本会编译 Swift 源文件、组装 App Bundle、重新生成图标、做 ad-hoc 签名。发布流程的细节写在 [RELEASE.md](RELEASE.md)。

<details>
<summary><strong>项目结构</strong></summary>

```text
andytici/
├── README.md
├── README.zh-CN.md
├── RELEASE.md
├── Casks/andytici.rb
├── docs/screenshots/
└── Textream/
    ├── Textream/
    │   ├── ContentView.swift              # 主编辑器 + 侧栏
    │   ├── WelcomeView.swift              # 三步首次启动引导
    │   ├── SettingsView.swift             # 六 tab 设置
    │   ├── SpeechRecognizer.swift         # 声音跟随引擎
    │   ├── SpeechTextAlignment.swift      # 读到的词 → 脚本位置
    │   ├── NotchOverlayController.swift   # MacBook 刘海浮窗
    │   ├── ExternalDisplayController.swift
    │   ├── BrowserServer.swift            # 局域网只读视图
    │   ├── DirectorServer.swift           # 局域网远程控制
    │   ├── TextreamService.swift          # URL Scheme 处理
    │   ├── HookTemplate.swift             # 开场结构模板
    │   ├── ScriptTag.swift                # 内联标记
    │   ├── KouboVocabulary.swift          # 创作者识别词表
    │   └── PlatformPreset.swift           # 抖音 / 小红书 / 视频号预设
    ├── TextreamTests/
    ├── Textream.xcodeproj/
    └── build_no_xcode.sh
```

</details>

---

## 哪些是真的验证过的

这一节老实交代「已经在实机上跑过」和「只是能编译但没真测过」的边界。列表里没写的，就当作未验证。

| 项目 | 状态 |
| --- | --- |
| Apple Silicon（arm64）| 在实机上日常构建与使用 |
| Intel（x86_64）| 通用二进制能编译，但还没在 Intel Mac 上跑过 |
| 代码签名 | ad-hoc 签名，没启用 Apple 公证 |
| 外接显示器模式 | 已实现，只在一台物理副屏上测过 |
| 自动化测试 | XCTest 源文件已存在（`TextreamTests/`），还没配 CI 执行环境 |
| 声音跟随准确率 | 在安静房间 + 真实脚本下可用；嘈杂环境下的表现还没量化 |

边界写在这里方便使用者判断这个版本对自己的场景够不够。

## 参与贡献

欢迎提 Issue 和范围明确的 Pull Request。比较大的改动 —— 新版式、新模式、新识别后端 —— 建议先开 Issue 对齐范围，再动代码。

请沿用现有的 SwiftUI 结构，保留用户界面中文优先的原则，避免给核心提词流程加云端依赖。Andy题词 的核心承诺就是脚本和识别都留在本机。

## 许可证

Andy题词 采用 [MIT License](LICENSE) 开源。

<p align="center">
  <sub>把眼睛留给镜头，把滚动交给 Andy题词。</sub>
</p>
