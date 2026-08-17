//
//  ExternalDisplayController.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import SwiftUI
import Combine

class ExternalDisplayController {
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    let overlayContent = OverlayContent()

    /// Find the target external screen based on saved screen ID, or first non-main screen
    func targetScreen() -> NSScreen? {
        let settings = NotchSettings.shared
        let screens = NSScreen.screens.filter { $0 != NSScreen.main }
        guard !screens.isEmpty else { return nil }

        // Try to find saved screen
        if settings.externalScreenID != 0 {
            if let match = screens.first(where: { $0.displayID == settings.externalScreenID }) {
                return match
            }
        }
        return screens.first
    }

    func show(speechRecognizer: SpeechRecognizer, words: [String], totalCharCount: Int, hasNextPage: Bool = false) {
        let settings = NotchSettings.shared
        guard settings.externalDisplayMode != .off else { return }
        guard let screen = targetScreen() else { return }

        dismiss()

        overlayContent.words = words
        overlayContent.totalCharCount = totalCharCount
        overlayContent.hasNextPage = hasNextPage

        let mirrorAxis = settings.externalDisplayMode == .mirror ? settings.mirrorAxis : nil
        let screenFrame = screen.frame

        let content = ExternalDisplayView(
            content: overlayContent,
            speechRecognizer: speechRecognizer,
            mirrorAxis: mirrorAxis
        )

        let hostingView = NSHostingView(rootView: content)

        let panel = NSPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView
        panel.setFrame(screenFrame, display: true)
        panel.orderFront(nil)
        self.panel = panel

        // Poll for dismiss signal
        Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, speechRecognizer.shouldDismiss else { return }
                self.cancellables.removeAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.dismiss()
                }
            }
            .store(in: &cancellables)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        cancellables.removeAll()
    }
}

// MARK: - NSScreen extension to get display ID

extension NSScreen {
    var displayID: UInt32 {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 0
        }
        return screenNumber.uint32Value
    }

    var displayName: String {
        return localizedName
    }
}

// MARK: - External Display SwiftUI View

struct ExternalDisplayView: View {
    @Bindable var content: OverlayContent
    @Bindable var speechRecognizer: SpeechRecognizer
    let mirrorAxis: MirrorAxis?

    private var words: [String] { content.words }
    private var totalCharCount: Int { content.totalCharCount }
    private var hasNextPage: Bool { content.hasNextPage }

    // Timer-based scroll for classic & silence-paused modes
    @State private var timerWordProgress: Double = 0
    @State private var isUserScrolling: Bool = false
    private let scrollTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    // Cached word index (see WordIndexTable in MarqueeTextView.swift).
    @State private var wordIndex: WordIndexTable = WordIndexTable(words: [])
    @State private var lastIndexedPage: Int = -1

    private var listeningMode: ListeningMode {
        NotchSettings.shared.listeningMode
    }

    /// Convert fractional word index to char offset using cached word index.
    /// O(1) per call after a one-time O(N) build per page-change.
    private func charOffsetForWordProgress(_ progress: Double) -> Int {
        rebuildWordIndexIfNeeded()
        return wordIndex.charOffset(forProgress: progress)
    }

    /// Convert char offset back to fractional word index (for taps).
    /// O(log N) per call after a one-time O(N) build per page-change.
    private func wordProgressForCharOffset(_ charOffset: Int) -> Double {
        rebuildWordIndexIfNeeded()
        return wordIndex.wordProgress(forCharOffset: charOffset)
    }

    private func rebuildWordIndexIfNeeded() {
        let page = content.currentPageIndex
        if page != lastIndexedPage {
            wordIndex = WordIndexTable(words: words)
            lastIndexedPage = page
        }
    }

    private var effectiveCharCount: Int {
        switch listeningMode {
        case .wordTracking:
            return speechRecognizer.recognizedCharCount
        case .classic, .silencePaused:
            return charOffsetForWordProgress(timerWordProgress)
        }
    }

    var isDone: Bool {
        totalCharCount > 0 && effectiveCharCount >= totalCharCount
    }

    private var isEffectivelyListening: Bool {
        switch listeningMode {
        case .wordTracking, .silencePaused:
            return speechRecognizer.isListening
        case .classic:
            return true
        }
    }

