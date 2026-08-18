//
//  SpeechRecognizer.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import Foundation
import Speech
import AVFoundation
import CoreAudio
import os

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    static func allInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            // Check if device has input streams
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }

            // Get UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let uidStatus = withUnsafeMutablePointer(to: &uid) { uidPointer in
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, uidPointer)
            }
            guard uidStatus == noErr else { continue }

            // Get name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let nameStatus = withUnsafeMutablePointer(to: &name) { namePointer in
                AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, namePointer)
            }
            guard nameStatus == noErr else { continue }

            result.append(AudioInputDevice(id: deviceID, uid: uid as String, name: name as String))
        }
        return result
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allInputDevices().first(where: { $0.uid == uid })?.id
    }
}

@Observable
class SpeechRecognizer {
    var recognizedCharCount: Int = 0
    var isListening: Bool = false
    var isStarting: Bool = false
    var error: String?
    var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    var lastSpokenText: String = "" {
        didSet {
            // R96: STT recognizers routinely re-emit the same partial verbatim
            // between acoustic refinements. matchCharacters (R62) already
            // guards on `partial != self.lastSpokenText`, but the didSet
            // pre-compute path was not — identical re-emits re-walked utf16,
            // re-split, re-joined two String tails, and re-fired @Observable
            // notifications on _lastSpokenTail3 / _lastSpokenTail5 (which
            // propagate to LastSpokenTailText → SwiftUI Text diff). Skip when
            // value is unchanged so cached tails stay correct from the prior
            // different-value assignment.
            guard oldValue != lastSpokenText else { return }
            // R56: also cache tail3/tail5 here so ASR partial handlers don't
            // each re-split. didSet runs once per assignment (both call sites
            // now only do `self.lastSpokenText = spoken` + matchCharacters).
            lastSpokenTextUtf16Count = lastSpokenText.utf16.count
            let words = lastSpokenText.split(separator: " ")
            _lastSpokenTail3 = words.suffix(3).joined(separator: " ")
            _lastSpokenTail5 = words.suffix(5).joined(separator: " ")
        }
    }
    /// Cached UTF-16 length of lastSpokenText. Avoids O(N) walk on every ASR
    /// partial in matchCharacters' prefix-trim calculation.
    @ObservationIgnored private var lastSpokenTextUtf16Count: Int = 0
    var lastSpokenTail3: String { _lastSpokenTail3 }
    @ObservationIgnored private var _lastSpokenTail3: String = ""
    var lastSpokenTail5: String { _lastSpokenTail5 }
    @ObservationIgnored private var _lastSpokenTail5: String = ""
    var shouldDismiss: Bool = false
    var shouldAdvancePage: Bool = false

    /// True when recent audio levels indicate the user is actively speaking
    var isSpeaking: Bool {
        voiceActivityDetector.isActive(at: ProcessInfo.processInfo.systemUptime)
    }

    @ObservationIgnored private var speechRecognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var audioEngine = AVAudioEngine()
    @ObservationIgnored private var sourceText: String = ""
    /// Cached `sourceText.count` (Character count). Populated whenever
    /// `sourceText` is assigned (R19). `String.count` is an O(N) Unicode
    /// grapheme walk; this cache lets per-ASR-partial sites (`jumpTo`,
    /// `matchSpokenText`) use an O(1) lookup. Grapheme count is the
    /// semantically correct bound here because `WordItem.charOffset` is
    /// built in `MarqueeTextView.buildItems` via `offset += word.count + 1`,
    /// which is also grapheme-based.
    @ObservationIgnored private var sourceTextCharCount: Int = 0
    @ObservationIgnored private var annotationRanges: [Range<Int>] = []
    /// Monotonic cursor into `annotationRanges` used by advancePastAnnotations.
    /// Reset to 0 whenever annotationRanges is rebuilt. (R26)
    @ObservationIgnored private var annotationCursor: Int = 0
    @ObservationIgnored private var voiceActivityDetector = VoiceActivityDetector()
    @ObservationIgnored private var matchStartOffset: Int = 0  // char offset to start matching from
    /// Cached lowercase [Character] view of sourceText, kept in sync with edits.
    /// charLevelMatch reuses this instead of rebuilding on every ASR partial.
    @ObservationIgnored private var cachedLowercasedSource: [Character] = []
    /// Position up to which cachedLowercasedSource has been consumed by the
    /// last charLevelMatch call. On the next call we only scan new characters.
    @ObservationIgnored private var charMatchCursor: Int = 0
    /// Cached word-level [String] view of sourceText, kept in sync with edits.
    @ObservationIgnored private var cachedSourceWords: [String] = []
    /// Pre-lowercased, letters/digits-only version of each cachedSourceWords
    /// entry. Avoids per-partial Character.isLetter/isNumber work in the
    /// word-level matcher's lookahead loops.
    @ObservationIgnored private var cachedSourceWordAlnum: [String] = []
    /// Character counts of each cachedSourceWords entry (utf16 length — for
    /// the BMP-heavy scripts STT returns this matches Character count exactly).
    /// Pre-computed so the word-level matcher and isFuzzyMatch can skip the
    /// O(N) grapheme walk that String.count performs on every access.
    @ObservationIgnored private var cachedSourceWordCharCount: [Int] = []
    /// utf16 count of each cachedSourceWordAlnum entry — used by isFuzzyMatch
    /// to short-circuit equal-length comparisons without re-walking the String.
    @ObservationIgnored private var cachedSourceWordAlnumUtf16Count: [Int] = []
    /// utf16 code units for each cachedSourceWordAlnum entry. Pre-materialized
    /// so the inner editDistance / isFuzzyMatch loop doesn't allocate a fresh
    /// `[UInt16]` for the source side on every mismatch (R36 was the UInt16
    /// conversion itself; R54 moves the source-side materialization off the
    /// hot path by computing it once in rebuildMatchCache).
    @ObservationIgnored private var cachedSourceWordAlnumUtf16: [[UInt16]] = []
    /// Scratch DP row reused by editDistance across calls. Grow-only: the
    /// first editDistance allocates; subsequent calls reset the used prefix
    /// in place. Eliminates the per-call `Array(0...iCount)` allocation
    /// (~12 editDistance calls per ASR partial, each previously allocating).
    @ObservationIgnored private var editDistanceDPBuffer: [Int] = []
    /// Char-offset table aligned with cachedSourceWords (each entry is the
    /// starting char offset of that word in sourceText). Pre-computed once.
    @ObservationIgnored private var cachedWordOffsets: [Int] = []
    /// Per-word annotation flag (true = word is inside a `[...]` block or is
    /// punctuation-only and should be skipped by wordLevelMatch). Pre-computed
    /// in rebuildMatchCache so the inner loop can do an O(1) array lookup
    /// instead of running `(si..<sourceCount).contains(where:)` and
    /// `Self.isAnnotationWord` (which allocates a temporary String via
    /// `word.filter`) on every iteration. (R21)
    @ObservationIgnored private var cachedSourceWordIsAnnotation: [Bool] = []
    /// Per-char annotation flag (true = char is inside any `[...]` block).
    /// Pre-computed so charLevelMatch can do an O(1) array lookup instead of
    /// `src[si...].firstIndex(of: "]")` (O(N) scan + ArraySlice allocation)
    /// each time it encounters a `[`. (R21)
    @ObservationIgnored private var cachedCharIsInAnnotation: [Bool] = []
    @ObservationIgnored private var retryCount: Int = 0
    @ObservationIgnored private let maxRetries: Int = 10
    @ObservationIgnored private var configurationChangeObserver: Any?
    @ObservationIgnored private var pendingRestart: DispatchWorkItem?
    @ObservationIgnored private var sessionGeneration: Int = 0
    @ObservationIgnored private var recognitionGeneration: Int = 0
    @ObservationIgnored private var shouldListen: Bool = false
    @ObservationIgnored private var suppressConfigChange: Bool = false
    // R109: os_unfair_lock is lighter than NSLock (which wraps pthread_mutex).
    // Same lock()/unlock() API; 47Hz audio hot path saves ~10s of ns per tick.
    @ObservationIgnored private var requestLock = OSAllocatedUnfairLock<Void>(initialState: ())
    @ObservationIgnored private var preemptiveRestartTimer: Timer?
    /// Sliding window of recent match positions for confidence gating.
    /// We require 2-of-3 recent results to agree before committing a forward jump.
    @ObservationIgnored private var recentMatchPositions: [Int] = []
    /// Transcript prefix to ignore when matching — set on jumps so the task
    /// can keep running instead of being restarted (a restart loses the words
    /// the user re-speaks right after the jump). Stored as the prefix string,
    /// not a char count: partial results revise earlier text, and trimming by
    /// the surviving common prefix avoids swallowing post-jump speech when
    /// the pre-jump portion changes length. Cleared whenever a new
    /// recognition task starts a fresh transcript.
    @ObservationIgnored private var spokenAnchorPrefix: String = "" {
        didSet { spokenAnchorPrefixUtf16Count = spokenAnchorPrefix.utf16.count }
    }
    /// Cached UTF-16 length of spokenAnchorPrefix. Avoids O(N) walk in
    /// matchCharacters when computing the trim length after a manual jump.
    @ObservationIgnored private var spokenAnchorPrefixUtf16Count: Int = 0
    /// Results computed before a jump can be delivered after it; matching
    /// ignores results for a short window so pre-jump speech isn't matched
    /// against the text at the new offset.
    @ObservationIgnored private var lastJumpAt: Date = .distantPast
    /// R62: STT recognizers frequently re-emit the latest partial verbatim.
    /// When fullSpoken, matchStartOffset and spokenAnchorPrefix are unchanged
    /// from the previous matchCharacters call, charLevelMatch and wordLevelMatch
    /// produce identical results — cache them and skip the O(N·M) scan.
    /// Cache invalidates automatically when any of the three keys differ
    /// (jumpTo / updateText / start / resume / restart all reset matchStartOffset
    /// and/or spokenAnchorPrefix).
    @ObservationIgnored private var prevMatchedFullSpoken: String = ""
    @ObservationIgnored private var prevMatchedStartOffset: Int = -1
    @ObservationIgnored private var prevMatchedAnchorPrefix: String = ""
    @ObservationIgnored private var prevMatchedCharResult: Int = 0
    @ObservationIgnored private var prevMatchedWordResult: Int = 0

