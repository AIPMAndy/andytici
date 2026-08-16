import Foundation

/// Andy题词 支持的发布平台预设
enum PlatformPreset: Equatable, Hashable {
    case douyin
    case xiaohongshu
    case shipinhao
    case custom(charTarget: Int, pacingMin: Int, pacingMax: Int, locale: String, overlayWidth: Int)

    var charTarget: Int {
        switch self {
        case .douyin: return 300
        case .xiaohongshu: return 450
        case .shipinhao: return 300
        case .custom(let n, _, _, _, _): return n
        }
    }

    var pacingMin: Int {
        switch self {
        case .douyin: return 180
        case .xiaohongshu: return 160
        case .shipinhao: return 180
        case .custom(_, let lo, _, _, _): return lo
        }
    }

    var pacingMax: Int {
        switch self {
        case .douyin: return 240
        case .xiaohongshu: return 220
        case .shipinhao: return 220
        case .custom(_, _, let hi, _, _): return hi
        }
    }

    var locale: String {
        switch self {
        case .douyin, .xiaohongshu, .shipinhao: return "zh-CN"
        case .custom(_, _, _, let loc, _): return loc
        }
    }

    var overlayWidth: Int {
        switch self {
        case .douyin, .xiaohongshu, .shipinhao: return 320
        case .custom(_, _, _, _, let w): return w
        }
    }

    var displayName: String {
        switch self {
        case .douyin: return "抖音"
        case .xiaohongshu: return "小红书"
        case .shipinhao: return "视频号"
        case .custom: return "自定义"
        }
    }

    /// 持久化 key（写入 UserDefaults 用）
    var persistenceKey: String {
        switch self {
        case .douyin: return "douyin"
        case .xiaohongshu: return "xiaohongshu"
        case .shipinhao: return "shipinhao"
        case .custom: return "custom"
        }
    }

    /// 从持久化 key 反解
    static func from(persistenceKey: String) -> PlatformPreset {
        switch persistenceKey {
        case "xiaohongshu": return .xiaohongshu
        case "shipinhao": return .shipinhao
        case "custom": return .custom(charTarget: 300, pacingMin: 180, pacingMax: 240, locale: "zh-CN", overlayWidth: 320)
        default: return .douyin
        }
    }

    /// 用于 Picker 展示的固定预设列表（不含 custom）
    static var allPresets: [PlatformPreset] {
        [.douyin, .xiaohongshu, .shipinhao]
    }
}