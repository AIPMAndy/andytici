import Foundation

/// 口播脚本中的 emoji 标记 token
struct ScriptTagToken: Equatable, Hashable {
    enum Tag: Character, CaseIterable {
        case emphasis = "\u{1F3AF}"     // 🎯 关键词
        case highEnergy = "\u{26A1}"   // ⚡ 重点句
        case pause = "\u{23F8}"        // ⏸ 停顿
        case exclaim = "\u{2757}"      // ❗ 感叹
        case hint = "\u{1F4A1}"        // 💡 提示
        case climax = "\u{1F525}"      // 🔥 情绪高潮

        var displayName: String {
            switch self {
            case .emphasis: return "关键词"
            case .highEnergy: return "重点句"
            case .pause: return "停顿"
            case .exclaim: return "感叹"
            case .hint: return "提示"
            case .climax: return "情绪高潮"
            }
        }
    }

    let text: String
    let tag: Tag?

    init(text: String, tag: Tag? = nil) {
        self.text = text
        self.tag = tag
    }
}

/// 将脚本文本解析为 token 序列（保留 emoji 标记）
enum ScriptTag {
    static let tagCharacters: Set<Character> = Set(ScriptTagToken.Tag.allCases.map { $0.rawValue })

    static func tokenize(_ source: String) -> [ScriptTagToken] {
        var tokens: [ScriptTagToken] = []
        var buffer = ""
        for ch in source {
            if let matched = ScriptTagToken.Tag(rawValue: ch) {
                if !buffer.isEmpty {
                    tokens.append(ScriptTagToken(text: buffer, tag: nil))
                    buffer = ""
                }
                tokens.append(ScriptTagToken(text: String(ch), tag: matched))
            } else {
                buffer.append(ch)
            }
        }
        if !buffer.isEmpty {
            tokens.append(ScriptTagToken(text: buffer, tag: nil))
        }
        return tokens
    }

    /// 给定一个单词（通常是 splitTextIntoWords 的输出），如果它恰好是某个标记 emoji，则返回对应 Tag
    static func tagForWord(_ word: String) -> ScriptTagToken.Tag? {
        guard word.count == 1, let ch = word.first else { return nil }
        return ScriptTagToken.Tag(rawValue: ch)
    }
}