    /// Update the source text while preserving the current recognized char count.
    /// Used by Director Mode to live-edit unread text without resetting read progress.
    func updateText(_ text: String, preservingCharCount: Int) {
        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        sourceTextCharCount = collapsed.count
        annotationRanges = SpeechTextAlignment.annotationRanges(in: collapsed)
        annotationCursor = 0
        recognizedCharCount = min(preservingCharCount, collapsed.count)
        recognizedCharCount = advancePastAnnotations(from: recognizedCharCount)
        matchStartOffset = recognizedCharCount
        recentMatchPositions = []
        rebuildMatchCache()
    }

    /// Jump highlight to a specific char offset (e.g. when user taps a word).
    /// Nearby jumps keep the recognition task alive and anchor matching past
    /// the already-spoken transcript, so tracking resumes on the first
    /// re-spoken word. Far jumps restart the task instead: contextualStrings
    /// are built for the section being read, and after a page-scale jump
    /// stale hints hurt recognition more than the task warm-up costs.
    /// retryCount is deliberately not touched here — resetting it on every
    /// tap would let a user keep a failing availability-retry loop alive
    /// forever.
    func jumpTo(charOffset: Int) {
        let clampedOffset = max(0, min(charOffset, sourceTextCharCount))
        let targetOffset = advancePastAnnotations(from: clampedOffset)
        let distance = abs(targetOffset - recognizedCharCount)
        recognizedCharCount = targetOffset
        matchStartOffset = targetOffset
        recentMatchPositions = []
        rebuildMatchCache()
        if isListening && (distance > 500 || !audioEngine.isRunning) {
            // Far jump, or the engine died without a config-change callback —
            // fall back to a full restart (also refreshes contextualStrings).
            restartRecognition(resetRetryCount: false)
            return
        }
        spokenAnchorPrefix = lastSpokenText
        lastJumpAt = Date()
    }

    func start(with text: String) {
        // Clean up any previous session immediately so pending restarts
        // and stale taps are removed before the async auth callback fires.
        cleanupRecognition()

        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        sourceTextCharCount = collapsed.count
        annotationRanges = SpeechTextAlignment.annotationRanges(in: collapsed)
        annotationCursor = 0
        recognizedCharCount = advancePastAnnotations(from: 0)
        matchStartOffset = recognizedCharCount
        retryCount = 0
        recentMatchPositions = []
        rebuildMatchCache()
        error = nil
        sessionGeneration &+= 1
        shouldListen = true
        isListening = false
        isStarting = true
        requestMicrophoneAccessAndBegin(for: sessionGeneration)
    }

