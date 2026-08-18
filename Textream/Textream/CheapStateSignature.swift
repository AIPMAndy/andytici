//
//  CheapStateSignature.swift
//  Andy题词
//
//  Shared dedup helper for the 10Hz broadcast tickers (R121).
//

import Foundation

/// O(1) cheap-signature comparison for the broadcast state (BrowserState /
/// DirectorState) shared between `BrowserServer` and `DirectorServer`. Lets
/// each server skip the JSONEncoder walk when no user-visible field changed
/// since the last tick.
///
/// Previously the same 6 stored properties + 2 functions lived in both
/// servers (~50 lines of copy-paste). Centralising the struct makes the
/// "what counts as a state change" rule auditable in one place and keeps
/// future tweaks (e.g. adding `audioLevels.max`) to a single edit.
///
/// The struct is a plain value type — no `@Observable` or Sendable ceremony
/// needed. Both servers mutate `sig` only on the main thread (the
/// broadcast timers are scheduled on `.main`).
struct CheapStateSignature {
    private var charCount: Int = -1
    private var isDone: Bool = false
    private var isListening: Bool = false
    private var lastSpoken: String = ""
    private var audioCount: Int = -1
    private var audioLast: CGFloat = 0

    /// True when at least one cheap-tracked field differs from the cached
    /// signature. The expensive step (JSONEncoder) is gated behind this
    /// check — calling it on every idle tick is the whole point. (R40 + R121)
    mutating func changed(
        highlightedCharCount: Int, isDone: Bool, isListening: Bool,
        lastSpokenText: String, audioLevels: [CGFloat]
    ) -> Bool {
        if highlightedCharCount != charCount { return true }
        if isDone != self.isDone { return true }
        if isListening != self.isListening { return true }
        if lastSpokenText != lastSpoken { return true }
        if audioLevels.count != audioCount { return true }
        // Sample only the last sample — earlier samples change monotonically
        // during a burst but the trailing edge is enough to detect motion.
        if let tail = audioLevels.last, tail != audioLast { return true }
        return false
    }

    /// Snapshot the cheap-tracked fields after a successful encode so the
    /// next tick's `changed` compares against the values we actually
    /// broadcast (not just the values we received from the recognizer).
    mutating func update(
        highlightedCharCount: Int, isDone: Bool, isListening: Bool,
        lastSpokenText: String, audioLevels: [CGFloat]
    ) {
        charCount = highlightedCharCount
        self.isDone = isDone
        self.isListening = isListening
        lastSpoken = lastSpokenText
        audioCount = audioLevels.count
        audioLast = audioLevels.last ?? 0
    }
}