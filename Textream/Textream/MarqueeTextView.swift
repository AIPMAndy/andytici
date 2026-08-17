//
//  MarqueeTextView.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import SwiftUI

// MARK: - CJK-aware word splitting

extension Unicode.Scalar {
    var isCJK: Bool {
        let v = value
        return (v >= 0x4E00 && v <= 0x9FFF)    // CJK Unified Ideographs
            || (v >= 0x3400 && v <= 0x4DBF)    // CJK Extension A
            || (v >= 0x20000 && v <= 0x2A6DF)  // CJK Extension B
            || (v >= 0xF900 && v <= 0xFAFF)    // CJK Compatibility Ideographs
            || (v >= 0x3040 && v <= 0x309F)    // Hiragana
            || (v >= 0x30A0 && v <= 0x30FF)    // Katakana
            || (v >= 0xAC00 && v <= 0xD7AF)    // Hangul Syllables
    }
}

/// Splits text into display-ready words. CJK characters (Chinese, Japanese, Korean)
/// are split into individual characters so the flow layout can wrap them properly.
func splitTextIntoWords(_ text: String) -> [String] {
    // Single unicodeScalars walk detects both CJK presence and newline presence,
    // so the fast path can skip the unconditional `replacingOccurrences` copy
    // when the script has no `\n` (the common case for both Chinese ASR scripts
    // and Latin dictation). The slow path also collapses replace + split + map
    // + per-token CJK re-check + per-char CJK split into one Character walk,
    // avoiding the intermediate [String] array and N redundant String inits.
    // (R30)
    var hasCJK = false
    var hasNewline = false
    for scalar in text.unicodeScalars {
        if !hasCJK, scalar.isCJK { hasCJK = true }
        if !hasNewline, scalar.value == 0x0A { hasNewline = true }
        if hasCJK && hasNewline { break }
    }

    if !hasCJK {
        // No CJK: just split on whitespace. Skip the whole-text replace copy
        // when there are no newlines to swap.
        let source = hasNewline ? text.replacingOccurrences(of: "\n", with: " ") : text
        return source
            .split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    // CJK present: single-pass split. Whitespace and CJK chars are both word
    // boundaries; consecutive non-CJK chars accumulate into the same word.
    // Equivalent to the previous 3-pass implementation (replace + split +
    // per-token CJK split) for every input the previous code accepted.
    var result: [String] = []
    result.reserveCapacity(text.unicodeScalars.count)
    var buffer = ""
    buffer.reserveCapacity(16)
    for ch in text {
        if ch.isWhitespace || ch == "\n" {
            if !buffer.isEmpty {
                result.append(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            continue
        }
        let isCJKChar = ch.unicodeScalars.first.map { $0.isCJK } ?? false
        if isCJKChar {
            if !buffer.isEmpty {
                result.append(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            result.append(String(ch))
        } else {
            buffer.append(ch)
        }
    }
    if !buffer.isEmpty {
        result.append(buffer)
    }
    return result
}

// MARK: - Word index table (shared O(log N) / O(1) lookup)
//
// Replaces the duplicated O(N) charOffsetForWordProgress / wordProgressForCharOffset
// helpers that lived in NotchOverlayView, FloatingOverlayView, and ExternalDisplayView.
// Build once per page-change; queries are O(1) (progress → offset) or O(log N) (offset → progress).

struct WordIndexTable {
    let wordLengths: [Int]
    let cumulativeEnds: [Int]
    let totalCharCount: Int

    init(words: [String]) {
        var lens: [Int] = []
        lens.reserveCapacity(words.count)
        var ends: [Int] = []
        ends.reserveCapacity(words.count)
        var offset = 0
        for w in words {
            lens.append(w.count)
            offset += w.count
            ends.append(offset)
            offset += 1 // space separator
        }
        self.wordLengths = lens
        self.cumulativeEnds = ends
        self.totalCharCount = max(0, offset - 1)
    }

    func charOffset(forProgress progress: Double) -> Int {
        guard !wordLengths.isEmpty else { return 0 }
        let whole = max(0, min(Int(progress), wordLengths.count - 1))
        let frac = progress - Double(whole)
        let base = whole > 0 ? cumulativeEnds[whole - 1] : 0
        let added = Int(Double(wordLengths[whole]) * frac)
        return min(base + added, totalCharCount)
    }

    func wordProgress(forCharOffset charOffset: Int) -> Double {
        guard !cumulativeEnds.isEmpty else { return 0 }
        var lo = 0
        var hi = cumulativeEnds.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if cumulativeEnds[mid] < charOffset {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let idx = min(lo, wordLengths.count - 1)
        let wordStart = idx > 0 ? cumulativeEnds[idx - 1] : 0
        let into = max(0, charOffset - wordStart)
        let denom = max(1, wordLengths[idx])
        return Double(idx) + Double(into) / Double(denom)
    }
}

// MARK: - Data

struct WordItem: Identifiable {
    let id: Int
    let word: String
    /// `word` with a trailing space — pre-computed once at build time so the
    /// per-frame render path doesn't have to allocate a new String for
    /// `item.word + " "` on every visible word every render. Was previously
    /// allocating N Strings/frame at 30 Hz.
    let wordWithSpace: String
    let charOffset: Int // char offset of this word in the full text (counting spaces)
    let isAnnotation: Bool // true for [bracket] words and emoji-only words
    /// Cached count of letters+digits in `word`. Used to decide when the
    /// word is "fully lit". Previously recomputed in `wordView` for every
    /// visible word every render frame via Character.isLetter/isNumber,
    /// which is slow (Unicode lookup) and wasted work for words that
    /// haven't changed.
    let letterCount: Int
    /// Cached `word.count` (grapheme length). Used by the hot path
    /// `nextWordIndex` which runs at ASR cadence for every visible word —
    /// calling String.count on every access is an O(N) Unicode walk. Once
    /// populated here at build time, lookups are O(1).
    let wordCount: Int
}

// MARK: - Preference key to report word Y positions

struct WordYPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Pre-computed derived Font / Color values used by `WordFlowLayout.wordView`.
/// Previously these were allocated inside `wordView` itself, once per visible
/// word per body call — at 30 fps × ~100 visible words × 5+ allocations per
/// word that's ~15k Color/Font allocations/sec for values that only change when
/// the user edits settings. Hoisting to a single struct built once per
/// `body` collapses those to one allocation per frame.
private struct WordStyles {
    let baseFont: Font
    let boldFont: Font
    let heavyFont: Font
    let italicFont: Font
    /// `highlightColor.opacity(0.6)` — used for current-but-not-yet-letters-lit word.
    let dimHighlight: Color
    /// `highlightColor.opacity(0.3)` — used for fully-lit words.
    let readHighlight: Color
    /// `cueColor.opacity(cueReadOpacity)` — annotation that has been read.
    let annotationRead: Color
    /// `cueColor.opacity(cueUnreadOpacity)` — annotation not yet read.
    let annotationUnread: Color

    static func make(
        font: NSFont,
        highlightColor: Color,
        cueColor: Color,
        cueReadOpacity: Double,
        cueUnreadOpacity: Double
    ) -> WordStyles {
        let f = Font(font)
        return WordStyles(
            baseFont: f,
            boldFont: f.weight(.bold),
            heavyFont: f.weight(.heavy),
            italicFont: f.italic(),
            dimHighlight: highlightColor.opacity(0.6),
            readHighlight: highlightColor.opacity(0.3),
            annotationRead: cueColor.opacity(cueReadOpacity),
            annotationUnread: cueColor.opacity(cueUnreadOpacity)
        )
    }
}

// MARK: - Teleprompter

struct SpeechScrollView: View {
    let words: [String]
    let highlightedCharCount: Int
    var font: NSFont = .systemFont(ofSize: 18, weight: .semibold)
    var highlightColor: Color = .white
    var cueColor: Color = .white
    var cueUnreadOpacity: Double = 0.2
    var cueReadOpacity: Double = 0.5
    var onWordTap: ((Int) -> Void)? = nil
    /// Called when user starts/stops manual scrolling in smooth mode.
    /// Bool: true = scrolling started (pause timer), false = scrolling ended (resume timer).
    /// Double: new word progress to resume from (only meaningful when false).
    var onManualScroll: ((Bool, Double) -> Void)? = nil
    var smoothScroll: Bool = false
    /// Continuous word progress (e.g. 3.7 = 70% through 4th word). Drives scroll in smooth mode.
    var smoothWordProgress: Double = 0

    var isListening: Bool = true
    @State private var scrollOffset: CGFloat = 0
    @State private var manualOffset: CGFloat = 0
    // Dense flat array indexed by word.id. WordItem.id is assigned as 0,1,2…
    // in buildItems(), so the array index is exactly the word id — no hashing,
    // no Dictionary.Values lazy view, no scattered allocations. `nil` means
    // "this slot hasn't been laid out yet" (the slot will be populated once
    // SwiftUI flushes that line's GeometryReader preference). This replaces
    // the previous `[Int: CGFloat]` dictionary: per-element lookup drops from
    // ~30 ns (hash + bucket walk) to ~3 ns (bounds check + load), and the
    // linear scan in wordProgressAtCurrentOffset runs over contiguous memory
    // instead of hash-table entries. (R20)
    @State private var wordYPositions: [CGFloat?] = []
    @State private var containerHeight: CGFloat = 0
    @State private var isUserScrolling: Bool = false
    // R48: derived from highlightedCharCount but updated only when ASR
    // actually crosses a word boundary. Drives WordFlowLayout's per-word
    // visual state (isNextWord / isFullyLit). Same-word ASR ticks no
    // longer trigger WordFlowLayout.body re-runs.
    @State private var nextIdx: Int = 0

    var body: some View {
        GeometryReader { geo in
            WordFlowLayout(
                words: words,
                // R48: pass `nextIdx` instead of `highlightedCharCount`. Body
                // now re-runs only when ASR crosses a word boundary — most
                // ASR ticks don't.
                nextIdx: nextIdx,
                font: font,
                highlightColor: highlightColor,
                cueColor: cueColor,
                cueUnreadOpacity: cueUnreadOpacity,
                cueReadOpacity: cueReadOpacity,
                highlightWords: !smoothScroll,
                containerWidth: geo.size.width,
                onWordTap: { charOffset in
                    manualOffset = 0
                    onWordTap?(charOffset)
                    // Force recenter on tapped word
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        recalcCenter(containerHeight: containerHeight)
                    }
                },
                scrollOffset: scrollOffset + manualOffset,
                viewportHeight: geo.size.height
            )
            .onPreferenceChange(WordYPreferenceKey.self) { positions in
                let wasEmpty = wordYPositions.isEmpty
                // R41 incremental update: instead of rebuilding the entire
                // [CGFloat?] of length `words.count` on every layout flush
                // (~60 Hz during scroll, ~16 KB of optional writes for a
                // 1000-word script), reuse the existing buffer and only
                // write the slots that arrived. Stale entries for off-screen
                // words are harmless: `currentMaxY()` only walks slots, and
                // an overestimate of maxY only widens the scroll bound, never
                // corrupting the centered-word lookup. On `words` array
                // change the `onChange(of: words)` handler clears the buffer
                // back to [] — see line ~332.
                var arr = wordYPositions
                let target = words.count
                if arr.count < target {
                    arr.append(contentsOf: repeatElement(nil, count: target - arr.count))
                } else if arr.count > target {
                    arr.removeLast(arr.count - target)
                }
                for (id, y) in positions where id >= 0 && id < target {
                    arr[id] = y
                }
                wordYPositions = arr
                // After a page switch, wordYPositions was cleared — recenter once new positions arrive
                if wasEmpty && !arr.isEmpty {
                    recalcCenter(containerHeight: containerHeight)
                }
            }
            .offset(y: scrollOffset + manualOffset)
            // Animate manual offset only — ASR-driven scrollOffset must be
            // discrete so 200ms partials don't pile up overlapping tweens.
            .animation(.easeOut(duration: 0.15), value: manualOffset)
            .onChange(of: geo.size.height) { _, newHeight in
                containerHeight = newHeight
                if highlightedCharCount == 0 && smoothWordProgress == 0 {
                    // Initial state: center first line on screen
                    let lineHeight = font.pointSize * 1.4
                    scrollOffset = newHeight * 0.5 - lineHeight * 0.5
                } else if isListening {
                    recalcCenter(containerHeight: newHeight)
                }
            }
            .onChange(of: highlightedCharCount) { _, newCount in
                // R48: derive nextIdx from the new highlightedCharCount and
                // only update @State when it actually changed. Same-word
                // ASR ticks (the majority — 5-20 Hz for short words, ~1 Hz
                // for long ones) leave nextIdx untouched, so SwiftUI does
                // not re-run WordFlowLayout.body. Items are pulled from the
                // shared layout cache to avoid duplicating the buildItems()
                // walk; the static `_memoizedNextIdx` inside WordFlowLayout
                // still owns the monotonic scan-forward shortcut.
                let items = WordFlowLayout._peekCachedItems()
                if !items.isEmpty {
                    let newNext = WordFlowLayout.nextWordIndex(items: items, target: newCount)
                    if newNext != nextIdx { nextIdx = newNext }
                }
                // While the user is manually scrolling, do NOT recenter — let
                // them browse the script freely without ASR yanking them back.
                if isUserScrolling { return }
                if isListening && !smoothScroll {
                    manualOffset = 0
                    recalcCenter(containerHeight: containerHeight)
                }
            }
            .onChange(of: smoothWordProgress) { _, _ in
                if isUserScrolling { return }
                if isListening && smoothScroll {
                    manualOffset = 0
                    recalcCenter(containerHeight: containerHeight)
                }
            }
            .onChange(of: isListening) { _, listening in
                if listening {
                    manualOffset = 0
                    recalcCenter(containerHeight: containerHeight)
                }
            }
            .onChange(of: words) { _, _ in
                // First line at vertical center: height/2 + lineHeight/2
                let lineHeight = font.pointSize * 1.4
                scrollOffset = containerHeight * 0.5 - lineHeight * 0.5
                manualOffset = 0
                wordYPositions = []
                // R48: words array changed — reset nextIdx so the next render
                // recomputes against the fresh items cache. buildItems()
                // already invalidated WordFlowLayout._memoizedNextIdx.
                nextIdx = 0
            }
            .onAppear {
                containerHeight = geo.size.height
                // First line at vertical center: height/2 + lineHeight/2
                let lineHeight = font.pointSize * 1.4
                scrollOffset = containerHeight * 0.5 - lineHeight * 0.5
            }
            .overlay(
                ScrollWheelView(
                    onScroll: { delta in
                        // Accept scroll input in every mode. Previously this was
                        // gated by `smoothScroll ? isListening : !isListening`,
                        // which made scrolling impossible in word-tracking mode
                        // while ASR was running — users couldn't nudge the
                        // overlay when ASR jumped to the wrong position.

                        // On the first scroll event, mark the user as driving
                        // so ASR-side recentering yields until they release.
                        if !isUserScrolling {
                            isUserScrolling = true
                            onManualScroll?(true, 0)
                        }

                        let maxY = currentMaxY()
                        let containerHeight = geo.size.height
                        let maxUp = containerHeight * 0.5
                        let maxDown = max(0, maxY - containerHeight * 0.5)

                        let newOffset = manualOffset + delta
                        let upperBound = maxUp
                        let lowerBound = -maxDown

                        if newOffset > upperBound {
                            let over = newOffset - upperBound
                            manualOffset = upperBound + over * 0.2
                        } else if newOffset < lowerBound {
                            let over = lowerBound - newOffset
                            manualOffset = lowerBound - over * 0.2
                        } else {
                            manualOffset = newOffset
                        }
                    },
                    onScrollEnd: {
                        if isUserScrolling {
                            // Find the word at the new visual center
                            let newProgress = wordProgressAtCurrentOffset()
                            withAnimation(.easeOut(duration: 0.15)) {
                                manualOffset = 0
                            }
                            isUserScrolling = false
                            // Notify parent so it can anchor ASR / timer at
                            // the position the user picked.
                            onManualScroll?(false, newProgress)
                        } else {
                            let maxY = currentMaxY()
                            let containerHeight = geo.size.height
                            let upperBound = containerHeight * 0.5
                            let lowerBound = -max(0, maxY - containerHeight * 0.5)

                            if manualOffset > upperBound || manualOffset < lowerBound {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    manualOffset = min(upperBound, max(lowerBound, manualOffset))
                                }
                            }
                        }
                    }
                )
            )
        }
        .clipped()
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: 0.05),
                    .init(color: .white, location: 0.95),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func recalcCenter(containerHeight: CGFloat) {
        let center = containerHeight * 0.5

        if smoothScroll {
            // Classic/silence-paused: anchor active word near the bottom, scrolling up
            let bottomAnchor = containerHeight - 20
            let wordIdx = Int(smoothWordProgress)
            let fraction = smoothWordProgress - Double(wordIdx)
            let clampedIdx = max(0, min(wordIdx, words.count - 1))
            guard let wordY = wordYPositions[clampedIdx] else { return }
            // Defensive bounds-checked read so clampedIdx == words.count
            // (when smoothWordProgress points at the very last word)
            // keeps the original "fall back to wordY" semantics instead of
            // crashing on an out-of-range index. (R20)
            let nextY: CGFloat
            if clampedIdx + 1 < wordYPositions.count, let next = wordYPositions[clampedIdx + 1] {
                nextY = next
            } else {
                nextY = wordY
            }
            let interpolatedY = wordY + (nextY - wordY) * CGFloat(fraction)
            scrollOffset = bottomAnchor - interpolatedY
        } else {
            // Word-tracking/voice-activated: active word at vertical center
            let wordIdx = activeWordIndex()
            if let wordY = wordYPositions[wordIdx] {
                let target = center - wordY
                // Only update if it actually changed to avoid redundant animations
                if abs(scrollOffset - target) > 1 {
                    scrollOffset = target
                }
            }
        }
    }

    /// Returns the largest populated Y value in `wordYPositions`, or 0 if the
    /// array is empty/all-nil. Replaces the previous
    /// `wordYPositions.values.max()` calls in the scroll handlers, which on a
    /// Dictionary allocated a lazy `Dictionary.Values` view and then iterated
    /// the hash buckets. This is a single linear scan over the dense array,
    /// no intermediate view, no hash table traversal. (R20)
    private func currentMaxY() -> CGFloat {
        var maxY: CGFloat = 0
        for v in wordYPositions {
            if let v, v > maxY { maxY = v }
        }
        return maxY
    }

    /// Find the word progress at the current visual position (scrollOffset + manualOffset)
    private func wordProgressAtCurrentOffset() -> Double {
        let center = containerHeight * 0.5
        // The Y position currently at the center of the view
        let targetY = center - (scrollOffset + manualOffset)

        // Single linear pass over the dense [CGFloat?] array (R20).
        // Previously this iterated a Dictionary<Int,CGFloat> which involved
        // hash-bucket traversal. Now it walks contiguous memory in id order
        // (id == array index). Nil entries — words that haven't been laid
        // out yet — are skipped, matching the previous "key absent" semantics.
        let count = wordYPositions.count
        guard count > 0 else { return smoothWordProgress }

        var prevId: Int = 0
        var prevY: CGFloat = 0
        var hasPrev = false
        var firstY: CGFloat = 0
        var sawFirst = false

        for (id, yOpt) in wordYPositions.enumerated() {
            guard let y = yOpt else { continue }
            if !sawFirst {
                firstY = y
                sawFirst = true
            }
            if hasPrev {
                if targetY >= prevY && targetY <= y {
                    let span = y - prevY
                    let frac = span > 0 ? Double(targetY - prevY) / Double(span) : 0
                    return Double(prevId) + frac
                }
            }
            prevId = id
            prevY = y
            hasPrev = true
        }

        // Past the last word → return count
        if hasPrev && targetY >= prevY {
            return Double(words.count)
        }
        // Above the first word → 0
        if sawFirst && targetY < firstY {
            return 0
        }
        return smoothWordProgress
    }

    private func activeWordIndex() -> Int {
        // Scan from the last memoized index when highlightedCharCount has
        // moved forward (the usual case for ASR). Restart from 0 only if
        // the count went backwards or the memoized position is invalid.
        let target = highlightedCharCount
        let n = words.count
        if n == 0 { return 0 }
        var i = max(0, Self._memoizedActiveIdx)
        if i >= n { i = 0; Self._memoizedActiveIdx = 0 }
        // Quick check: see if the previously cached word still covers target
        if i > 0 {
            let item = cachedItemsForActive[i]
            if item.charOffset <= target && target <= item.charOffset + max(1, item.letterCount) {
                return i
            }
        }
        while i < n {
            let item = cachedItemsForActive[i]
            if target <= item.charOffset + max(1, item.letterCount) {
                Self._memoizedActiveIdx = i
                return i
            }
            i += 1
        }
        Self._memoizedActiveIdx = max(0, n - 1)
        return Self._memoizedActiveIdx
    }

    /// Returns (wordIndex, fractionThroughWord) for smooth interpolation
    private func activeWordFraction() -> (Int, Double) {
        let target = highlightedCharCount
        let n = words.count
        if n == 0 { return (0, 1.0) }
        var i = max(0, Self._memoizedActiveIdx)
        if i >= n { i = 0 }
        while i < n {
            let item = cachedItemsForActive[i]
            let wordLen = max(1, item.letterCount)
            if target <= item.charOffset + wordLen {
                let into = target - item.charOffset
                Self._memoizedActiveIdx = i
                return (i, Double(into) / Double(wordLen))
            }
            i += 1
        }
        Self._memoizedActiveIdx = max(0, n - 1)
        return (Self._memoizedActiveIdx, 1.0)
    }

    // Memoized last-hit index for activeWordIndex/activeWordFraction.
    // Highlighted char count is monotonic during ASR, so once we know the
    // active word we only need to scan forward from there on subsequent
    // calls. Falls back to 0 if invalidated (see invalidateActiveMemo).
    private static var _memoizedActiveIdx: Int = 0

    // Snapshot of [WordItem] used by activeWordIndex / activeWordFraction.
    // We need charOffset + letterCount (cached on the item) — not just the
    // raw `words` strings — so the scanner doesn't have to call .count on
    // each String every iteration (which is an O(N) grapheme walk).
    // Refreshed from _cachedItems when SpeechScrollView invalidates layout.
    private static var _cachedItemsForActive: [WordItem] = []
    private static var _cachedItemsForActiveCount: Int = -1

    private var cachedItemsForActive: [WordItem] {
        // Refresh only when the cached layout changes (cheap identity check).
        let n = WordFlowLayout._cachedItemsCount
        if n != Self._cachedItemsForActiveCount || Self._cachedItemsForActive.isEmpty {
            Self._cachedItemsForActive = WordFlowLayout._peekCachedItems()
            Self._cachedItemsForActiveCount = n
        }
        return Self._cachedItemsForActive
    }
}

// MARK: - Word Flow Layout

struct WordFlowLayout: View {
    let words: [String]
    // R48: replace the per-tick `highlightedCharCount` parameter with
    // `nextIdx` (the only signal that actually affects per-word visual state).
    // ASR ticks that advance within a word leave nextIdx unchanged, so
    // SwiftUI does not re-run this view's body. The previous version ran
    // body at ASR cadence (5-20 Hz) just to re-derive nextIdx — see the
    // matching change in SpeechScrollView.onChange(of: highlightedCharCount).
    let nextIdx: Int
    let font: NSFont
    var highlightColor: Color = .white
    var cueColor: Color = .white
    var cueUnreadOpacity: Double = 0.2
    var cueReadOpacity: Double = 0.5
    var highlightWords: Bool = true
    let containerWidth: CGFloat
    var onWordTap: ((Int) -> Void)? = nil
    var scrollOffset: CGFloat = 0
    var viewportHeight: CGFloat = 0

    // Compute line spacing based on font metrics — fonts with large built-in
    // line height (e.g. OpenDyslexic) need less extra spacing. Cached against
    // pointSize so we don't touch NSFont metric getters on every body call.
    private static var _cachedLineSpacing: CGFloat = 0

    // Simple layout cache to avoid re-measuring words on every highlight update
    private static var _cachedWordsCount: Int = 0
    private static var _cachedFirst: String = ""
    private static var _cachedLast: String = ""
    private static var _cachedPointSize: CGFloat = 0
    private static var _cachedWidth: Int = 0
    private static var _cachedItems: [WordItem] = []
    private static var _cachedLines: [[WordItem]] = []
    private static var _cachedRTL: Bool = false
    // Standalone mirror of _cachedItems.count, exposed to SpeechScrollView
    // (where activeWordIndex lives) so it can detect cache invalidation
    // without copying the whole [WordItem] array on every call.
    static var _cachedItemsCount: Int = 0
    // Lightweight handle for SpeechScrollView to read the cached items
    // without re-running buildItems(). Returns whatever's currently cached
    // (possibly stale on first invocation — caller compares count).
    static func _peekCachedItems() -> [WordItem] {
        return _cachedItems
    }
    // Memoize the last-hit index for nextWordIndex — ASR progress is
    // nearly monotonic, so the active word is almost always the same or
    // the next one, and we don't need to restart the scan from index 0
    // on every partial. Invalidated in buildItems() when items change.
    private static var _memoizedNextIdx: Int = -1

    private func cachedLayout() -> ([WordItem], [[WordItem]], Bool, CGFloat) {
        let w = words
        let count = w.count
        let first = w.first ?? ""
        let last = w.last ?? ""
        let pointSize = font.pointSize
        let width = Int(containerWidth)
        if count == Self._cachedWordsCount
           && first == Self._cachedFirst
           && last == Self._cachedLast
           && pointSize == Self._cachedPointSize
           && width == Self._cachedWidth {
            // pointSize changed-or-not, lineSpacing is a pure function of pointSize,
            // so it's safe to read it whenever the rest of the cache is valid.
            let lineSpacing: CGFloat = {
                if pointSize == Self._cachedPointSize && Self._cachedLineSpacing != 0 {
                    return Self._cachedLineSpacing
                }
                let intrinsic = font.ascender - font.descender + font.leading
                let ratio = intrinsic / font.pointSize
                let s: CGFloat = ratio > 1.5 ? 2 : 8
                Self._cachedLineSpacing = s
                return s
            }()
            return (Self._cachedItems, Self._cachedLines, Self._cachedRTL, lineSpacing)
        }
        let (items, rtl) = buildItems()
        let lines = buildLines(items: items)
        // Compute lineSpacing now (font metrics), keyed off the new pointSize.
        let intrinsic = font.ascender - font.descender + font.leading
        let ratio = intrinsic / font.pointSize
        let lineSpacing: CGFloat = ratio > 1.5 ? 2 : 8
        Self._cachedWordsCount = count
        Self._cachedFirst = first
        Self._cachedLast = last
        Self._cachedPointSize = pointSize
        Self._cachedWidth = width
        Self._cachedItems = items
        Self._cachedItemsCount = items.count
        Self._cachedLines = lines
        Self._cachedRTL = rtl
        Self._cachedLineSpacing = lineSpacing
        return (items, lines, rtl, lineSpacing)
    }

    // Find the index of the next word to read (first non-fully-lit, non-annotation word).
    // charOffset is monotonically non-decreasing, so for monotonic ASR progress we can
    // resume scanning from the last hit instead of restarting at index 0.
    // R48: static + parameterized on `target`. Previously this lived as an instance
    // method that read `self.highlightedCharCount`, which forced WordFlowLayout.body
    // to re-evaluate every ASR tick (5-20 Hz). After R48 SpeechScrollView owns the
    // "next word" derivation and only updates its `nextIdx` @State when ASR actually
    // crosses a word boundary — body re-runs drop by ~90 % during steady ASR.
    static func nextWordIndex(items: [WordItem], target: Int) -> Int {
        let n = items.count
        if _memoizedNextIdx >= n { _memoizedNextIdx = -1 }
        var i = max(0, _memoizedNextIdx)
        while i < n {
            let item = items[i]
            if item.isAnnotation { i += 1; continue }
            let charsIntoWord = target - item.charOffset
            let litCount = max(0, min(item.wordCount, charsIntoWord))
            if litCount < item.letterCount {
                _memoizedNextIdx = i
                return item.id
            }
            i += 1
        }
        _memoizedNextIdx = -1
        return -1
    }

    // Per-line row in the rendered marquee. Hoists the GeometryReader that
    // reports word Y positions out of wordView (which used to do it for
    // every visible word) — all words in an HStack share the same baseline Y,
    // so one GeometryReader per visible line is sufficient.
    @ViewBuilder
    private func lineRow(
        lineIdx: Int,
        line: [WordItem],
        isVisible: Bool,
        isLeadingPlaceholder: Bool,
        startLine: Int,
        nextIdx: Int,
        rtl: Bool,
        styles: WordStyles
    ) -> some View {
        if isLeadingPlaceholder {
            Color.clear.frame(height: CGFloat(startLine) * (ceil(font.ascender - font.descender + font.leading) + lineSpacingCached))
        } else if isVisible {
            HStack(spacing: 0) {
                ForEach(line, id: \.id) { item in
                    wordView(for: item, isNextWord: item.id == nextIdx, styles: styles)
                        .id(item.id)
                }
            }
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            // Single GeometryReader per visible line (was: one per visible word,
            // i.e. ~5-10× more evaluations per frame). Each word on this line
            // gets the same Y reported under its own id so downstream
            // `wordYPositions[id]` reads (now backed by a dense [CGFloat?]
            // indexed by id — R20) get the right value.
            .background(GeometryReader { lineGeo in
                let y = lineGeo.frame(in: .named("flowLayout")).midY
                let count = line.count
                var pairs = [Int: CGFloat](minimumCapacity: count)
                var i = 0
                while i < count {
                    pairs[line[i].id] = y
                    i += 1
                }
                return Color.clear.preference(
                    key: WordYPreferenceKey.self,
                    value: pairs
                )
            })
        } else {
            Color.clear.frame(height: ceil(font.ascender - font.descender + font.leading) + lineSpacingCached)
        }
    }

    // Reading cached layout line spacing (avoids re-deriving in lineRow)
    private var lineSpacingCached: CGFloat {
        Self._cachedLineSpacing
    }

    var body: some View {
        let (items, lines, rtl, lineSpacing) = cachedLayout()
        // R48: nextIdx is now a prop — no need to recompute here. Body re-runs
        // only when nextIdx actually changes (≈ per-word advance, not per ASR tick).
        let totalLines = lines.count

        // Pre-compute derived Font/Color values once per frame (R18). wordView
        // used to recompute these per visible word; for ~100 visible words at
        // 30 fps that was ~15k Color/Font allocations/sec of constant values.
        let styles = WordStyles.make(
            font: font,
            highlightColor: highlightColor,
            cueColor: cueColor,
            cueReadOpacity: cueReadOpacity,
            cueUnreadOpacity: cueUnreadOpacity
        )

        // Estimate line height for visibility culling using actual font metrics
        let lineH = ceil(font.ascender - font.descender + font.leading) + lineSpacing

        // Determine visible range of lines
        let canCull = viewportHeight > 0 && totalLines > 0
        let buffer: CGFloat = 400
        let startLine = canCull ? max(0, min(totalLines, Int(floor((-scrollOffset - buffer) / lineH)))) : 0
        let endLine = canCull ? max(startLine, min(totalLines, Int(ceil((viewportHeight - scrollOffset + buffer) / lineH)))) : totalLines

        // For RTL scripts (Arabic, Hebrew, Persian, Urdu), flip the layout direction
        // so words within each line flow right-to-left instead of left-to-right.
        VStack(alignment: rtl ? .trailing : .leading, spacing: lineSpacing) {
            ForEach(lines.indices, id: \.self) { lineIdx in
                lineRow(
                    lineIdx: lineIdx,
                    line: lines[lineIdx],
                    isVisible: lineIdx >= startLine && lineIdx < endLine,
                    isLeadingPlaceholder: lineIdx == startLine && startLine > 0,
                    startLine: startLine,
                    nextIdx: nextIdx,
                    rtl: rtl,
                    styles: styles
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
        .coordinateSpace(name: "flowLayout")
    }

    // Per-word render. Previously returned AnyView (which forced SwiftUI to
    // box each visible word's view subtree into an existential, defeating the
    // diff optimizer's ability to match concrete types across frames).
    // Returns opaque `some View` instead: each branch returns a concrete
    // `_ModifiedContent<...>` shape that SwiftUI can compare structurally
    // across renders, skipping the AnyView alloc. Tagged-word branch is
    // inlined (no scriptedTagView indirection) for the same reason.
    @ViewBuilder
    private func wordView(for item: WordItem, isNextWord: Bool, styles: WordStyles) -> some View {
        // Compute the per-word flags up front in a plain function (not a
        // @ViewBuilder body) — the ViewBuilder cannot accept assignments to
        // `let` as the first statements of its body.
        let (isFullyLit, isCurrentWord) = wordFlags(item: item, isNextWord: isNextWord)

        // Andy题词 ScriptTag emoji rendering — give each tag a distinct visual cue.
        // Inlined (was: a separate scriptedTagView() that returned AnyView)
        // so tagged words also stay opaque to the diff.
        if let tag = ScriptTag.tagForWord(item.word) {
            switch tag {
            case .emphasis:
                Text(item.wordWithSpace)
                    .font(styles.boldFont)
                    .foregroundStyle(Color.andyGold)
            case .highEnergy:
                Text(item.wordWithSpace)
                    .font(styles.boldFont)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .background(Color.yellow)
            case .pause:
                Text(item.wordWithSpace)
                    .font(styles.italicFont)
                    .foregroundStyle(.gray)
            case .exclaim:
                Text(item.wordWithSpace)
                    .font(styles.boldFont)
                    .foregroundStyle(Color.red)
            case .hint:
                Text(item.wordWithSpace)
                    .font(.system(size: max(font.pointSize - 4, 10)).italic())
                    .foregroundStyle(Color.gray)
            case .climax:
                Text(item.wordWithSpace)
                    .font(styles.heavyFont)
                    .foregroundStyle(Color.orange)
            }
        }
        // When highlighting is off (classic/silence-paused), use uniform color
        else if !highlightWords {
            let uniformColor: Color = item.isAnnotation
                ? styles.annotationUnread
                : highlightColor

            Text(item.wordWithSpace)
                .font(item.isAnnotation ? styles.italicFont : styles.baseFont)
                .foregroundStyle(uniformColor)
                // Word Y is now reported once per visible line by the
                // HStack-level GeometryReader in `body`. This word-level
                // background just keeps the modifier chain shape (and the
                // hit area) stable.
                .background(Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    onWordTap?(item.charOffset)
                }
        }
        // Annotations: italic, dimmed with cue color
        else if item.isAnnotation {
            let annotationColor: Color = isFullyLit
                ? styles.annotationRead
                : styles.annotationUnread

            Text(item.wordWithSpace)
                .font(styles.italicFont)
                .foregroundStyle(annotationColor)
                .background(Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    onWordTap?(item.charOffset)
                }
        }
        // Main highlight branch
        else {
            // Dim color: highlight color variant for current word, full for unread
            let dimColor: Color = isCurrentWord
                ? styles.dimHighlight
                : highlightColor

            // Base color for the whole word
            let wordColor: Color = isFullyLit ? styles.readHighlight : dimColor

            // Andy题词 当前词焦点加强：略大字号 + 粗体 + 强色下划线
            let currentWordFont: Font = isCurrentWord
                ? styles.boldFont
                : styles.baseFont
            let currentWordColor: Color = isCurrentWord
                ? highlightColor
                : wordColor

            Text(item.wordWithSpace)
                .font(currentWordFont)
                .foregroundStyle(currentWordColor)
                .underline(isCurrentWord, color: highlightColor)
                .background(Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    onWordTap?(item.charOffset)
                }
        }
    }

    // Plain (non-ViewBuilder) helper that derives the per-word state flags
    // once. Pulled out of wordView so the ViewBuilder body opens directly
    // with the first view-producing branch.
    private func wordFlags(item: WordItem, isNextWord: Bool) -> (Bool, Bool) {
        if isNextWord {
            return (false, true)
        }
        // R48: now derived from `nextIdx` comparison rather than re-computing
        // (highlightedCharCount - item.charOffset) >= item.letterCount every
        // frame. Both formulations are equivalent: any word whose id is
        // strictly less than nextIdx's id has been fully passed by ASR.
        // nextIdx == -1 means "no remaining word" — every word is fully lit.
        let isFullyLit = nextIdx < 0 || item.id < nextIdx
        return (isFullyLit, false)
    }

    private func buildItems() -> ([WordItem], Bool) {
        // Item array changed — invalidate the nextWordIndex memoization.
        Self._memoizedNextIdx = -1
        var items: [WordItem] = []
        var offset = 0
        let annotationFlags = SpeechTextAlignment.annotationFlags(for: words)
        var detectedRTL = false
        for (i, word) in words.enumerated() {
            let isAnnotation = annotationFlags[i] || Self.isAnnotationWord(word)
            // Hoist RTL detection here (once per layout rebuild) so the body
            // render path doesn't redo Unicode bidi analysis per ASR partial.
            if !isAnnotation && !detectedRTL {
                switch textBaseDirection(in: word) {
                case .rightToLeft:
                    detectedRTL = true
                case .leftToRight:
                    detectedRTL = false
                    break
                case .natural:
                    break
                }
            }
            // Count letters+digits once at build time. Avoids repeated
            // Character.isLetter/isNumber calls in the per-frame render path.
            let lc = word.reduce(0) { acc, ch in
                acc + ((ch.isLetter || ch.isNumber) ? 1 : 0)
            }
            let letterCount = max(1, lc)
            // Cache grapheme length for both the WordItem (used by hot path
            // `nextWordIndex`) and the offset increment below. One walk, two
            // readers; the hot path was previously doing its own per-word walk.
            let wc = word.count
            items.append(WordItem(
                id: i,
                word: word,
                wordWithSpace: word + " ",
                charOffset: offset,
                isAnnotation: isAnnotation,
                letterCount: letterCount,
                wordCount: wc
            ))
            offset += wc + 1 // +1 for space
        }
        return (items, detectedRTL)
    }

    static func isAnnotationWord(_ word: String) -> Bool {
        // Words inside square brackets like [smile]
        if word.hasPrefix("[") && word.hasSuffix("]") { return true }
        // Andy题词 ScriptTag emoji (🎯/⚡/⏸/❗/💡/🔥) — keep visually distinct from text
        if ScriptTag.tagForWord(word) != nil { return true }
        // Emoji-only words (no letters or numbers)
        let stripped = word.filter { $0.isLetter || $0.isNumber }
        if stripped.isEmpty { return true }
        return false
    }

    private func buildLines(items: [WordItem]) -> [[WordItem]] {
        var lines: [[WordItem]] = [[]]
        var currentLineWidth: CGFloat = 0
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width

        for item in items {
            let wordWidth = (item.word as NSString).size(withAttributes: [.font: font]).width + spaceWidth
            if currentLineWidth + wordWidth > containerWidth && !lines[lines.count - 1].isEmpty {
                lines.append([])
                currentLineWidth = 0
            }
            lines[lines.count - 1].append(item)
            currentLineWidth += wordWidth
        }
        return lines
    }
}

// MARK: - Elapsed Time

struct ElapsedTimeView: View {
    let fontSize: CGFloat

    @State private var startDate = Date()

    var body: some View {
        TimelineView(.periodic(from: startDate, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            let minutes = Int(elapsed) / 60
            let seconds = Int(elapsed) % 60
            Text(String(format: "%02d:%02d", minutes, seconds))
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

// MARK: - Audio Waveform + Progress

struct AudioWaveformProgressView: View {
    let levels: [CGFloat]
    let progress: Double // 0.0 to 1.0

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            let n = levels.count
            let denom = max(1, n - 1)
            ForEach(0..<n, id: \.self) { index in
                let level = levels[index]
                let barProgress = Double(index) / Double(denom)
                let isLit = barProgress <= progress

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isLit
                          ? Color.yellow.opacity(0.9)
                          : Color.white.opacity(0.15)
                    )
                    .frame(width: 3, height: max(3, level * 28))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
    }
}

/// Isolates the 47 Hz `audioLevels` mutation from the heavy overlay body.
/// Without this, every audio buffer would re-evaluate the GeometryReader +
/// WordFlowLayout of the parent overlay. The parent only needs to observe
/// the slow 5 Hz ASR path (transcript, error, mode).
struct AudioWaveformProgressView_Observer: View {
    @Bindable var recognizer: SpeechRecognizer
    let progress: Double

    var body: some View {
        AudioWaveformProgressView(levels: recognizer.audioLevels, progress: progress)
    }
}

/// Isolates changes to `lastSpokenText` (which updates the tail caches) so
/// only this tiny Text re-renders — not the whole overlay body.
struct LastSpokenTailText: View {
    @Bindable var recognizer: SpeechRecognizer
    let tailSize: Int   // 3 or 5
    let fontSize: CGFloat

    var body: some View {
        let text: String = tailSize == 5 ? recognizer.lastSpokenTail5 : recognizer.lastSpokenTail3
        Text(text)
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Keep the old one for backward compat
struct AudioWaveformView: View {
    let levels: [CGFloat]
    var color: Color = .white

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            let n = levels.count
            ForEach(0..<n, id: \.self) { index in
                let level = levels[index]
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(0.4 + Double(level) * 0.6))
                    .frame(width: 3, height: max(3, level * 28 + 3))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
    }
}

// MARK: - Scroll Wheel Handler

struct ScrollWheelView: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void
    var onScrollEnd: (() -> Void)?

    init(onScroll: @escaping (CGFloat) -> Void, onScrollEnd: (() -> Void)? = nil) {
        self.onScroll = onScroll
        self.onScrollEnd = onScrollEnd
    }

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        view.onScrollEnd = onScrollEnd
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onScrollEnd = onScrollEnd
    }
}

class ScrollWheelNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    var onScrollEnd: (() -> Void)?
    private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window else { return event }
                // Only handle if event is in our window
                if event.window == window {
                    let delta = event.scrollingDeltaY
                    let scaled = event.hasPreciseScrollingDeltas ? delta : delta * 10
                    self.onScroll?(scaled)

                    if event.phase == .ended || event.momentumPhase == .ended {
                        self.onScrollEnd?()
                    }
                }
                return event
            }
        }
    }

    override func removeFromSuperview() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        super.removeFromSuperview()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}