    private func requestMicrophoneAccessAndBegin(for generation: Int) {
        guard shouldListen, sessionGeneration == generation else { return }

        // Check microphone permission first
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            failListening("麦克风权限被拒绝。请打开 系统设置 → 隐私与安全性 → 麦克风，并允许 Andy题词。")
            openMicrophoneSettings()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self,
                          self.shouldListen,
                          self.sessionGeneration == generation else { return }
                    if granted {
                        self.beginAfterMicrophoneAccess(for: generation)
                    } else {
                        self.failListening("麦克风权限被拒绝。请打开 系统设置 → 隐私与安全性 → 麦克风，并允许 Andy题词。")
                    }
                }
            }
        case .authorized:
            beginAfterMicrophoneAccess(for: generation)
        @unknown default:
            failListening("麦克风权限不可用。")
        }
    }

    private func beginAfterMicrophoneAccess(for generation: Int) {
        guard shouldListen, sessionGeneration == generation else { return }
        if NotchSettings.shared.listeningMode == .wordTracking {
            requestSpeechAuthAndBegin(for: generation)
        } else {
            beginRecognition()
        }
    }

    private func requestSpeechAuthAndBegin(for generation: Int) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self,
                      self.shouldListen,
                      self.sessionGeneration == generation else { return }
                switch status {
                case .authorized:
                    self.beginRecognition()
                default:
                    self.failListening("语音识别权限未授权。请打开 系统设置 → 隐私与安全性 → 语音识别，并允许 Andy题词。")
                    self.openSpeechRecognitionSettings()
                }
            }
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSpeechRecognitionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }

    private func failListening(_ message: String) {
        voiceActivityDetector.reset()
        shouldListen = false
        isListening = false
        isStarting = false
        error = message
        cleanupRecognition()
    }

    func stop() {
        shouldListen = false
        sessionGeneration &+= 1
        isListening = false
        isStarting = false
        _lastSpokenTail3 = ""
        _lastSpokenTail5 = ""
        cleanupRecognition()
    }

    /// Clears the cached last-spoken-tail strings without touching any other
    /// recognition state. Call when external code resets `lastSpokenText`
    /// directly (e.g. on page change) so the overlay doesn't show stale text
    /// until the next ASR partial arrives.
    func resetSpokenTails() {
        _lastSpokenTail3 = ""
        _lastSpokenTail5 = ""
    }

    func forceStop() {
        shouldListen = false
        sessionGeneration &+= 1
        isListening = false
        isStarting = false
        sourceText = ""
        sourceTextCharCount = 0
        annotationRanges = []
        annotationCursor = 0
        retryCount = maxRetries
        recentMatchPositions = []
        _lastSpokenTail3 = ""
        _lastSpokenTail5 = ""
        cleanupRecognition()
    }

    func resume() {
        guard !sourceText.isEmpty else { return }
        cleanupRecognition()
        retryCount = 0
        recognizedCharCount = advancePastAnnotations(from: recognizedCharCount)
        matchStartOffset = recognizedCharCount
        recentMatchPositions = []
        rebuildMatchCache()
        shouldDismiss = false
        error = nil
        sessionGeneration &+= 1
        shouldListen = true
        isListening = false
        isStarting = true
        requestMicrophoneAccessAndBegin(for: sessionGeneration)
    }

    private func cleanupRecognitionTask() {
        recognitionGeneration &+= 1
        // Cancel any pending restart to prevent overlapping beginRecognition calls
        pendingRestart?.cancel()
        pendingRestart = nil

        stopPreemptiveTimer()

        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationChangeObserver = nil
        }
        requestLock.lock()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        requestLock.unlock()
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func cleanupAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func cleanupRecognition() {
        cleanupRecognitionTask()
        cleanupAudioEngine()
        voiceActivityDetector.reset()
        _lastSpokenTail3 = ""
        _lastSpokenTail5 = ""
    }

    /// Coalesces all delayed beginRecognition() calls into a single pending work item.
    /// Any previously scheduled restart is cancelled before the new one is queued.
    private func scheduleBeginRecognition(after delay: TimeInterval) {
        pendingRestart?.cancel()
        guard shouldListen, !sourceText.isEmpty else { return }
        isListening = false
        isStarting = true
        let expectedSessionGeneration = sessionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldListen,
                  self.sessionGeneration == expectedSessionGeneration,
                  !self.sourceText.isEmpty else { return }
            self.pendingRestart = nil
            self.beginRecognition()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func beginRecognition() {
        guard shouldListen, !sourceText.isEmpty else {
            isListening = false
            isStarting = false
            return
        }
        let expectedSessionGeneration = sessionGeneration
        let requiresSpeechRecognition = NotchSettings.shared.listeningMode == .wordTracking
        // Ensure clean state
        cleanupRecognition()
        guard shouldListen, sessionGeneration == expectedSessionGeneration else {
            isListening = false
            isStarting = false
            return
        }
        isListening = false
        isStarting = true
        // New session = fresh transcript (see restartTask for why
        // lastSpokenText must be cleared alongside the anchor)
        spokenAnchorPrefix = ""
        lastSpokenText = ""

        // Create a fresh engine so it picks up the current hardware format.
        // AVAudioEngine caches the device format internally and reset() alone
        // does not reliably flush it after a mic switch.
        audioEngine = AVAudioEngine()
        suppressConfigChange = false

        // Set selected microphone if configured
        let micUID = NotchSettings.shared.selectedMicUID
        if !micUID.isEmpty, let deviceID = AudioInputDevice.deviceID(forUID: micUID) {
            // Suppress config-change observer during our own device switch
            suppressConfigChange = true
            let inputUnit = audioEngine.inputNode.audioUnit
            if let audioUnit = inputUnit {
                var devID = deviceID
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                // Re-initialize audio unit so it picks up the new device's format
                AudioUnitUninitialize(audioUnit)
                AudioUnitInitialize(audioUnit)
            }
            // Allow config changes again after a settle period
            let expectedSessionGeneration = sessionGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self,
                      self.sessionGeneration == expectedSessionGeneration else { return }
                self.suppressConfigChange = false
            }
        }

        if requiresSpeechRecognition {
            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: NotchSettings.shared.speechLocale))
            guard let speechRecognizer else {
                // nil means the locale isn't supported for speech recognition —
                // that's permanent, so fail immediately instead of retrying.
                failListening("Speech recognition isn't supported for the selected language.")
                return
            }
            guard speechRecognizer.isAvailable else {
                // Unavailability is often transient (the recognition service
                // churns briefly after a task cancellation or device change).
                // Giving up here leaves the engine stopped and the app deaf —
                // retry like the invalid-format guard below does.
                if retryCount < maxRetries {
                    retryCount += 1
                    scheduleBeginRecognition(after: 0.5)
                } else {
                    failListening("Speech recognizer is not available.")
                }
                return
            }

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest else {
                failListening("Unable to create a speech recognition request.")
                return
            }
            recognitionRequest.shouldReportPartialResults = true
            recognitionRequest.taskHint = .dictation

            // Build contextual strings from the cached lowercased source.
            // Replaces `String(sourceText.dropFirst(...))` + split + lowercased
            // + alnum-filter chain which allocated 1 whole-text String copy
            // + N per-word `lowercased()` Strings + N per-word `filter` Strings
            // for every ASR start/restart. (R31)
            let contextWords = upcomingContextWords()
            // Andy题词: 合并口播常用词热词表，提升中文 ASR 准确率
            let uniqueContextWords = Array(Set(contextWords + KouboVocabulary.words).prefix(80))
            if !uniqueContextWords.isEmpty {
                recognitionRequest.contextualStrings = uniqueContextWords
            }
        } else {
            speechRecognizer = nil
            recognitionRequest = nil
        }

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        // Guard against invalid format during device transitions (e.g. mic switch)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            // Retry after a longer delay to let the audio system settle
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                failListening("Audio input is unavailable.")
            }
            return
        }

        // SFSpeechRecognizer requires mono audio. Multi-channel devices (e.g.
        // RODECaster Pro II at 2ch/48kHz) cause the recognition task to silently
        // return no results. Request a mono tap and let AVAudioEngine downmix.
        let monoFormat = AVAudioFormat(
            commonFormat: hardwareFormat.commonFormat,
            sampleRate: hardwareFormat.sampleRate,
            channels: 1,
            interleaved: hardwareFormat.isInterleaved
        )
        let tapFormat = (hardwareFormat.channelCount > 1) ? monoFormat : hardwareFormat

        // Observe audio configuration changes (e.g. mic switched externally) to restart gracefully
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self,
                  self.shouldListen,
                  !self.suppressConfigChange,
                  !self.sourceText.isEmpty else { return }
            self.restartRecognition()
        }

        // Belt-and-suspenders: ensure no stale tap exists before installing
        inputNode.removeTap(onBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            self?.appendBufferToRequest(buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrt(sum / Float(max(frameLength, 1)))
            let level = CGFloat(min(rms * 5, 1.0))

            DispatchQueue.main.async {
                guard let self,
                      self.shouldListen,
                      self.sessionGeneration == expectedSessionGeneration else { return }
                self.recordAudioLevel(level)
            }
        }

        if let speechRecognizer, let recognitionRequest {
            recognitionGeneration &+= 1
            let currentRecognitionGeneration = recognitionGeneration
            let currentGeneration = sessionGeneration
            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let spoken = result.bestTranscription.formattedString
                    DispatchQueue.main.async {
                        // Ignore stale results from a previous session
                        guard self.sessionGeneration == currentGeneration,
                              self.recognitionGeneration == currentRecognitionGeneration else { return }
                        self.retryCount = 0 // Reset on success
                        self.lastSpokenText = spoken
                        self.matchCharacters(spoken: spoken)
                    }
                }
                if let error {
                    DispatchQueue.main.async {
                        guard self.sessionGeneration == currentGeneration,
                              self.recognitionGeneration == currentRecognitionGeneration else { return }
                        // If recognitionRequest is nil, cleanup already ran (intentional cancel) — don't retry
                        guard self.recognitionRequest != nil else { return }
                        guard self.shouldListen && !self.shouldDismiss && !self.sourceText.isEmpty else {
                            self.isListening = false
                            self.isStarting = false
                            return
                        }

                        self.matchStartOffset = self.recognizedCharCount

                        // Distinguish timeout errors (expected every ~60s) from real errors.
                        // SFSpeechRecognizer timeout is error code 1110 in kAFAssistantErrorDomain,
                        // or 216 (kAudioConverterErr_FormatNotSupported). Retry immediately for
                        // timeouts with no retry limit; use backoff for real errors.
                        let nsError = error as NSError
                        let isTimeout = nsError.code == 1110 || nsError.code == 216

                        if isTimeout {
                            // Expected timeout — restart immediately, no retry limit
                            self.retryCount = 0
                            if self.audioEngine.isRunning {
                                self.restartTask()
                            } else {
                                self.scheduleBeginRecognition(after: 0.1)
                            }
                        } else if self.retryCount < self.maxRetries {
                            self.retryCount += 1
                            let delay = min(Double(self.retryCount) * 0.5, 1.5)
                            self.scheduleBeginRecognition(after: delay)
                        } else {
                            self.failListening("Speech recognition stopped: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            guard shouldListen, sessionGeneration == expectedSessionGeneration else {
                cleanupRecognition()
                return
            }
            error = nil
            isStarting = false
            isListening = true
            if requiresSpeechRecognition {
                startPreemptiveTimer()
            }
        } catch {
            // Transient failure after a device switch — retry with longer delay
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                failListening("Audio engine failed: \(error.localizedDescription)")
            }
        }
    }

    private func restartRecognition(resetRetryCount: Bool = true) {
        guard shouldListen, !sourceText.isEmpty else {
            isListening = false
            isStarting = false
            return
        }
        if resetRetryCount {
            retryCount = 0
        }
        isListening = false
        isStarting = true
        cleanupRecognition()
        scheduleBeginRecognition(after: 0.5)
    }

    // MARK: - Thread-safe buffer appending

    // R84: cache `audioLevels.count` once. Previous version read count twice
    // per call (one for the >30 guard, one inside removeFirst's argument).
    // audioLevels is an @Observable-stored [CGFloat]; each .count access goes
    // through the synthesized observationRegistrar.access call. recordAudioLevel
    // fires at the AVAudioEngine tap rate (~15 Hz with bufferSize 1024 at 16 kHz
    // mono), so the original code did 2 redundant count reads/tick × 15 Hz = 30
    // redundant @Observable accesses/sec. The fire-and-forget trim path is
    // equivalent because `count + 1 > 30` ⟺ `count >= 30`, and removeFirst(n-29)
    // leaves exactly 30 elements (matches the old removeFirst((n+1)-30) post-
    // append behavior).
    private func recordAudioLevel(_ level: CGFloat) {
        let count = audioLevels.count
        if count >= 30 {
            audioLevels.removeFirst(count - 29)
        }
        audioLevels.append(level)
        voiceActivityDetector.process(level: level, at: ProcessInfo.processInfo.systemUptime)
    }

    private func appendBufferToRequest(_ buffer: AVAudioPCMBuffer) {
        requestLock.lock()
        recognitionRequest?.append(buffer)
        requestLock.unlock()
    }

    /// Build contextual strings from the upcoming portion of the source text
    /// using the already-lowercased char cache. Mirrors the prior behavior
    /// (`split(separator: " ")` + `lowercased()` + `filter(isLetter/isNumber)`
    /// + `filter(count >= 5)`) without the per-word `lowercased()` alloc or
    /// the `String(dropFirst(_:))` copy. Lookahead is capped to bound work on
    /// huge scripts. (R31)
    private func upcomingContextWords(lookaheadChars: Int = 1500) -> [String] {
        let totalLen = cachedLowercasedSource.count
        let startOffset = min(matchStartOffset, totalLen)
        let endOffset = min(startOffset + lookaheadChars, totalLen)
        var contextWords: [String] = []
        contextWords.reserveCapacity(32)
        var wordBuf = ""
        wordBuf.reserveCapacity(16)
        for i in startOffset..<endOffset {
            let ch = cachedLowercasedSource[i]
            // Original split on " " (space only); other whitespace and `\n`
            // survived into the word then got dropped by the alnum filter.
            // Mirror that here: only " " is a word boundary; everything
            // non-alnum is dropped from the running buffer.
            if ch == " " {
                if wordBuf.count >= 5 {
                    contextWords.append(wordBuf)
                }
                wordBuf.removeAll(keepingCapacity: true)
                continue
            }
            if ch.isLetter || ch.isNumber {
                wordBuf.append(ch)
            }
            // else: drop (\n, tabs, punctuation)
        }
        if wordBuf.count >= 5 {
            contextWords.append(wordBuf)
        }
        return contextWords
    }

    // MARK: - Soft restart (task only, keeps audio engine running)

    private func restartTask() {
        guard shouldListen, isListening, audioEngine.isRunning, !sourceText.isEmpty else {
            isListening = false
            if shouldListen, !sourceText.isEmpty {
                cleanupRecognition()
                scheduleBeginRecognition(after: 0.5)
            }
            return
        }
        recognitionGeneration &+= 1
        let currentRecognitionGeneration = recognitionGeneration
        // Update match offset before restarting
        matchStartOffset = recognizedCharCount
        recentMatchPositions = []
        // New task = fresh transcript. lastSpokenText must be cleared too:
        // a jump taken before the first new result would otherwise anchor on
        // the old task's transcript and trim away everything the new task
        // ever produces.
        spokenAnchorPrefix = ""
        lastSpokenText = ""

        // Cancel any pending restart to avoid stale beginRecognition clobbering this session
        pendingRestart?.cancel()
        pendingRestart = nil

        // Cancel the old task and atomically swap to a new request under lock.
        // The lock prevents the audio tap from appending to the old request
        // between endAudio() and the new assignment.
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.taskHint = .dictation

        // Build contextual strings from the cached lowercased source. (R31)
        let contextWords = upcomingContextWords()
        let uniqueWords = Array(Set(contextWords).prefix(50))
        if !uniqueWords.isEmpty {
            newRequest.contextualStrings = uniqueWords
        }

        // Nil out recognitionRequest before cancelling the old task so the
        // old task's error callback sees nil and skips retry logic. Then set
        // the new request after cancellation.
        requestLock.lock()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        requestLock.unlock()
        recognitionTask?.cancel()
        recognitionTask = nil

        requestLock.lock()
        recognitionRequest = newRequest
        requestLock.unlock()

        // Start new recognition task
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            // Transient unavailability — fall back to a full session restart
            // with retries rather than going permanently deaf.
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                // Don't leave the mic hot with no session consuming it
                failListening("Speech recognizer is not available.")
            }
            return
        }

        let currentGeneration = sessionGeneration
        recognitionTask = speechRecognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let spoken = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    guard self.sessionGeneration == currentGeneration,
                          self.recognitionGeneration == currentRecognitionGeneration else { return }
                    self.retryCount = 0
                    self.lastSpokenText = spoken
                    self.matchCharacters(spoken: spoken)
                }
            }
            if let error {
                DispatchQueue.main.async {
                    guard self.sessionGeneration == currentGeneration,
                          self.recognitionGeneration == currentRecognitionGeneration else { return }
                    guard self.recognitionRequest != nil else { return }
                    guard self.shouldListen && !self.shouldDismiss && !self.sourceText.isEmpty else {
                        self.isListening = false
                        self.isStarting = false
                        return
                    }

                    self.matchStartOffset = self.recognizedCharCount

                    let nsError = error as NSError
                    let isTimeout = nsError.code == 1110 || nsError.code == 216

                    if isTimeout {
                        self.retryCount = 0
                        if self.audioEngine.isRunning {
                            self.restartTask()
                        } else {
                            self.scheduleBeginRecognition(after: 0.1)
                        }
                    } else if self.retryCount < self.maxRetries {
                        self.retryCount += 1
                        let delay = min(Double(self.retryCount) * 0.5, 1.5)
                        self.scheduleBeginRecognition(after: delay)
                    } else {
                        self.failListening("Speech recognition stopped: \(error.localizedDescription)")
                    }
                }
            }
        }

        startPreemptiveTimer()
    }

    // MARK: - Pre-emptive restart timer

    private func startPreemptiveTimer() {
        preemptiveRestartTimer?.invalidate()
        preemptiveRestartTimer = Timer.scheduledTimer(withTimeInterval: 55.0, repeats: true) { [weak self] _ in
            guard let self, self.isListening, !self.sourceText.isEmpty else { return }
            self.restartTask()
        }
    }

    private func stopPreemptiveTimer() {
        preemptiveRestartTimer?.invalidate()
        preemptiveRestartTimer = nil
    }

    // MARK: - Fuzzy character-level matching

    private func matchCharacters(spoken fullSpoken: String) {
        // Results computed before a jump can be delivered just after it —
        // don't match pre-jump speech against the text at the new offset.
        guard Date().timeIntervalSince(lastJumpAt) > 0.3 else { return }

        // R97: cache fullSpoken.utf16.count once. The matchCharacters body
        // reads it twice (lines 964 + 981 below) on every ASR partial at
        // 5-20 Hz — utf16.count is O(1) for ASCII/BMP but each call still
        // does a property dispatch + length read on the String's UTF16View.
        // For STT plain text the value is invariant within this call, so
        // one local covers both sites with identical semantics.
        let fullSpokenUtf16Count = fullSpoken.utf16.count

        // Ignore transcript from before the most recent jump. Trim by the
        // common prefix that survived the recognizer's revisions, but never
        // less than the anchor length minus a small slack — a revision very
        // early in the transcript would otherwise leak the whole pre-jump
        // transcript back into matching.
        // Hold `spoken` as a Substring view into fullSpoken's storage instead of
        // allocating a fresh String. `dropFirst` returns a Substring sharing
        // fullSpoken's underlying buffer (COW), so per-ASR-partial we save:
        // - 1 Substring → String wrap allocation
        // - the Grapheme walk String.init(Substring) does internally
        // Generic <S: StringProtocol> char/word level matchers accept the
        // Substring directly. (R24)
        let spoken: Substring
        if !spokenAnchorPrefix.isEmpty {
            // Manual utf16 iterator walk for the common-prefix count.
            // Replaces `zip(spokenAnchorPrefix, fullSpoken).prefix(while:
            // { $0 == $1 }).count` which built a Zip2 + PrefixSequence +
            // closure-capture, and each Character equality checks Unicode
            // grapheme normalization. Both sides are STT plain text — utf16
            // unit comparison is correct and ~10× cheaper per char. (R28)
            let aU16 = spokenAnchorPrefix.utf16
            let bU16 = fullSpoken.utf16
            let limit = min(spokenAnchorPrefixUtf16Count, fullSpokenUtf16Count)
            var ai = aU16.startIndex
            var bi = bU16.startIndex
            var common = 0
            while common < limit, aU16[ai] == bU16[bi] {
                ai = aU16.index(after: ai)
                bi = bU16.index(after: bi)
                common += 1
            }
            // Use cached utf16 counts (set via didSet on lastSpokenText /
            // spokenAnchorPrefix) to avoid O(N) String.count walks per ASR
            // partial. utf16.count and Swift's String.count only diverge
            // when the text contains surrogate-pair grapheme clusters
            // (e.g. emoji) — STT output is plain text in practice.
            let trimLen = min(lastSpokenTextUtf16Count, max(common, spokenAnchorPrefixUtf16Count - 24))
            // dropFirst traps if trimLen > fullSpoken.utf16.count; guard
            // with the cheap utf16 count (O(1), no grapheme walk).
            if trimLen >= fullSpokenUtf16Count { return }
            spoken = fullSpoken.dropFirst(trimLen)
        } else {
            spoken = Substring(fullSpoken)
        }
        guard !spoken.isEmpty else { return }

        // R62: cache char/word match results when STT re-emits the same
        // partial. The matchers are O(N·M) over remaining source length
        // and spoken length — for a 10-minute script and a 5-word partial
        // that's ~7.5k character comparisons + up to ~100 fuzzy match
        // calls. STT recognizers routinely repeat the latest partial
        // verbatim while waiting for the speaker; skipping the scan
        // here drops the heavy work for those ticks entirely. Confidence
        // gating, recognizedCharCount advancement, and recentMatchPositions
        // still run so commit behavior is unchanged.
        let isRepeat = !prevMatchedFullSpoken.isEmpty
            && fullSpoken == prevMatchedFullSpoken
            && matchStartOffset == prevMatchedStartOffset
            && spokenAnchorPrefix == prevMatchedAnchorPrefix
        let charResult: Int
        let wordResult: Int
        if isRepeat {
            charResult = prevMatchedCharResult
            wordResult = prevMatchedWordResult
        } else {
            // Strategy 1: character-level fuzzy match from the start offset
            charResult = charLevelMatch(spoken: spoken)
            // Strategy 2: word-level match (handles STT word substitutions)
            wordResult = wordLevelMatch(spoken: spoken)
            prevMatchedFullSpoken = fullSpoken
            prevMatchedStartOffset = matchStartOffset
            prevMatchedAnchorPrefix = spokenAnchorPrefix
            prevMatchedCharResult = charResult
            prevMatchedWordResult = wordResult
        }

        // Combine the two strategies. When they agree, average; when they
        // disagree, prefer the further (word-level) match so fast reading can
        // catch up instead of being dragged back by the brittle character scan.
        let best = SpeechTextAlignment.bestOffset(characterResult: charResult, wordResult: wordResult)

        let rawCandidate = min(matchStartOffset + best, sourceTextCharCount)
        let candidate = advancePastAnnotations(from: rawCandidate)
        guard candidate > recognizedCharCount else { return }

        // Confidence gating: require 2-of-3 recent results to agree on
        // forward movement to avoid single-result false-positive jumps.
        recentMatchPositions.append(candidate)
        if recentMatchPositions.count > 3 {
            recentMatchPositions.removeFirst()
        }

        // Check if at least 2 of the recent positions agree (within tolerance)
        let agreementThreshold = 10 // characters
        var confirmed = false
        if recentMatchPositions.count >= 2 {
            var agreeCount = 0
            for pos in recentMatchPositions {
                if abs(pos - candidate) <= agreementThreshold {
                    agreeCount += 1
                }
            }
            confirmed = agreeCount >= 2
        }

        // Small forward movements (< 1 word length) are always allowed
        // to keep the highlight responsive for normal reading
        if SpeechTextAlignment.shouldCommit(
            characterResult: charResult,
            wordResult: wordResult,
            current: recognizedCharCount,
            rawCandidate: rawCandidate,
            candidate: candidate,
            confirmed: confirmed
        ) {
            recognizedCharCount = candidate
        }
    }

    private func advancePastAnnotations(from offset: Int) -> Int {
        SpeechTextAlignment.advancePastAnnotations(
            in: cachedLowercasedSource,
            ranges: annotationRanges,
            from: offset,
            cursor: &annotationCursor
        )
    }

    /// Refresh the per-source cached views used by char/word level matchers.