    var body: some View {
        // R68: cache `effectiveCharCount` and `isDone` once per body render.
        // The previous body read `isDone` three times (the `if` branch, the
        // `.animation(value:)`, and the `.onChange(of:)`), and each `isDone`
        // access re-runs `effectiveCharCount`, which switches on
        // `listeningMode` and (for classic / silence-paused) walks the
        // WordIndexTable via `charOffsetForWordProgress`. Body re-renders
        // 20 Hz while scrollTimer drives `timerWordProgress`, so the original
        // code was evaluating `effectiveCharCount` ~60 times/sec from body
        // outer alone. The scrollTimer handler also read `isDone` (one more
        // per tick) — now served by the same local. PrompterView still
        // references `effectiveCharCount` directly, addressed separately.
        let effective = effectiveCharCount
        let done = totalCharCount > 0 && effective >= totalCharCount
        // R70: cache `listeningMode` once. The previous body read it three
        // times per render (the `if done && (...)` line, the .onChange
        // closure, and the scrollTimer closure). `listeningMode` resolves
        // to `NotchSettings.shared.listeningMode`, so each read goes through
        // the @Observable singleton's access tracker. Hoisting to a local
        // also lets the scrollTimer closure drop its own `let mode =
        // listeningMode` line and use the body-captured value directly —
        // closures capture enclosing scope. Net per body render: -2
        // singleton reads.
        let mode = listeningMode
        // R72: cache `showElapsedTime` once. The previous body read
        // `NotchSettings.shared.showElapsedTime` inside the .overlay
        // closure every render. Body re-renders at 20 Hz in classic / silence-
        // paused modes (scrollTimer drives timerWordProgress), so this was
        // 20 singleton reads/sec that the R68/R70 cache pattern had missed.
        // Hoisting also makes the body-local cache set complete: every
        // @Observable-backed read the body performs is now served from a
        // single local instead of going through the access tracker.
        let showElapsed = NotchSettings.shared.showElapsedTime
        return ZStack {
            Color.black.ignoresSafeArea()

            if done && (mode == .wordTracking || hasNextPage) {
                doneView
            } else {
                // R69: pass the body-cached `effective` (one effectiveCharCount
                // evaluation per body render — see R68) instead of letting
                // prompterView recompute it twice internally (once for
                // highlightedCharCount, once for the waveform progress
                // fraction). At 20 Hz body re-renders, that's 40 saved
                // effectiveCharCount calls/sec.
                prompterView(effective: effective)
            }
        }
        .overlay(alignment: .topTrailing) {
            // R72: served from the body-cached `showElapsed` local.
            if showElapsed {
                ElapsedTimeView(fontSize: 24)
                    .padding(.top, 20)
                    .padding(.trailing, 40)
            }
        }
        .scaleEffect(x: mirrorAxis?.scaleX ?? 1, y: mirrorAxis?.scaleY ?? 1)
        .animation(.easeInOut(duration: 0.5), value: done)
        .onChange(of: done) { _, d in
            if d && mode == .wordTracking {
                speechRecognizer.stop()
            }
        }
        .onReceive(scrollTimer) { _ in
            // R67: cache `listeningMode` once. The previous version read it
            // twice per 20 Hz tick (once in the guard, once in the switch) —
            // each read goes through `NotchSettings.shared`'s @Observable
            // access tracker. Hoisting to a local also lets us convert the
            // nested `if` in the .silencePaused branch to a `guard`,
            // removing one branch and one indent level. Net per tick:
            // -1 singleton read, -1 branch.
            // R70: use the body-captured `mode` (single source of truth for
            // this body render) instead of re-reading `listeningMode` here.
            guard mode != .wordTracking else { return }
            // R68: use cached `done` instead of recomputing `isDone` here.
            guard !done, !isUserScrolling else { return }
            let speed = NotchSettings.shared.scrollSpeed // words per second
            switch mode {
            case .classic:
                timerWordProgress += speed * 0.05
            case .silencePaused:
                guard speechRecognizer.isListening, speechRecognizer.isSpeaking else { return }
                timerWordProgress += speed * 0.05
            case .wordTracking:
                break
            }
        }
    }

    private func prompterView(effective: Int) -> some View {
        GeometryReader { geo in
            let fontSize = max(48, min(96, geo.size.width / 14))
            let hPad = max(40, geo.size.width * 0.08)

            VStack(spacing: 0) {
                Spacer().frame(height: 20)

                SpeechScrollView(
                    words: words,
                    // R69: served from the body-cached `effective` parameter
                    // instead of re-evaluating effectiveCharCount here.
                    highlightedCharCount: effective,
                    font: .systemFont(ofSize: fontSize, weight: .semibold),
                    highlightColor: NotchSettings.shared.fontColorPreset.color,
                    cueColor: NotchSettings.shared.cueColorPreset.color,
                    cueUnreadOpacity: NotchSettings.shared.cueBrightness.unreadOpacity,
                    cueReadOpacity: NotchSettings.shared.cueBrightness.readOpacity,
                    onWordTap: { charOffset in
                        if listeningMode == .wordTracking {
                            speechRecognizer.jumpTo(charOffset: charOffset)
                        } else {
                            timerWordProgress = wordProgressForCharOffset(charOffset)
                        }
                    },
                    onManualScroll: { scrolling, newProgress in
                        isUserScrolling = scrolling
                        if !scrolling {
                            timerWordProgress = max(0, min(Double(words.count), newProgress))
                        }
                    },
                    smoothScroll: listeningMode != .wordTracking,
                    smoothWordProgress: timerWordProgress,
                    isListening: isEffectivelyListening
                )
                .padding(.horizontal, hPad)

                Spacer().frame(height: 20)

                HStack(alignment: .center, spacing: 16) {
                    AudioWaveformProgressView_Observer(
                        recognizer: speechRecognizer,
                        // R69: served from the body-cached `effective` parameter.
                        progress: totalCharCount > 0
                            ? Double(effective) / Double(totalCharCount)
                            : 0
                    )
                    .frame(width: 240, height: 32)

                    if listeningMode == .wordTracking {
                        LastSpokenTailText(recognizer: speechRecognizer, tailSize: 5, fontSize: 18)
                    } else {
                        Spacer()
                    }

                    if listeningMode != .classic {
                        Button {
                            if speechRecognizer.isListening {
                                speechRecognizer.stop()
                            } else {
                                speechRecognizer.resume()
                            }
                        } label: {
                            Image(systemName: speechRecognizer.isListening ? "mic.fill" : "mic.slash.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(speechRecognizer.isListening ? .yellow.opacity(0.8) : .white.opacity(0.4))
                                .frame(width: 40, height: 40)
                                .background(.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, hPad)
                .padding(.bottom, 40)
            }
        }
    }

    private var doneView: some View {
        VStack(spacing: 12) {
            if hasNextPage {
                Button {
                    speechRecognizer.shouldAdvancePage = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 28, weight: .bold))
                        Text("下一页")
                            .font(.system(size: 28, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)
                Text("完成！")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .transition(.scale.combined(with: .opacity))
    }
}
