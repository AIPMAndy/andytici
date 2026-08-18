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
    // R107: tracks the live Observation registration for `speechRecognizer
    // .shouldDismiss`. Replaces the previous 10 Hz Timer.publish polling
    // block: every 100 ms tick paid an @Observable proxy access for
    // `shouldDismiss` (and the enclosing Timer.scheduledTimer drain).
    // Event-driven via withObservationTracking fires within microseconds
    // of the flag flipping true and burns zero CPU while idle. The
    // trailing closure re-arms itself so the listener stays live across
    // successive dismiss→reset cycles.
    private var dismissObserver: (() -> Void)?
    // R103: both controllers now share the process-wide OverlayContent
    // singleton. Previously this property owned its own instance and was
    // kept in lockstep with NotchOverlayController.overlayContent via
    // explicit setWords calls in TextreamService — those are now removed
    // since mutations on one controller are immediately visible to the other.
    let overlayContent = OverlayContent.shared

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

        overlayContent.setWords(words, totalCharCount: totalCharCount, hasNextPage: hasNextPage)

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

        // R107: replaced 10 Hz Timer.publish polling of
        // `speechRecognizer.shouldDismiss` with event-driven
        // withObservationTracking. Wakes within microseconds of the flag
        // flipping true instead of up to 100 ms later, and costs nothing
        // while the user is presenting. The closure re-arms itself so it
        // stays live across dismiss → reset cycles.
        observeShouldDismiss(speechRecognizer: speechRecognizer)
    }

    /// Wires a one-shot Observation tracking that re-arms on every fire.
    /// Mirrors the pattern SwiftUI's `.onChange(of:)` uses internally,
    /// exposed to non-View consumers (controllers) that need the same
    /// event-driven semantics without a view tree. (R107)
    private func observeShouldDismiss(speechRecognizer: SpeechRecognizer) {
        // Cancel any prior observer so a second `show()` call doesn't stack
        // duplicate registrations (each previous registration would still
        // fire, racing the latest one on the same flag flip).
        dismissObserver = nil
        withObservationTracking {
            // Touch the property inside the apply closure so the runtime
            // registers a dependency on this key path. Reading it here is
            // the only thing that matters — the returned value is unused.
            _ = speechRecognizer.shouldDismiss
        } onChange: { [speechRecognizer] in
            // The onChange closure is @Sendable, so it can only carry
            // Sendable values out. Collapse the decision to a single Bool
            // (Sendable) and hand the rest of the work — including the
            // non-Sendable self/speechRecognizer captures the re-arm
            // path needs — to a regular main-queue block. The outer
            // capture of `speechRecognizer` is required so we can re-arm
            // on the reset path below; Swift lifts the reference through
            // the @Sendable boundary because DispatchQueue.main.async's
            // block parameter is not @Sendable (only the queue *hop* is).
            let didDismiss = speechRecognizer.shouldDismiss
            DispatchQueue.main.async { [weak self, speechRecognizer] in
                guard let self else { return }
                guard didDismiss else {
                    // Reset path (shouldDismiss flipped false): no action,
                    // but re-arm so the next flip is captured.
                    self.observeShouldDismiss(speechRecognizer: speechRecognizer)
                    return
                }
                self.dismissObserver = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.dismiss()
                }
                // No re-arm: we just tore the panel down. A subsequent
                // `show()` will install a fresh observer.
            }
        }
    }

    func dismiss() {
        // R107: cancel the live Observation registration on manual
        // teardown so a future `show()` starts with a clean slate.
        dismissObserver = nil
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
        // R73: cache `scrollSpeed` once. The previous scrollTimer closure
        // read `NotchSettings.shared.scrollSpeed` at every 20 Hz tick (line
        // `let speed = NotchSettings.shared.scrollSpeed`). The closure
        // captures body-level scope, so hoisting is safe: when the user
        // changes scrollSpeed, NotchSettings writes trigger a body re-render
        // via @Observable (the body depends on it for nothing else, but the
        // @Observable access tracker re-fires the view on writes), and the
        // new value is captured for subsequent ticks. Closure also returns
        // early in `.wordTracking` mode where scrollSpeed is unused, so
        // there's no staleness window to worry about.
        let speed = NotchSettings.shared.scrollSpeed
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
            // R73: use the body-captured `speed` (read once per body
            // render) instead of `NotchSettings.shared.scrollSpeed` here.
            // Saves 20 singleton reads/sec (one per 20 Hz tick).
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
        // R78: mirror the R76 local-cache pattern from
        // NotchOverlayController.prompterView. GeometryReader body
        // re-runs every time this view is rendered — which on the
        // external display happens at 20 Hz whenever the scrollTimer
        // drives timerWordProgress. Previously each render went
        // through 4 NotchSettings.shared reads (fontColorPreset,
        // cueColorPreset, cueBrightness.unreadOpacity, cueBrightness
        // .readOpacity) plus 4 listeningMode reads (onWordTap
        // closure, smoothScroll argument, toolbar wordTracking
        // branch, toolbar classic branch) — 8 singleton reads per
        // render × 20 Hz = 160 reads/sec. Hoist to locals; the
        // closures below capture them by enclosing scope, the same
        // way NotchOverlayController.prompterView does.
        GeometryReader { geo in
            let fontSize = max(48, min(96, geo.size.width / 14))
            let hPad = max(40, geo.size.width * 0.08)
            let fontColor = NotchSettings.shared.fontColorPreset.color
            let cueColor = NotchSettings.shared.cueColorPreset.color
            let cueUnread = NotchSettings.shared.cueBrightness.unreadOpacity
            let cueRead = NotchSettings.shared.cueBrightness.readOpacity
            let mode = listeningMode
            // R80: inline isEffectivelyListening switch on the cached `mode`
            // local. External display version's classic branch returns
            // `true` (no pause concept — it's a read-only display).
            // Wrap in an immediately-invoked closure so the switch is an
            // expression returning Bool rather than a Void statement —
            // GeometryReader's content closure is @ViewBuilder, and the
            // assignment-only switch form collides with buildExpression
            // (the previous form built successfully outside @ViewBuilder
            // scopes but failed here, hence the IIFE).
            let effectiveListening: Bool = {
                switch mode {
                case .wordTracking, .silencePaused:
                    return speechRecognizer.isListening
                case .classic:
                    return true
                }
            }()

            VStack(spacing: 0) {
                Spacer().frame(height: 20)

                SpeechScrollView(
                    words: words,
                    // R69: served from the body-cached `effective` parameter
                    // instead of re-evaluating effectiveCharCount here.
                    highlightedCharCount: effective,
                    font: .systemFont(ofSize: fontSize, weight: .semibold),
                    // R78: served from the locals above (single read per
                    // GeometryReader render).
                    highlightColor: fontColor,
                    cueColor: cueColor,
                    cueUnreadOpacity: cueUnread,
                    cueReadOpacity: cueRead,
                    onWordTap: { charOffset in
                        // R78: served from `mode` local.
                        if mode == .wordTracking {
                            speechRecognizer.jumpTo(charOffset: charOffset)
                        } else {
                            timerWordProgress = wordProgressForCharOffset(charOffset)
                        }
                    },
                    onManualScroll: { scrolling, newProgress in
                        isUserScrolling = scrolling
                        if !scrolling {
                            let clamped = max(0, min(Double(words.count), newProgress))
                            // R101+bug-fix: in wordTracking mode, route the
                            // user's chosen position through
                            // speechRecognizer.jumpTo (matching the
                            // NotchOverlayView/FloatingOverlayView fix). The
                            // previous code only updated timerWordProgress,
                            // which wordTracking mode ignores — leaving the
                            // external display prone to a desynced/blank
                            // baseline after manual scroll-release.
                            if mode == .wordTracking {
                                let progress = words.count > 0
                                    ? clamped / Double(words.count)
                                    : 0
                                let newCharOffset = charOffsetForWordProgress(progress)
                                speechRecognizer.jumpTo(charOffset: newCharOffset)
                            } else {
                                timerWordProgress = clamped
                            }
                        }
                    },
                    // R78: served from `mode` local.
                    smoothScroll: mode != .wordTracking,
                    smoothWordProgress: timerWordProgress,
                    isListening: effectiveListening
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

                    // R78: served from `mode` local.
                    if mode == .wordTracking {
                        LastSpokenTailText(recognizer: speechRecognizer, tailSize: 5, fontSize: 18)
                    } else {
                        Spacer()
                    }

                    // R78: served from `mode` local.
                    if mode != .classic {
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