/// Called whenever sourceText changes or after a manual jump.
    private func rebuildMatchCache() {
        // Note: use cachedLowercasedSource (Character array) for offset/character
        // checks — Swift String does not allow Int subscripting and going via
        // String.Index would allocate per call. Character-count == lowercased
        // length because lowercased() preserves length for all script we
        // process (Latin, CJK).
        let lower = sourceText.lowercased()
        cachedLowercasedSource = Array(lower)
        let split = sourceText.split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        cachedSourceWords = split.map { String($0) }
        // Pre-compute lowercased+letters/digits-only versions of each source
        // word. wordLevelMatch previously called .lowercased().filter {...}
        // per word per ASR partial — Character.isLetter/isNumber is slow
        // because of Unicode property lookups.
        cachedSourceWordAlnum = cachedSourceWords.map { word in
            var out = ""
            out.reserveCapacity(word.count)
            for ch in word.lowercased() where ch.isLetter || ch.isNumber {
                out.append(ch)
            }
            return out
        }
        // Pre-compute Character counts once so wordLevelMatch and isFuzzyMatch
        // can avoid the O(N) grapheme walk that String.count performs.
        // utf16.count is O(1) and matches Character.count for all BMP scripts.
        cachedSourceWordCharCount = cachedSourceWords.map { $0.utf16.count }
        cachedSourceWordAlnumUtf16Count = cachedSourceWordAlnum.map { $0.utf16.count }
        // R54: pre-materialize each alnum word into a [UInt16] once. Lets
        // editDistance skip the per-call `Array(srcWord.utf16)` allocation
        // (and the matching grapheme → utf16 code-unit walk) on the source
        // side, where the word is invariant across ASR partials. Spoken-
        // side words still allocate — they're freshly built per partial.
        cachedSourceWordAlnumUtf16 = cachedSourceWordAlnum.map { Array($0.utf16) }
        let lowerChars = cachedLowercasedSource
        var offsets = [Int](repeating: 0, count: cachedSourceWords.count)
        var cursor = 0
        let total = lowerChars.count
        for (i, w) in cachedSourceWords.enumerated() {
            // Account for collapsed whitespace between words — find first
            // non-whitespace starting at `cursor`.
            while cursor < total, lowerChars[cursor].isWhitespace {
                cursor += 1
            }
            offsets[i] = cursor
            cursor += w.count
            // skip any remaining whitespace inside collapsed sequence (defensive)
            while cursor < total, lowerChars[cursor].isWhitespace {
                cursor += 1
            }
        }
        cachedWordOffsets = offsets
        charMatchCursor = matchStartOffset

        // R21: pre-compute per-word annotation flag and per-char annotation
        // mask so the hot matchers don't have to do O(N) bracket scans or
        // O(W) `word.filter` allocations per ASR partial. See comments on
        // the property declarations for the rationale.
        var wordMask = [Bool](repeating: false, count: cachedSourceWords.count)
        // Pass 1: any `]` anywhere? If not, no `[...]` blocks exist and we
        // can skip the inside-annotation scan entirely.
        var anyClosingBracket = false
        for word in cachedSourceWords where word.contains("]") {
            anyClosingBracket = true
            break
        }
        if anyClosingBracket {
            var inside = false
            for (i, word) in cachedSourceWords.enumerated() {
                if word.hasPrefix("[") {
                    inside = true
                }
                if inside {
                    wordMask[i] = true
                }
                if word.contains("]") {
                    inside = false
                }
            }
        }
        // Pass 2: punctuation-only words (matches isAnnotationWord's second
        // condition). For words already inside an annotation block, this is
        // redundant; for everything else, it catches `...`, `!!!`, orphan
        // `]`, etc. that contribute no alnum chars.
        for (i, word) in cachedSourceWords.enumerated() where !wordMask[i] {
            if word.hasPrefix("[") && word.hasSuffix("]") {
                wordMask[i] = true
                continue
            }
            var hasAlnum = false
            for ch in word where ch.isLetter || ch.isNumber {
                hasAlnum = true
                break
            }
            if !hasAlnum {
                wordMask[i] = true
            }
        }
        cachedSourceWordIsAnnotation = wordMask

        // Char-level mask: mark every character that's inside a `[...]` block.
        // We scan cachedLowercasedSource directly (guaranteed to be the same
        // length / same indexing as the cache the matcher reads) and stamp
        // `true` for the chars between matching brackets.
        var charMask = [Bool](repeating: false, count: lowerChars.count)
        var openingIndex: Int? = nil
        for (i, ch) in lowerChars.enumerated() {
            if ch == "[", openingIndex == nil {
                openingIndex = i
            } else if ch == "]", let start = openingIndex {
                for j in start..<(i + 1) {
                    charMask[j] = true
                }
                openingIndex = nil
            }
        }
        cachedCharIsInAnnotation = charMask
    }

    /// Find the first cachedSourceWords index whose starting offset >= target.
    /// Caller must clamp target to sourceText.count.
    private func wordIndexAtCharOffset(_ target: Int) -> Int {
        // cachedWordOffsets is monotonically non-decreasing; binary search.
        var lo = 0, hi = cachedWordOffsets.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if cachedWordOffsets[mid] < target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return min(lo, max(0, cachedWordOffsets.count - 1))
    }

    private func charLevelMatch<S: StringProtocol>(spoken: S) -> Int {
        // Use the cached Character array's count (O(1)) instead of sourceText.count
        // (O(N) grapheme walk). The cache is rebuilt only when sourceText changes.
        let totalLen = cachedLowercasedSource.count
        let src = cachedLowercasedSource

        // Single-pass lowercase + alnum/whitespace filter into [Character].
        // Replaces `Array(Self.normalize(spoken))` which allocated 2 Strings
        // (one from `lowercased()`, one from `.filter`) and walked the
        // grapheme 3 times per ASR partial. `Self.normalize` still exists
        // for the 2 cold callsites in updateText/start. ASCII fast path
        // mirrors wordLevelMatch's lowercasing branch. (R22)
        var spk: [Character] = []
        spk.reserveCapacity(spoken.utf16.count)
        for ch in spoken {
            if ch.isASCII {
                let v = ch.unicodeScalars.first!.value
                if v >= 65 && v <= 90 {
                    spk.append(Character(UnicodeScalar(v + 32)!))
                } else if (v >= 97 && v <= 122) || (v >= 48 && v <= 57)
                    || v == 32 || v == 9 || v == 10 || v == 13 {
                    spk.append(ch)
                }
                // else: ASCII punctuation -> drop
            } else {
                // Non-ASCII alnum/whitespace. Character.lowercased() returns
                // a String (grapheme length may change, e.g. ligatures); its
                // first Character is what the original normalize kept.
                let lowerStr = ch.lowercased()
                guard let lowerCh = lowerStr.first else { continue }
                if lowerCh.isLetter || lowerCh.isNumber || lowerCh.isWhitespace {
                    spk.append(lowerCh)
                }
            }
        }

        // Anchor positions:
        //   si = position in source we're currently matching at
        //   ri = position in spoken we've consumed up to
        var si = matchStartOffset
        var ri = 0
        var lastGoodOrigIndex = si

        // Anchor in spoken at the surviving prefix. We approximate by skipping
        // any leading non-alnum noise, then assuming the next alnum char aligns
        // with si. This matches the prior behavior of starting from
        // matchStartOffset against a freshly built remainingSource.
        while ri < spk.count, !spk[ri].isLetter, !spk[ri].isNumber {
            ri += 1
        }

        // If we've already advanced past previously seen text, fast-forward si
        // past any leading non-alnum in source (mirrors old behavior).
        // Annotation chars are skipped via the per-char mask (R21) — the old
        // `src[si...].firstIndex(of: "]")` scan was O(N) per `[`.
        while si < totalLen, !src[si].isLetter, !src[si].isNumber, !cachedCharIsInAnnotation[si] {
            si += 1
        }

        let matchStart = si

        while si < totalLen && ri < spk.count {
            let sc = src[si]
            let rc = spk[ri]

            // Skip annotation chars via pre-computed mask (R21). Replaces the
            // old `src[si...].firstIndex(of: "]")` O(N) scan + ArraySlice
            // alloc per bracket encounter.
            if cachedCharIsInAnnotation[si] {
                si += 1
                lastGoodOrigIndex = si
                continue
            }

            // Skip non-alphanumeric in source
            if !sc.isLetter && !sc.isNumber {
                si += 1
                continue
            }
            // Skip non-alphanumeric in spoken
            if !rc.isLetter && !rc.isNumber {
                ri += 1
                continue
            }

            if sc == rc {
                si += 1
                ri += 1
                lastGoodOrigIndex = si
            } else {
                // Try to re-sync: look ahead in both strings
                var found = false

                // Skip up to 5 chars in spoken (STT inserted extra chars, or
                // fast reading outran the scan)
                let maxSkipR = min(5, spk.count - ri - 1)
                if maxSkipR >= 1 {
                    for skipR in 1...maxSkipR {
                        let nextRI = ri + skipR
                        if nextRI < spk.count && spk[nextRI] == sc {
                            ri = nextRI
                            found = true
                            break
                        }
                    }
                }
                if found { continue }

                // Skip up to 5 chars in source (STT missed some chars, or
                // fast reading outran the scan)
                let maxSkipS = min(5, totalLen - si - 1)
                if maxSkipS >= 1 {
                    for skipS in 1...maxSkipS {
                        let nextSI = si + skipS
                        if nextSI < totalLen && src[nextSI] == rc {
                            si = nextSI
                            found = true
                            break
                        }
                    }
                }
                if found { continue }

                // No resync found — advance spoken pointer only.
                // Do NOT advance lastGoodOrigIndex; this is a genuine mismatch,
                // not a confirmed match position.
                ri += 1
            }
        }

        while si < totalLen {
            if cachedCharIsInAnnotation[si] {
                si += 1
                lastGoodOrigIndex = si
            } else if !src[si].isLetter && !src[si].isNumber {
                si += 1
                lastGoodOrigIndex = si
            } else {
                break
            }
        }

        charMatchCursor = matchStart  // remember where this scan started
        return lastGoodOrigIndex
    }

    private func wordLevelMatch<S: StringProtocol>(spoken: S) -> Int {
        // Reuse the cached word view; start from the first word whose
        // starting char-offset is >= matchStartOffset.
        guard !cachedSourceWords.isEmpty else { return 0 }
        let startIdx = wordIndexAtCharOffset(matchStartOffset)
        // Work with absolute indices into the cached arrays instead of copying
        // the suffix into fresh arrays on every call.
        let sourceCount = cachedSourceWords.count
        // Fold splitTextIntoWords + lowercased + alnum-filter into a single
        // per-character walk. Replaces the previous chain
        // `splitTextIntoWords(spoken).map { ... }` which allocated: 1
        // replacingOccurrences String, 1 [Substring] array, N Substring
        // slices, N String(Substring) inits, N per-word `out = ""` Strings,
        // plus a separate `[Int].map { $0.utf16.count }` for length
        // parallel array. New path: 1 [String] + 1 [Int] reserved once,
        // 1 reused buffer between words. Behavior preserved:
        // - whitespace splits (incl. '\n' → separator)
        // - CJK chars become individual words (matches splitTextIntoWords)
        // - ASCII A-Z lowercased in place
        // - non-alnum dropped per char. (R23)
        var spokenAlnumWords: [String] = []
        var spokenAlnumUtf16Counts: [Int] = []
        // R102: parallel [UInt16] table to feed isFuzzyMatchCachedSrc without
        // a per-call `Array(b.utf16)` materialization. Built once per partial,
        // looked up by index at each skip step (≤12 lookups per partial).
        var spokenAlnumUtf16: [[UInt16]] = []
        spokenAlnumWords.reserveCapacity(32)
        spokenAlnumUtf16Counts.reserveCapacity(32)
        spokenAlnumUtf16.reserveCapacity(32)
        var wordBuf = ""
        wordBuf.reserveCapacity(16)
        for ch in spoken {
            if ch.isWhitespace || ch == "\n" {
                if !wordBuf.isEmpty {
                    spokenAlnumUtf16Counts.append(wordBuf.utf16.count)
                    spokenAlnumWords.append(wordBuf)
                    spokenAlnumUtf16.append(Array(wordBuf.utf16))
                    wordBuf = ""
                    wordBuf.reserveCapacity(16)
                }
                continue
            }
            if ch.isASCII {
                let v = ch.unicodeScalars.first!.value
                if v >= 65 && v <= 90 {
                    wordBuf.append(Character(UnicodeScalar(v + 32)!))
                } else if (v >= 97 && v <= 122) || (v >= 48 && v <= 57) {
                    wordBuf.append(ch)
                }
                // else: ASCII punctuation → drop
                continue
            }
            // Non-ASCII: split CJK chars as individual words (matches the
            // CJK branch in MarqueeTextView.splitTextIntoWords). Other
            // non-ASCII alnum (accented Latin etc.) joins the buffer.
            let firstScalar = ch.unicodeScalars.first
            let isCJK = firstScalar.map { $0.isCJK } ?? false
            if isCJK {
                if !wordBuf.isEmpty {
                    spokenAlnumUtf16Counts.append(wordBuf.utf16.count)
                    spokenAlnumWords.append(wordBuf)
                    spokenAlnumUtf16.append(Array(wordBuf.utf16))
                    wordBuf = ""
                    wordBuf.reserveCapacity(16)
                }
                if ch.isLetter || ch.isNumber {
                    spokenAlnumUtf16Counts.append(ch.utf16.count)
                    spokenAlnumWords.append(String(ch))
                    spokenAlnumUtf16.append(Array(ch.utf16))
                }
            } else if ch.isLetter || ch.isNumber {
                let lower = ch.lowercased()
                if let c = lower.first {
                    wordBuf.append(c)
                }
            }
            // else: non-ASCII punctuation → drop
        }
        if !wordBuf.isEmpty {
            spokenAlnumUtf16Counts.append(wordBuf.utf16.count)
            spokenAlnumWords.append(wordBuf)
            spokenAlnumUtf16.append(Array(wordBuf.utf16))
        }
        let spokenAlnumCount = spokenAlnumWords.count

        var si = startIdx // absolute source word index into cachedSourceWords
        var ri = 0 // spoken word index
        var matchedCharCount = cachedWordOffsets[startIdx]
        // `isInsideAnnotation` is no longer needed at runtime — R21 pre-computes
        // the per-word annotation flag in cachedSourceWordIsAnnotation so the
        // hot loop is a single array lookup.

        // Anchor spoken at the prefix that's already matched.
        // splitTextIntoWords collapses whitespace; we don't know exactly which
        // spoken words correspond to source words[0..<startIdx], so we let
        // matching begin at the first remaining source word.

        while si < sourceCount && ri < spokenAlnumCount {
            // Auto-skip annotation words in source (brackets, emoji,
            // punctuation-only). Pre-computed in rebuildMatchCache — O(1)
            // array lookup replaces the old (si..<sourceCount).contains(where:)
            // O(N) scan and `Self.isAnnotationWord`'s `word.filter` allocation.
            if cachedSourceWordIsAnnotation[si] {
                matchedCharCount += cachedSourceWordCharCount[si]
                if si < sourceCount - 1 { matchedCharCount += 1 }
                si += 1
                continue
            }

            let srcWord = cachedSourceWordAlnum[si]
            // R54: src-side utf16 length now lives inside cachedSourceWordAlnumUtf16
            // (looked up by isFuzzyMatchCachedSrc), so this local is unused —
            // but we keep `srcWord` for the cheap `==` short-circuit above.
            let spkWord = spokenAlnumWords[ri]
            let spkWordCount = spokenAlnumUtf16Counts[ri]
            // R102: parallel utf16 table lookup replaces the per-call
            // `Array(b.utf16)` materialization in isFuzzyMatchCachedSrc.
            let spkWordUtf16 = spokenAlnumUtf16[ri]

            if srcWord == spkWord || isFuzzyMatchCachedSrc(srcIndex: si, b: spkWord, bUtf16: spkWordUtf16, bCount: spkWordCount) {
                // Count original chars including trailing punctuation
                matchedCharCount += cachedSourceWordCharCount[si]
                si += 1
                ri += 1
                // Add space separator only if there's a following word
                if si < sourceCount {
                    matchedCharCount += 1
                }
            } else {
                // Try skipping up to 5 spoken words (STT hallucinated words,
                // or fast reading produced a burst)
                var foundSpk = false
                let maxSpkSkip = min(5, spokenAlnumCount - ri - 1)
                if maxSpkSkip >= 1 {
                    for skip in 1...maxSpkSkip {
                        let nextSpk = spokenAlnumWords[ri + skip]
                        let nextSpkCount = spokenAlnumUtf16Counts[ri + skip]
                        // R102: parallel utf16 table lookup.
                        let nextSpkUtf16 = spokenAlnumUtf16[ri + skip]
                        if srcWord == nextSpk || isFuzzyMatchCachedSrc(srcIndex: si, b: nextSpk, bUtf16: nextSpkUtf16, bCount: nextSpkCount) {
                            ri += skip
                            foundSpk = true
                            break
                        }
                    }
                }
                if foundSpk { continue }

                // Try skipping up to 5 source words (user read fast, STT missed words)
                var foundSrc = false
                let maxSrcSkip = min(5, sourceCount - si - 1)
                if maxSrcSkip >= 1 {
                    for skip in 1...maxSrcSkip {
                        let nextSrc = cachedSourceWordAlnum[si + skip]
                        // R54: src-side utf16 length unused (isFuzzyMatchCachedSrc
                        // looks it up internally from cachedSourceWordAlnumUtf16).
                        if nextSrc == spkWord || isFuzzyMatchCachedSrc(srcIndex: si + skip, b: spkWord, bUtf16: spkWordUtf16, bCount: spkWordCount) {
                            // Add all skipped source words' char counts
                            for s in 0..<skip {
                                matchedCharCount += cachedSourceWordCharCount[si + s] + 1
                            }
                            si += skip
                            foundSrc = true
                            break
                        }
                    }
                }
                if foundSrc { continue }

                // Try treating current source word as punctuation-only and skip it
                if srcWord.isEmpty {
                    matchedCharCount += cachedSourceWordCharCount[si]
                    if si < sourceCount - 1 { matchedCharCount += 1 }
                    si += 1
                    continue
                }
                // No match, advance spoken
                ri += 1
            }
        }

        // Auto-skip trailing annotation words at end of source. R21: O(1) array
        // lookup via the pre-computed cachedSourceWordIsAnnotation mask.
        while si < sourceCount, cachedSourceWordIsAnnotation[si] {
            matchedCharCount += cachedSourceWordCharCount[si]
            if si < sourceCount - 1 { matchedCharCount += 1 }
            si += 1
        }

        return matchedCharCount
    }

    /// R102: hot-path isFuzzyMatch variant for when `a` is one of the cached
    /// source words. Same exact-match / prefix / shared-prefix / DP checks as
    /// the String overload, but:
    /// - The source side reads its [UInt16] from the rebuild-time cache
    ///   (R54) — no per-call `Array(a.utf16)`.
    /// - The spoken side now receives pre-built [UInt16] from the caller
    ///   (R102) — no per-call `Array(b.utf16)` either, and the prefix +
    ///   shared-prefix walks share one utf16 traversal instead of three
    ///   separate ones (`a.hasPrefix`, `b.hasPrefix`, and the prior
    ///   shared-walk). The combined walk also replaces the awkward
    ///   `aU16.distance(from:to:)` with a running `shared` counter.
    /// Net per mismatch in wordLevelMatch's skip-lookahead loops
    /// (~12 calls/partial): -2 utf16 materializations, -2 String view walks,
    /// -1 distance() call.
    private func isFuzzyMatchCachedSrc(srcIndex: Int, b: String, bUtf16: [UInt16], bCount: Int) -> Bool {
        let a = cachedSourceWordAlnum[srcIndex]
        let aLen = cachedSourceWordAlnumUtf16Count[srcIndex]
        if aLen == 0 || bCount == 0 { return false }
        // Exact match
        if a == b { return true }
        let shorter = min(aLen, bCount)
        let longer = max(aLen, bCount)
        if shorter <= 2 { return false } // 2-char words must be exact
        // R102: combined prefix + shared-prefix utf16 walk. Original called
        // a.hasPrefix(b), b.hasPrefix(a), then a separate utf16 shared-prefix
        // walk — 3 utf16 walks per call. Merged into one: walk shared chars
        // while they match, then decide prefix (full match on either side)
        // vs shared (>= 60% of shorter word, min 3).
        let aU16 = a.utf16
        let sharedMax = shorter
        var shared = 0
        var ai = aU16.startIndex
        var bi = 0  // Int index into [UInt16]
        while ai < aU16.endIndex, bi < bUtf16.count, shared < sharedMax,
              aU16[ai] == bUtf16[bi] {
            ai = aU16.index(after: ai)
            bi += 1
            shared += 1
        }
        // R102: prefix-match decision. shared == aLen ⇒ a is fully consumed
        // (a is prefix of b); shared == bCount ⇒ b is fully consumed
        // (b is prefix of a). `shorter <= 2` already short-circuited above so
        // `shared >= 3` implies the shorter side has at least 3 chars.
        if shared >= 3, shared == aLen || shared == bCount { return true }
        // R102: shared-prefix >= 60% of shorter word (min 3 chars).
        if shared >= max(3, sharedMax * 3 / 5) { return true }
        let tolerance: Int
        if shorter <= 4 { tolerance = 1 }
        else if shorter <= 8 { tolerance = 2 }
        else { tolerance = longer / 3 }
        if longer - shorter > tolerance { return false }
        // R102: pass both pre-built [UInt16] tables into editDistance so it
        // skips the per-call `Array(b.utf16)` materialization.
        let dist = editDistance(
            aCodeUnits: cachedSourceWordAlnumUtf16[srcIndex],
            bUtf16: bUtf16,
            maxDistance: tolerance
        )
        return dist <= tolerance
    }

    /// R102: same DP but:
    /// - Both sides now arrive as pre-built [UInt16] — the spoken side too
    ///   (caller-built once per ASR partial, looked up at each skip step).
    ///   Saves 1 allocation + 1 grapheme walk per call (was `Array(b.utf16)`).
    /// - DP row reused via `editDistanceDPBuffer` — grown on demand, reset
    ///   in place between calls. Saves the `Array(0...iCount)` allocation
    ///   that ran on every editDistance invocation (~12 calls/partial).
    /// - Sub-buffer accesses are inlined through `editDistanceDPBuffer`
    ///   directly rather than copied into a local `var dp` — Array COW
    ///   would otherwise re-allocate the row on the first subscript write.
    private func editDistance(aCodeUnits: [UInt16], bUtf16: [UInt16], maxDistance: Int) -> Int {
        let aCount = aCodeUnits.count
        let bCount = bUtf16.count
        if aCount == 0 { return bCount }
        if bCount == 0 { return aCount }
        let lenDiff = aCount - bCount
        if lenDiff > maxDistance || -lenDiff > maxDistance {
            return abs(lenDiff)
        }
        // Always iterate the shorter string on the outer loop to keep the
        // DP row small.
        let (oChars, iChars, oCount, iCount) = aCount <= bCount
            ? (aCodeUnits, bUtf16, aCount, bCount)
            : (bUtf16, aCodeUnits, bCount, aCount)
        // R102: grow-only scratch buffer. First call allocates; subsequent
        // calls reset the used prefix in place (≤ iCount+1 writes per call).
        let need = iCount + 1
        if editDistanceDPBuffer.count < need {
            editDistanceDPBuffer = Array(0..<need)
        } else {
            for j in 0..<need { editDistanceDPBuffer[j] = j }
        }
        for i in 1...oCount {
            var prev = editDistanceDPBuffer[0]
            editDistanceDPBuffer[0] = i
            let oc = oChars[i - 1]
            // Best possible score for the rest of this row is bounded by
            // abs(i - j) + remaining char differences. Use a diagonal cap.
            let rowBest = abs(i - iCount) // if all chars beyond match
            // Quick path: if every dp[j] already exceeds tolerance, bail.
            var rowMin = Int.max
            for j in 1...iCount {
                let temp = editDistanceDPBuffer[j]
                let cost = oc == iChars[j - 1] ? 0 : 1
                let v = min(prev + cost, editDistanceDPBuffer[j] + 1, editDistanceDPBuffer[j - 1] + 1)
                editDistanceDPBuffer[j] = v
                prev = temp
                if v < rowMin { rowMin = v }
            }
            if rowMin > maxDistance && rowBest > maxDistance {
                return rowMin
            }
        }
        return editDistanceDPBuffer[iCount]
    }

    // tailWords helper removed in R56 — tail3/tail5 now computed in
    // lastSpokenText.didSet so ASR partial handlers don't re-split.
}
