import Foundation

enum SpeechContextHints {
    private static let maximumCJKPhraseLength = 12

    /// Builds phrases for Apple's speech recognizer from the normalized source.
    /// Andy题词 inserts spaces between CJK display tokens, so treating every space
    /// as a word boundary leaves Chinese scripts with no usable contextual hints.
    static func upcoming(
        in characters: [Character],
        from startOffset: Int,
        lookaheadCharacters: Int = 1500
    ) -> [String] {
        let start = max(0, min(startOffset, characters.count))
        let length = max(0, lookaheadCharacters)
        let end = min(start + length, characters.count)
        guard start < end else { return [] }

        var hints: [String] = []
        hints.reserveCapacity(32)
        var cjkPhrase = ""
        var latinWord = ""

        func flushLatinWord() {
            if latinWord.count >= 5 {
                hints.append(latinWord)
            }
            latinWord.removeAll(keepingCapacity: true)
        }

        func flushCJKPhrase() {
            if cjkPhrase.count >= 2 {
                hints.append(cjkPhrase)
            }
            cjkPhrase.removeAll(keepingCapacity: true)
        }

        for index in start..<end {
            let character = characters[index]
            if isCJK(character) {
                flushLatinWord()
                cjkPhrase.append(character)
                if cjkPhrase.count == maximumCJKPhraseLength {
                    flushCJKPhrase()
                }
            } else if character.isLetter || character.isNumber {
                flushCJKPhrase()
                latinWord.append(character)
            } else if character.isWhitespace {
                // Spaces between Chinese display tokens are synthetic. Preserve
                // the CJK phrase while still ending ordinary Latin words.
                flushLatinWord()
            } else {
                flushLatinWord()
                flushCJKPhrase()
            }
        }
        flushLatinWord()
        flushCJKPhrase()
        return hints
    }

    /// Stable deduplication keeps nearby script phrases ahead of generic terms.
    static func merging(_ primary: [String], _ fallback: [String], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(min(limit, primary.count + fallback.count))
        for hint in primary + fallback where seen.insert(hint).inserted {
            result.append(hint)
            if result.count == limit { break }
        }
        return result
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (value >= 0x4E00 && value <= 0x9FFF)
                || (value >= 0x3400 && value <= 0x4DBF)
                || (value >= 0x20000 && value <= 0x2A6DF)
                || (value >= 0xF900 && value <= 0xFAFF)
                || (value >= 0x3040 && value <= 0x30FF)
                || (value >= 0xAC00 && value <= 0xD7AF)
        }
    }
}

enum SpeechTextAlignment {
    static func annotationFlags(for words: [String]) -> [Bool] {
        var closingAtOrAfter = Array(repeating: false, count: words.count)
        var hasClosing = false
        for index in words.indices.reversed() {
            if words[index].contains("]") {
                hasClosing = true
            }
            closingAtOrAfter[index] = hasClosing
        }

        var flags: [Bool] = []
        var isInsideAnnotation = false
        for (index, word) in words.enumerated() {
            let beginsAnnotation = word.hasPrefix("[") && closingAtOrAfter[index]
            let isAnnotation = isInsideAnnotation || beginsAnnotation
            flags.append(isAnnotation)
            if beginsAnnotation {
                isInsideAnnotation = true
            }
            if isInsideAnnotation && word.contains("]") {
                isInsideAnnotation = false
            }
        }
        return flags
    }

    static func annotationRanges(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var openingIndex: Int?

        for (index, character) in text.enumerated() {
            if character == "[" && openingIndex == nil {
                openingIndex = index
            } else if character == "]", let start = openingIndex {
                ranges.append(start..<(index + 1))
                openingIndex = nil
            }
        }

        return ranges
    }

