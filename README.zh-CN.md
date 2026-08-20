<p align="center">
  <img src="Textream/Textream/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="112" alt="Andy题词 App 图标">
</p>

<h1 align="center">Andy题词</h1>

<p align="center">
  <strong>会听你说话的提词器。</strong><br>
  为抖音、小红书、视频号中文口播创作者打造的 macOS 原生工作台。
</p>

<p align="center">
  <a href="https://github.com/AIPMAndy/andytici/releases"><img src="https://img.shields.io/github/v/release/AIPMAndy/andytici?style=flat&label=release&color=F5C542" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-111111?style=flat&logo=apple&logoColor=white" alt="需要 macOS 15 或更高版本">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-111111?style=flat" alt="通用架构">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/AIPMAndy/andytici?style=flat&color=111111" alt="MIT 许可证"></a>
</p>

<p align="center">
  <a href="https://github.com/AIPMAndy/andytici/releases/latest"><strong>下载最新版</strong></a>
  &nbsp;·&nbsp;
  <a href="README.md">English</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/AIPMAndy/andytici/issues">提交反馈</a>
</p>

<br>

<p align="center">
  <img src="docs/screenshots/andy-tici-main.png" width="100%" alt="Andy题词中文口播稿编辑界面">
</p>

<p align="center"><sub>写稿、分段、排练和提词，都在同一个创作流程里完成。</sub></p>

---

## 跟着你，不催着你

普通提词器按照固定速度滚动：说快了跟不上，停下来想一想，稿子却已经跑远。

Andy题词会听你读到哪里，让高亮跟着声音走。你可以暂停、重说一句，甚至临场换个表达，不必追赶屏幕。眼睛更接近镜头，口播也更自然。

| | |
| --- | --- |
| **🎙 跟随声音高亮**<br>中文语音识别定位当前词，不靠计时器猜测朗读进度。 | **🧠 中文口播词库**<br>把点赞、关注、扣1、上链接等高频词作为识别上下文，提高创作者场景的匹配能力。 |
| **🖥 适配拍摄场景**<br>支持主窗口、悬浮提词、MacBook 刘海区域和外接显示器。 | **🔒 本地优先**<br>无需注册账号，也没有遥测；脚本以便携的 `.andytici` 文档保存在本机。 |

## 三步开始口播

1. **粘贴或打开脚本**：长稿可以拆成多页，并为停顿、重点和金句加入视觉标记。
2. **调整提词方式**：设置字体、宽度、位置、滚动方式和显示模式。
3. **开始自然朗读**：当前内容持续高亮，Andy题词根据你的声音推进。

## 为中文创作者而生

- **中文优先识别**：支持调整识别语言，并加入常用口播词作为上下文
- **多页脚本管理**：使用轻量的 `.andytici` 格式保存和分享
- **Hook 模板与提示标记**：快速插入开场结构、重点、停顿和金句
- **刘海、悬浮与外接屏模式**：适配不同镜头和拍摄设备
- **局域网浏览与导演模式**：让同一网络中的另一台设备查看或控制进度
- **macOS 服务与 URL Scheme**：从快捷指令、Raycast、Alfred 或其他应用发送文稿

### 自动化调用

```text
andytici://read?text=今天我们聊一聊...
```

传入多行文稿时，请先对 `text=` 后面的内容进行 URL 编码。

---

## 安装

前往 [GitHub Releases](https://github.com/AIPMAndy/andytici/releases/latest) 下载最新磁盘镜像，打开后将 **Andy题词.app** 拖入 `/Applications`。

当前版本使用 ad-hoc 签名，macOS 首次启动时可能需要手动确认：

1. 在 Finder 中右键点击 **Andy题词.app**，选择 **打开**。
2. 再次确认 **打开**。
3. 需要语音跟随时，允许麦克风与语音识别权限。

上述安全确认通常只需要完成一次。

## 从源码构建

不安装完整 Xcode 也可以构建，推荐脚本只依赖 Xcode Command Line Tools。

```bash
git clone https://github.com/AIPMAndy/andytici.git
cd andytici/Textream

# Apple Silicon 本机构建，速度最快
./build_no_xcode.sh
open build/release/Andy题词.app

# Apple Silicon + Intel 通用构建
./build_no_xcode.sh --universal
```

环境要求：

- macOS 15 或更高版本
- Xcode Command Line Tools（`xcode-select --install`）
- 只有通过 `Textream.xcodeproj` 构建时才需要 Xcode 16+

命令行脚本会编译 Swift 源码、组装 App Bundle、生成图标并完成 ad-hoc 签名。发布流程见 [RELEASE.md](RELEASE.md)。

<details>
<summary><strong>项目结构</strong></summary>

```text
andytici/
├── README.md
├── README.zh-CN.md
├── RELEASE.md
├── Casks/
│   └── andytici.rb
├── docs/
│   └── screenshots/
└── Textream/
    ├── Textream/
    │   ├── ContentView.swift
    │   ├── SpeechRecognizer.swift
    │   ├── MarqueeTextView.swift
    │   ├── NotchOverlayController.swift
    │   ├── ExternalDisplayController.swift
    │   ├── BrowserServer.swift
    │   └── DirectorServer.swift
    ├── TextreamTests/
    ├── Textream.xcodeproj/
    └── build_no_xcode.sh
```

</details>

## 当前状态

最新公开版本为 **v0.1.1**。

| 项目 | 状态 |
| --- | --- |
| Apple Silicon | 已在真实设备构建和日常使用 |
| Intel | 通用二进制可编译，尚未在 Intel Mac 实机验证 |
| 代码签名 | 当前为 ad-hoc 签名，尚未启用 Apple 公证 |
| 外接显示器 | 功能已实现，真实副屏覆盖仍有限 |
| 自动化测试 | 已有 XCTest 源文件，暂未配置 CI 执行环境 |

这里明确区分已经验证和仍待验证的能力，方便使用者判断当前边界。

## 参与贡献

欢迎提交 Issue 和范围明确的 Pull Request。较大改动建议先开 Issue 对齐目标，再开始实现。

请沿用现有 SwiftUI 结构，保持用户界面中文优先，并避免让核心提词流程依赖云端服务。

## 许可证

Andy题词采用 [MIT License](LICENSE) 开源。

<p align="center">
  <sub>把眼睛留给镜头，把滚动交给 Andy题词。</sub>
</p>
