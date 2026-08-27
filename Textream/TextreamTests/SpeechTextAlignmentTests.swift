import XCTest
@testable import Textream

final class SpeechTextAlignmentTests: XCTestCase {
    func testCandidateOffsetUsesAbsoluteMatcherCoordinatesAfterRestart() {
        XCTAssertEqual(
            SpeechTextAlignment.candidateOffset(
                characterResult: 238,
                wordResult: 242,
                sourceTextCount: 500
            ),
            240
        )
    }

    func testLongChineseScriptDoesNotDoubleCountMidScriptProgress() throws {
        let script = """
        拍视频你是不是老忘词？我也是一样的。所以我就干脆手搓了一个，并且免费开源，
        最近我尝试拍口播结果老忘词。
        后来我用提词器，结果更灾难
        我说快了，它跟不上；我一停，它还在跑。
        最后我不是在说话，我是在追字幕。
        后来我受不了了，
        我干脆自己写了一个。
        它叫Andy 题词。
        以前，是我追着字幕跑。
        现在，字幕跟着我的声音走。
        我说快，它跟快；
        我停，它就等我。
        觉得好的提词器，
        应该让我忘记它的存在。
        这个开源工具呢，全场景适配，支持主窗、刘海屏、悬浮和外接屏。
        并且本地优先，也不用注册，稿子直接存在本机。
        本来只是给自己写的，后来干脆开源了。
        我是Andy，有好东西就喜欢开源。
        """
        let restartOffset = try XCTUnwrap(script.range(of: "现在，字幕跟着我的声音走"))
        let restartCharacterOffset = script.distance(from: script.startIndex, to: restartOffset.lowerBound)
        let nextPhrase = try XCTUnwrap(script.range(of: "我说快，它跟快"))
        let absoluteMatch = script.distance(from: script.startIndex, to: nextPhrase.upperBound)

        XCTAssertGreaterThan(restartCharacterOffset, 0)
        XCTAssertEqual(
            SpeechTextAlignment.candidateOffset(
                characterResult: absoluteMatch,
                wordResult: absoluteMatch,
                sourceTextCount: script.count
            ),
            absoluteMatch
        )
        XCTAssertLessThan(absoluteMatch, restartCharacterOffset + absoluteMatch)
    }

    func testCandidateOffsetClampsToScriptBounds() {
        XCTAssertEqual(
            SpeechTextAlignment.candidateOffset(
                characterResult: 900,
                wordResult: 920,
                sourceTextCount: 300
            ),
            300
        )
    }

    func testChineseContextHintsRemainAvailableAfterMidScriptRestart() throws {
        let script = """
        拍视频你是不是老忘词？我也是一样的。所以我就干脆手搓了一个，并且免费开源，
        最近我尝试拍口播结果老忘词。
        现在，字幕跟着我的声音走。
        我说快，它跟快；
        我停，它就等我。
        """
        let normalized = splitTextIntoWords(script).joined(separator: " ").lowercased()
        let restartText = try XCTUnwrap(normalized.range(of: "现 在"))
        let restartOffset = normalized.distance(from: normalized.startIndex, to: restartText.lowerBound)
        let hints = SpeechContextHints.upcoming(
            in: Array(normalized),
            from: restartOffset
        )

        XCTAssertTrue(hints.contains("现在"))
        XCTAssertTrue(hints.contains("字幕跟着我的声音走"))
        XCTAssertTrue(hints.contains("我说快"))
        XCTAssertFalse(hints.contains(where: { $0.count == 1 }))
    }

    func testContextHintMergeIsStableAndKeepsScriptPhrasesFirst() {
        XCTAssertEqual(
            SpeechContextHints.merging(
                ["字幕跟着我的声音走", "Andy题词", "Andy题词"],
                ["点赞", "字幕跟着我的声音走"],
                limit: 3
            ),
            ["字幕跟着我的声音走", "Andy题词", "点赞"]
        )
    }

    func testProductNameRemainsAvailableAsRecognitionContext() {
        let hints = SpeechContextHints.merging([], KouboVocabulary.words, limit: 80)

        XCTAssertTrue(hints.contains("Andy题词"))
        XCTAssertTrue(hints.contains("安迪题词"))
    }
}