    /// Cursor-based O(1)-amortized advance over sorted annotation ranges.
    ///
    /// `annotationRanges` is built by `annotationRanges(in:)` which appends
    /// in openingIndex order, so ranges are sorted by lowerBound. During
    /// normal ASR flow offsets only increase — a monotonic cursor over the
    /// sorted ranges eliminates the per-call `first(where:)` linear scans.
    /// `cursor` must be reset (set to 0) whenever `ranges` is rebuilt.
    static func advancePastAnnotations(
        in chars: [Character],
        ranges: [Range<Int>],
        from offset: Int,
        cursor: inout Int
    ) -> Int {
        let charCount = chars.count
        var current = max(0, min(offset, charCount))
        let rangeCount = ranges.count
        if rangeCount == 0 { return current }

        // Clamp cursor into bounds; reset on backward jump (manual page jump,
        // source edit that shifted annotations).
        if cursor >= rangeCount {
            cursor = rangeCount - 1
        }
        if cursor > 0, ranges[cursor].lowerBound > current {
            cursor = 0
        }

        var skippedAnnotation = false

        while current < charCount {
            // Advance cursor past ranges whose upperBound is at or before
            // current. O(1) amortized over the lifetime of a stream.
            while cursor < rangeCount, ranges[cursor].upperBound <= current {
                cursor += 1
            }
            if cursor < rangeCount, ranges[cursor].contains(current) {
                current = ranges[cursor].upperBound
                skippedAnnotation = true
                continue
            }

            var next = current
            while next < charCount, chars[next].isWhitespace {
                next += 1
            }

            // Find range whose lowerBound is exactly `next` — cursor only
            // moves forward, never restarts.
            while cursor < rangeCount, ranges[cursor].lowerBound < next {
                cursor += 1
            }
            if cursor < rangeCount, ranges[cursor].lowerBound == next {
                current = ranges[cursor].upperBound
                cursor += 1
                skippedAnnotation = true
                continue
            }

            return skippedAnnotation ? next : current
        }

        return current
    }

    /// Combine the character-level and word-level match results into a single
    /// forward offset. When they roughly agree, average them. When they
    /// disagree, prefer the further match: the word-level scan advances
    /// in-order and monotonically, so trusting it lets fast reading catch up
    /// instead of being dragged back by the brittle character scan that
    /// desyncs over long spans. `shouldCommit` still gates single-strategy
    /// (one result is zero) jumps behind confirmation.
    static func bestOffset(
        characterResult: Int,
        wordResult: Int,
        agreementTolerance: Int = 20
    ) -> Int {
        if abs(characterResult - wordResult) <= agreementTolerance {
            return (characterResult + wordResult) / 2
        }
        return max(characterResult, wordResult)
    }

    /// Both matchers return absolute character offsets into the full script.
    /// Keep that coordinate system when clamping the combined result. Adding
    /// the recognition segment's start offset here would double-count progress
    /// after the speech task restarts in the middle of a long script.
    static func candidateOffset(
        characterResult: Int,
        wordResult: Int,
        sourceTextCount: Int
    ) -> Int {
        min(
            max(0, bestOffset(characterResult: characterResult, wordResult: wordResult)),
            max(0, sourceTextCount)
        )
    }

    static func shouldCommit(
        characterResult: Int,
        wordResult: Int,
        current: Int,
        rawCandidate: Int,
        candidate: Int,
        confirmed: Bool
    ) -> Bool {
        // When both the character and word strategies independently found
        // forward progress, trust the (conservative) match even if they land
        // at different offsets. A false positive would require both strategies
        // to hallucinate the same advance, which is unlikely — so this keeps
        // multi-word phrases (e.g. "following your voice") responsive without
        // waiting for a streaming partial to repeat the same position.
        let bothProgressed = min(characterResult, wordResult) > 0
        // A single strategy matching forward is riskier, so it still needs
        // either a small step or confirmation from repeated results.
        let skippedAnnotation = candidate > rawCandidate
        let smallStep = candidate - current <= 15
        return bothProgressed || skippedAnnotation || confirmed || smallStep
    }
}
