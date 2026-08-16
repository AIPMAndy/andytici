import Foundation

/// 语速状态：慢/正常/快/未开始
enum PacingStatus: Equatable {
    case idle
    case slow
    case normal
    case fast

    var displayName: String {
        switch self {
        case .idle: return "—"
        case .slow: return "慢"
        case .normal: return "✓"
        case .fast: return "快"
        }
    }
}

/// 实时语速监测器
/// - 滑动窗口 5 秒统计「字/分钟」
/// - 静音超过 2 秒自动重置
final class PacingMonitor {
    private struct WordEvent { let timestamp: Date }
    private var events: [WordEvent] = []
    private let windowSeconds: TimeInterval = 5.0
    private let silenceResetSeconds: TimeInterval = 2.0

    /// 最近窗口内的「字/分钟」
    var wordsPerMinute: Double {
        let now = Date()
        let recent = events.filter { now.timeIntervalSince($0.timestamp) <= windowSeconds }
        guard recent.count >= 2 else { return 0 }
        let elapsed = recent.last!.timestamp.timeIntervalSince(recent.first!.timestamp)
        guard elapsed > 0 else { return 0 }
        return Double(recent.count) * 60.0 / elapsed
    }

    /// 当前状态（基于 wordsPerMinute 与平台阈值）
    /// - Parameters:
    ///   - preset: 平台预设，用于阈值（默认使用 .douyin 的 180-240）
    func status(for preset: PlatformPreset = .douyin) -> PacingStatus {
        let wpm = wordsPerMinute
        if wpm < 1 { return .idle }
        if wpm < Double(preset.pacingMin) { return .slow }
        if wpm > Double(preset.pacingMax) { return .fast }
        return .normal
    }

    /// 记录一个词被说出（或识别）
    func recordWord(at date: Date = Date()) {
        if let last = events.last, date.timeIntervalSince(last.timestamp) > silenceResetSeconds {
            events.removeAll()
        }
        events.append(WordEvent(timestamp: date))
    }

    /// 重置（暂停 / 重新开始时调用）
    func reset() {
        events.removeAll()
    }
}