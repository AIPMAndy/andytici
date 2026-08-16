import SwiftUI

/// Andy题词 中文首次启动引导页
struct WelcomeView: View {
    @Binding var isPresented: Bool
    @State private var step: Int = 0
    @State private var selectedPreset: PlatformPreset = .douyin

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 40)
                .padding(.bottom, 24)

            Spacer()

            Group {
                switch step {
                case 0:
                    introStep
                case 1:
                    presetStep
                default:
                    finishStep
                }
            }
            .frame(maxWidth: .infinity)

            Spacer()

            footer
                .padding(.bottom, 32)
        }
        .frame(width: 520, height: 460)
        .background(AndyTheme.background)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(AndyTheme.gold)
            Text("Andy题词")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(AndyTheme.gold)
        }
    }

    private var introStep: some View {
        VStack(spacing: 16) {
            Text("欢迎使用")
                .font(.title2)
                .foregroundColor(AndyTheme.textPrimary)
            Text("中文口播创作者的智能提词器")
                .font(.title3)
                .foregroundColor(AndyTheme.textSecondary)
            VStack(alignment: .leading, spacing: 8) {
                feature(icon: "speedometer", text: "实时语速提示")
                feature(icon: "tv", text: "Dynamic Island 浮窗")
                feature(icon: "qrcode.viewfinder", text: "手机扫码远程投屏")
                feature(icon: "eye.slash", text: "录制时自动隐藏")
            }
            .padding(.top, 8)
        }
    }

    private var presetStep: some View {
        VStack(spacing: 16) {
            Text("选择主要发布平台")
                .font(.title3)
                .foregroundColor(AndyTheme.textPrimary)
            Picker("平台", selection: $selectedPreset) {
                ForEach(PlatformPreset.allPresets, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            VStack(spacing: 4) {
                Text("字数目标：\(selectedPreset.charTarget)")
                    .font(.callout)
                    .foregroundColor(AndyTheme.textSecondary)
                Text("节奏区间：\(selectedPreset.pacingMin)–\(selectedPreset.pacingMax) 字/分")
                    .font(.callout)
                    .foregroundColor(AndyTheme.textSecondary)
            }
            .padding(.top, 8)
        }
    }

    private var finishStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(AndyTheme.gold)
            Text("准备好了！")
                .font(.title2)
                .foregroundColor(AndyTheme.textPrimary)
            Text("粘贴你的脚本，按 ⌘P 开始提词")
                .font(.body)
                .foregroundColor(AndyTheme.textSecondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if step > 0 && step < 2 {
                Button("返回") { step -= 1 }
                    .buttonStyle(.bordered)
                    .foregroundColor(AndyTheme.textSecondary)
            }
            Spacer()
            Button(step == 0 ? "开始" : (step == 1 ? "继续" : "开始使用")) {
                if step < 2 {
                    step += 1
                } else {
                    UserDefaults.standard.set(selectedPreset.persistenceKey, forKey: "selectedPlatformPreset")
                    UserDefaults.standard.set(true, forKey: "hasShownWelcome")
                    isPresented = false
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(AndyTheme.gold)
        }
        .padding(.horizontal, 40)
    }

    private func feature(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(AndyTheme.gold)
                .frame(width: 24)
            Text(text)
                .foregroundColor(AndyTheme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 60)
    }
}

/// Andy题词 品牌色
enum AndyTheme {
    static let gold = Color(red: 1.0, green: 0.843, blue: 0.0)
    static let goldMuted = Color(red: 0.788, green: 0.635, blue: 0.0)
    static let background = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.7)
}