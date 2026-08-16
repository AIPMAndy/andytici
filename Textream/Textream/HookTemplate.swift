import Foundation

/// 口播开场模板（一键插入到脚本开头）
struct HookTemplate: Identifiable, Equatable, Hashable {
    enum Category: String, CaseIterable, Hashable {
        case painPoint = "痛点型"
        case contrast = "反差型"
        case number = "数字型"
        case suspense = "悬念型"
    }

    let id: UUID
    let category: Category
    let template: String
    let exampleFilled: String

    init(category: Category, template: String, exampleFilled: String) {
        self.id = UUID()
        self.category = category
        self.template = template
        self.exampleFilled = exampleFilled
    }

    /// 用占位符内容填充模板
    /// - Parameter input: 替换 "_____" 的内容
    func fill(with input: String) -> String {
        template.replacingOccurrences(of: "_____", with: input)
    }

    /// 内置 11 个爆款开场模板
    static let all: [HookTemplate] = [
        // 痛点型
        HookTemplate(category: .painPoint, template: "你是不是也 _____", exampleFilled: "你是不是也经常加班到深夜"),
        HookTemplate(category: .painPoint, template: "为什么 _____ 总是做不好", exampleFilled: "为什么你的视频总是没人看"),
        HookTemplate(category: .painPoint, template: "说实话，_____ 真的很难", exampleFilled: "说实话，坚持日更真的很难"),
        // 反差型
        HookTemplate(category: .contrast, template: "99% 的人不知道 _____", exampleFilled: "99% 的人不知道这个 AI 工具"),
        HookTemplate(category: .contrast, template: "99% 的人都做错了 _____", exampleFilled: "99% 的人都做错了选题"),
        HookTemplate(category: .contrast, template: "别再 _____ 了", exampleFilled: "别再傻傻地手动剪辑了"),
        // 数字型
        HookTemplate(category: .number, template: "3 秒告诉你 _____", exampleFilled: "3 秒告诉你怎么写标题"),
        HookTemplate(category: .number, template: "一句话讲清楚 _____", exampleFilled: "一句话讲清楚什么是 RAG"),
        HookTemplate(category: .number, template: "一个公式搞定 _____", exampleFilled: "一个公式搞定口播脚本"),
        // 悬念型
        HookTemplate(category: .suspense, template: "接下来这个 _____ 一定要看完", exampleFilled: "接下来这个工具一定要看完"),
        HookTemplate(category: .suspense, template: "最近我发现 _____", exampleFilled: "最近我发现一个爆款规律"),
    ]
}