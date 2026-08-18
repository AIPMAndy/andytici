//
//  NotchOverlayController.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import SwiftUI
import Combine

@Observable
class NotchFrameTracker {
    var visibleHeight: CGFloat = 37 {
        didSet { updatePanel() }
    }
    var visibleWidth: CGFloat = 200 {
        didSet { updatePanel() }
    }
    weak var panel: NSPanel?
    var screenMidX: CGFloat = 0
    var screenMaxY: CGFloat = 0
    var menuBarHeight: CGFloat = 0

    func updatePanel() {
        guard let panel else { return }
        let x = screenMidX - visibleWidth / 2
        let y = screenMaxY - visibleHeight
        panel.setFrame(NSRect(x: x, y: y, width: visibleWidth, height: visibleHeight), display: false)
    }

    // R94: batched frame write. The per-property didSets above each call
    // updatePanel() independently, so writing both `visibleHeight` and
    // `visibleWidth` in sequence issues 2 WindowServer setFrame IPCs and
    // produces an intermediate (newHeight, oldWidth) frame that the
    // WindowServer never displays — pure waste. Callers that update both
    // axes at once (showPinned init, updateFrameTracker on every drag tick
    // 30-60 Hz) should use this entry point so we issue exactly one IPC
    // with the final combined state. The individual didSets stay so single-
    // property writers from any future caller still trigger a redraw.
    func applyFrame(height: CGFloat, width: CGFloat) {
        var changed = false
        if visibleHeight != height { visibleHeight = height; changed = true }
        if visibleWidth != width { visibleWidth = width; changed = true }
        if changed { updatePanel() }
    }
}

@Observable
class OverlayContent {
    var words: [String] = []
    var totalCharCount: Int = 0
    var hasNextPage: Bool = false
    /// R52: prefix-sum of char offsets for O(1) word-progress → char-offset
    /// lookups. `wordCharOffsets[i]` = sum of (words[0..<i].count + 1 each),
    /// so `wordCharOffsets[0] == 0` and `wordCharOffsets[words.count] ==
    /// totalCharCount`. Built once per page change; consumed by notch
    /// overlay views' `charOffsetForWordProgress` (was O(N) per call, now
    /// O(1)).
    var wordCharOffsets: [Int] = []

    // Page picker
    var pageCount: Int = 1
    var currentPageIndex: Int = 0
    var pagePreviews: [String] = []
    var showPagePicker: Bool = false
    var jumpToPageIndex: Int? = nil

    /// R52: single entry point for updating words + totalCharCount so the
    /// prefix sum stays in sync. Always use this instead of assigning
    /// `words` and `totalCharCount` independently — otherwise the prefix
    /// sum drifts and the O(1) charOffsetForWordProgress returns wrong values.
    func setWords(_ newWords: [String], totalCharCount: Int) {
        self.words = newWords
        self.totalCharCount = totalCharCount
        var offsets = [Int](repeating: 0, count: newWords.count + 1)
        for i in 0..<newWords.count {
            offsets[i + 1] = offsets[i] + newWords[i].count + 1 // +1 for space
        }
        self.wordCharOffsets = offsets
    }
}

// R93: file-level Color cache for hot-path overlay literals. Both
// prompterView and floatingPrompterView re-render at 20 Hz in
// classic/silencePaused modes; previously each render allocated
// ~19 fresh Color structs via .opacity() calls. Top-level file
// lets are lazily initialized once per process, then reused for
// every render across NotchOverlayView, FloatingOverlayView, and
// NotchOverlayController alike — zero per-render Color alloc.
// (Class-level static lets can't work here because the views that
// use these colors are separate types; `Self.` would resolve to the
// enclosing struct, not the controller.)
private let white60 = Color.white.opacity(0.6)
private let white15 = Color.white.opacity(0.15)
private let white80 = Color.white.opacity(0.8)
private let white50 = Color.white.opacity(0.5)
private let white30 = Color.white.opacity(0.3)
private let white25 = Color.white.opacity(0.25)
private let yellow80 = Color.yellow.opacity(0.8)
private let yellow70 = Color.yellow.opacity(0.7)
private let yellow10 = Color.yellow.opacity(0.1)
private let white05 = Color.white.opacity(0.05)
private let red90 = Color.red.opacity(0.9)

class NotchOverlayController: NSObject {
    private let cursorOffset: CGFloat = 8
    private let screenEdgeMargin: CGFloat = 5
    // R85: longest overlay dismiss animation span. NotchOverlayView exit runs
    // 0.15s content fade + 0.1s wait + 0.3s shrink (phase 2 ends at 0.4s).
    // The teardown timer must fire AFTER the visual animation completes,
    // otherwise orderOut(nil) freezes SwiftUI mid-frame and the panel pops
    // out instead of shrinking smoothly. 0.6s gives a 200 ms buffer past
    // the last animation tick.
    private let dismissTeardownDelay: TimeInterval = 0.6
    private var panel: NSPanel?
    let speechRecognizer = SpeechRecognizer()
    let overlayContent = OverlayContent()
    var onComplete: (() -> Void)?
    var onNextPage: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()
    private var isDismissing = false
    private var frameTracker: NotchFrameTracker?
    private var mouseTrackingTimer: AnyCancellable?
    private var cursorTrackingTimer: AnyCancellable?
    private var currentScreenID: UInt32 = 0
    // R71: cache the last frame we set via panel.setFrame in cursor-follow
    // mode. cursorTrackingTimer runs at 60 Hz; while the mouse is idle the
    // computed frame is byte-identical to the previous tick, but setFrame
    // still triggers a WindowServer roundtrip (~1 ms). Skipping the
    // roundtrip on unchanged frames is invisible to the user and saves
    // up to ~60 ms/sec of WindowServer time when the speaker pauses.
    private var lastCursorFrame: NSRect?
    // R95: dedup one step earlier than lastCursorFrame. cursorTrackingTimer
    // runs at 60 Hz; the R71 frame guard catches unchanged `setFrame` calls
    // but the scan + math + panel.frame.size read on the prior lines still
    // run. When the cursor is stationary (the dominant state of cursor-
    // follow mode between spoken phrases), the mouse position is the only
    // input to `cursorFollowingFrame` — if it hasn't moved, the frame can't
    // have changed. Catching it here skips NSEvent.mouseLocation propagation
    // through screenUnderMouse, cursorFollowingFrame math, and a Cocoa
    // panel.frame.size read per tick.
    private var lastMouseLocation: CGPoint?
    private var stopButtonPanel: NSPanel?
    private var escMonitor: Any?

    func show(
        text: String,
        words: [String]? = nil,
        totalCharCount: Int? = nil,
        hasNextPage: Bool = false,
        onComplete: (() -> Void)? = nil
    ) {
        self.onComplete = onComplete
        self.onNextPage = {
            TextreamService.shared.advanceToNextPage()
        }
        self.isDismissing = false
        forceClose()
        observeDismiss()

        // Populate overlay content. Callers (TextreamService) may pass already-
        // computed words/totalCharCount to avoid the O(N) splitTextIntoWords
        // + O(N) reduce running 3× in sequence (overlay, ext display, browser).
        let normalized = words ?? splitTextIntoWords(text)
        let resolvedTotal = totalCharCount ?? (normalized.reduce(0) { $0 + $1.count } + max(0, normalized.count - 1))
        // R52: route both `words` and `totalCharCount` through OverlayContent.setWords
        // so the prefix sum stays in sync (used by O(1) charOffsetForWordProgress).
        overlayContent.setWords(normalized, totalCharCount: resolvedTotal)
        overlayContent.hasNextPage = hasNextPage

        let settings = NotchSettings.shared

        let screen: NSScreen
        switch settings.notchDisplayMode {
        case .followMouse:
            screen = screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens[0]
        case .fixedDisplay:
            screen = NSScreen.screens.first(where: { $0.displayID == settings.pinnedScreenID }) ?? NSScreen.main ?? NSScreen.screens[0]
        }

        let screenFrame = screen.frame

        if settings.overlayMode == .fullscreen {
            let fsScreen: NSScreen
            if settings.fullscreenScreenID != 0,
               let match = NSScreen.screens.first(where: { $0.displayID == settings.fullscreenScreenID }) {
                fsScreen = match
            } else {
                fsScreen = screen
            }
            showFullscreen(settings: settings, screen: fsScreen)
        } else if settings.overlayMode == .floating && settings.followCursorWhenUndocked {
            showFollowCursor(settings: settings, screen: screen)
        } else {
            switch settings.overlayMode {
            case .pinned:
                showPinned(settings: settings, screen: screen)
            case .floating:
                showFloating(settings: settings, screenFrame: screenFrame)
            case .fullscreen:
                break // handled above
            }
        }

        // Show floating stop button only in follow-cursor mode (panel ignores mouse events)
        if settings.overlayMode == .floating && settings.followCursorWhenUndocked {
            showStopButton(on: screen)
        }

        // Word tracking & silence-paused need the microphone; classic does not
        if settings.listeningMode != .classic {
            speechRecognizer.start(with: text)
        }
    }

    func updateContent(text: String, hasNextPage: Bool) {
        let normalized = splitTextIntoWords(text)

        // Fully reset speech state for new page
        speechRecognizer.recognizedCharCount = 0
        speechRecognizer.shouldDismiss = false
        speechRecognizer.shouldAdvancePage = false
        speechRecognizer.lastSpokenText = ""

        overlayContent.words = normalized
        overlayContent.totalCharCount = normalized.joined(separator: " ").count
        // R52: keep prefix sum in sync with the new words list (init from
        // totalCharCount-derivation; the old `totalCharCount` was joined-
        // separator-count which is consistent).
        var prefix = [Int](repeating: 0, count: normalized.count + 1)
        for i in 0..<normalized.count {
            prefix[i + 1] = prefix[i] + normalized[i].count + 1
        }
        overlayContent.wordCharOffsets = prefix
        overlayContent.hasNextPage = hasNextPage

        let settings = NotchSettings.shared
        if settings.listeningMode != .classic {
            speechRecognizer.start(with: text)
        }
    }

    private func screenUnderMouse() -> NSScreen? {
        screenUnderMouse(mouseLocation: NSEvent.mouseLocation)
    }

    // R59: callers that have already read NSEvent.mouseLocation pass the value
    // through here so we don't trigger a second Cocoa mouseLocation lookup on
    // the same tick. updateCursorPosition runs at 30Hz during cursor-follow;
    // before this change it called NSEvent.mouseLocation twice per tick
    // (once explicitly, once inside screenUnderMouse) and ran the
    // NSScreen.screens.first(where:) scan twice as well.
    private func screenUnderMouse(mouseLocation: NSPoint) -> NSScreen? {
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
    }

    private func startMouseTracking() {
        mouseTrackingTimer?.cancel()
        mouseTrackingTimer = Timer.publish(every: 0.3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkMouseScreen()
            }
    }

    private func stopMouseTracking() {
        mouseTrackingTimer?.cancel()
        mouseTrackingTimer = nil
    }

    private func startCursorTracking() {
        cursorTrackingTimer?.cancel()
        cursorTrackingTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateCursorPosition()
            }
    }

    private func stopCursorTracking() {
        cursorTrackingTimer?.cancel()
        cursorTrackingTimer = nil
    }

    private func updateCursorPosition() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        // R95: early-return when the mouse hasn't moved since the previous
        // tick. CGPoint.== is 2 CGFloat compares (~ns). The R71 lastCursorFrame
        // guard remains as a defensive second gate for the case where panel
        // size or screen layout changed for unrelated reasons.
        if let prev = lastMouseLocation, prev == mouse { return }
        lastMouseLocation = mouse
        // R59: reuse the mouse location we just read instead of letting
        // screenUnderMouse() trigger another NSEvent.mouseLocation call +
        // NSScreen.screens scan on the same 60Hz tick.
        guard let screen = screenUnderMouse(mouseLocation: mouse) ?? panel.screen ?? NSScreen.main else { return }
        let frame = cursorFollowingFrame(mouse: mouse, panelSize: panel.frame.size, screen: screen)
        // R71: skip the WindowServer roundtrip when the frame is unchanged
        // from the previous tick. NSRect.== is 4 CGFloat compares (~5 ns) —
        // far cheaper than a setFrame IPC. Cache invalidates naturally when
        // mouse, panel size, or screen changes.
        if let prev = lastCursorFrame, prev == frame { return }
        lastCursorFrame = frame
        panel.setFrame(frame, display: false)
    }

    private func cursorFollowingFrame(mouse: NSPoint, panelSize: NSSize, screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame

        let minimumX = screenFrame.minX + screenEdgeMargin
        let maximumX = max(minimumX, screenFrame.maxX - panelSize.width - screenEdgeMargin)
        let x = min(max(mouse.x + cursorOffset, minimumX), maximumX)

        let minimumY = screenFrame.minY + screenEdgeMargin
        let maximumY = max(minimumY, screen.visibleFrame.maxY - panelSize.height)
        let y = min(max(mouse.y - panelSize.height, minimumY), maximumY)

        return NSRect(origin: NSPoint(x: x, y: y), size: panelSize)
    }

    private func checkMouseScreen() {
        guard let panel, let frameTracker else { return }
        guard let mouseScreen = screenUnderMouse() else { return }
        let mouseScreenID = mouseScreen.displayID
        guard mouseScreenID != currentScreenID else { return }

        // Mouse moved to a different screen — reposition the notch
        // Keep the same panel dimensions since the SwiftUI view's menuBarHeight is fixed
        currentScreenID = mouseScreenID
        let screenFrame = mouseScreen.frame

        frameTracker.screenMidX = screenFrame.midX
        frameTracker.screenMaxY = screenFrame.maxY

        let w = frameTracker.visibleWidth
        let h = frameTracker.visibleHeight
        let x = screenFrame.midX - w / 2
        let y = screenFrame.maxY - h
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    private func showPinned(settings: NotchSettings, screen: NSScreen) {
        let notchWidth = settings.notchWidth
        let textAreaHeight = settings.textAreaHeight
        let maxExtraHeight: CGFloat = 350
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame

        // Menu bar / notch height from top of screen
        let menuBarHeight = screenFrame.maxY - visibleFrame.maxY

        let tracker = NotchFrameTracker()
        tracker.screenMidX = screenFrame.midX
        tracker.screenMaxY = screenFrame.maxY
        tracker.menuBarHeight = menuBarHeight
        // Set full expanded dimensions so mouse tracking uses the correct size.
        // R94: batched single IPC instead of two (visibleHeight then visibleWidth
        // didSets would each call updatePanel independently).
        tracker.applyFrame(
            height: menuBarHeight + textAreaHeight,
            width: notchWidth
        )
        self.frameTracker = tracker
        self.currentScreenID = screen.displayID

        let overlayView = NotchOverlayView(content: overlayContent, speechRecognizer: speechRecognizer, menuBarHeight: menuBarHeight, baseTextHeight: textAreaHeight, maxExtraHeight: maxExtraHeight, frameTracker: tracker)
        let contentView = NSHostingView(rootView: overlayView)

        // Start panel at full target size (SwiftUI animates the notch shape inside)
        let targetHeight = menuBarHeight + textAreaHeight
        let targetY = screenFrame.maxY - targetHeight
        let xPosition = screenFrame.midX - notchWidth / 2
        let panel = NSPanel(
            contentRect: NSRect(x: xPosition, y: targetY, width: notchWidth, height: targetHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        tracker.panel = panel

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false
        panel.sharingType = NotchSettings.shared.hideFromScreenShare ? .none : .readOnly
        panel.contentView = contentView

        panel.orderFrontRegardless()
        self.panel = panel

        // Start mouse tracking for follow-mouse mode
        if settings.notchDisplayMode == .followMouse {
            startMouseTracking()
        }

        installKeyMonitor()
    }

    private func showFollowCursor(settings: NotchSettings, screen: NSScreen) {
        let panelWidth = settings.notchWidth
        let panelHeight = settings.textAreaHeight

        let mouse = NSEvent.mouseLocation
        let cursorScreen = screenUnderMouse() ?? screen
        let initialFrame = cursorFollowingFrame(
            mouse: mouse,
            panelSize: NSSize(width: panelWidth, height: panelHeight),
            screen: cursorScreen
        )

        let floatingView = FloatingOverlayView(
            content: overlayContent,
            speechRecognizer: speechRecognizer,
            baseHeight: panelHeight,
            followingCursor: true
        )
        let contentView = NSHostingView(rootView: floatingView)

        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.sharingType = NotchSettings.shared.hideFromScreenShare ? .none : .readOnly
        panel.contentView = contentView

        panel.orderFrontRegardless()
        self.panel = panel

        startCursorTracking()
        installKeyMonitor()
    }

    private func showFullscreen(settings: NotchSettings, screen: NSScreen) {
        let screenFrame = screen.frame

        let fullscreenView = ExternalDisplayView(
            content: overlayContent,
            speechRecognizer: speechRecognizer,
            mirrorAxis: nil
        )
        let contentView = NSHostingView(rootView: fullscreenView)

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
        panel.ignoresMouseEvents = false
        panel.sharingType = settings.hideFromScreenShare ? .none : .readOnly
        panel.contentView = contentView
        panel.setFrame(screenFrame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        installKeyMonitor()
    }

    private func showFloating(settings: NotchSettings, screenFrame: CGRect) {
        let panelWidth = settings.notchWidth
        let panelHeight = settings.textAreaHeight

        let xPosition = screenFrame.midX - panelWidth / 2
        let yPosition = screenFrame.midY - panelHeight / 2 + 100

        let floatingView = FloatingOverlayView(
            content: overlayContent,
            speechRecognizer: speechRecognizer,
            baseHeight: panelHeight
        )
        let contentView = NSHostingView(rootView: floatingView)

        let panel = NSPanel(
            contentRect: NSRect(x: xPosition, y: yPosition, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 280, height: panelHeight)
        panel.maxSize = NSSize(width: 500, height: panelHeight + 350)
        panel.sharingType = NotchSettings.shared.hideFromScreenShare ? .none : .readOnly
        panel.contentView = contentView

        panel.orderFrontRegardless()
        self.panel = panel

        installKeyMonitor()
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true

        // Trigger the shrink animation
        speechRecognizer.shouldDismiss = true
        speechRecognizer.forceStop()

        // Wait for animation, then remove panel
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissTeardownDelay) { [weak self] in
            guard let self else { return }
            self.stopMouseTracking()
            self.stopCursorTracking()
            self.removeStopButton()
            self.removeEscMonitor()
            self.cancellables.removeAll()
            self.panel?.orderOut(nil)
            self.panel = nil
            self.frameTracker = nil
            self.speechRecognizer.shouldDismiss = false
            self.isDismissing = false
            self.onComplete?()
        }
    }

    private func installKeyMonitor() {
        removeEscMonitor()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // ESC
                if self.overlayContent.showPagePicker {
                    self.overlayContent.showPagePicker = false
                    return nil
                }
                self.dismiss()
                return nil
            }
            return event
        }
    }

    private func forceClose() {
        stopMouseTracking()
        stopCursorTracking()
        removeStopButton()
        removeEscMonitor()
        cancellables.removeAll()
        speechRecognizer.forceStop()
        speechRecognizer.recognizedCharCount = 0
        panel?.orderOut(nil)
        panel = nil
        frameTracker = nil
        speechRecognizer.shouldDismiss = false
        speechRecognizer.shouldAdvancePage = false
    }

    private func observeDismiss() {
        // Single timer polls all conditions instead of two separate timers
        Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }

                // Check for page advance
                if self.speechRecognizer.shouldAdvancePage {
                    self.speechRecognizer.shouldAdvancePage = false
                    self.onNextPage?()
                }

                // Check for page jump from page picker
                if let targetIndex = self.overlayContent.jumpToPageIndex {
                    self.overlayContent.jumpToPageIndex = nil
                    TextreamService.shared.jumpToPage(index: targetIndex)
                }

                // Check for dismiss
                if self.speechRecognizer.shouldDismiss, !self.isDismissing {
                    self.isDismissing = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + dismissTeardownDelay) { [weak self] in
                        guard let self else { return }
                        self.stopMouseTracking()
                        self.stopCursorTracking()
                        self.removeStopButton()
                        self.removeEscMonitor()
                        self.cancellables.removeAll()
                        self.panel?.orderOut(nil)
                        self.panel = nil
                        self.frameTracker = nil
                        self.speechRecognizer.shouldDismiss = false
                        self.onComplete?()
                    }
                }
            }
            .store(in: &cancellables)
    }

    var isShowing: Bool {
        panel != nil
    }

    // MARK: - Floating Stop Button

    private func showStopButton(on screen: NSScreen) {
        guard stopButtonPanel == nil else { return }

        let buttonSize: CGFloat = 36
        let margin: CGFloat = 8
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarBottom = visibleFrame.maxY
        let x = screenFrame.midX - buttonSize / 2
        let y = menuBarBottom - buttonSize - margin

        let stopView = NSHostingView(rootView: StopButtonView {
            self.dismiss()
        })

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.sharingType = .none
        panel.contentView = stopView
        panel.orderFrontRegardless()
        stopButtonPanel = panel
    }

    private func removeStopButton() {
        stopButtonPanel?.orderOut(nil)
        stopButtonPanel = nil
    }

    private func removeEscMonitor() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
        }
        escMonitor = nil
    }
}

// MARK: - Floating Stop Button View

struct StopButtonView: View {
    let onStop: () -> Void

    var body: some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.red.opacity(0.85))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Notch Blur View (for transparency mode)

struct NotchBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.material = .hudWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Dynamic Island Shape (concave top corners, convex bottom corners)

struct DynamicIslandShape: Shape {
    var topInset: CGFloat = 16
    var bottomRadius: CGFloat = 18

    // Enable smooth animation by providing animatable data
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topInset, bottomRadius) }
        set {
            topInset = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let t = topInset
        let br = bottomRadius
        var p = Path()

        // Start at top-left corner
        p.move(to: CGPoint(x: 0, y: 0))

        // Top-left curve: from (0,0) curve down-right to (t, t)
        // Control at (t, 0) makes it bow DOWNWARD (like DynamicNotchKit)
        p.addQuadCurve(
            to: CGPoint(x: t, y: t),
            control: CGPoint(x: t, y: 0)
        )

        // Left edge down
        p.addLine(to: CGPoint(x: t, y: h - br))

        // Bottom-left convex corner
        p.addQuadCurve(
            to: CGPoint(x: t + br, y: h),
            control: CGPoint(x: t, y: h)
        )

        // Bottom edge
        p.addLine(to: CGPoint(x: w - t - br, y: h))

        // Bottom-right convex corner
        p.addQuadCurve(
            to: CGPoint(x: w - t, y: h - br),
            control: CGPoint(x: w - t, y: h)
        )

        // Right edge up
        p.addLine(to: CGPoint(x: w - t, y: t))

        // Top-right curve: from (w-t, t) curve up-right to (w, 0)
        // Control at (w-t, 0) makes it bow DOWNWARD
        p.addQuadCurve(
            to: CGPoint(x: w, y: 0),
            control: CGPoint(x: w - t, y: 0)
        )

        // Top edge back to start
        p.closeSubpath()
        return p
    }
}

// MARK: - Overlay SwiftUI View

struct NotchOverlayView: View {
    @Bindable var content: OverlayContent
    @Bindable var speechRecognizer: SpeechRecognizer
    let menuBarHeight: CGFloat
    let baseTextHeight: CGFloat
    let maxExtraHeight: CGFloat
    var frameTracker: NotchFrameTracker

    private var words: [String] { content.words }
    private var totalCharCount: Int { content.totalCharCount }
    private var hasNextPage: Bool { content.hasNextPage }

    // Animation state - 0.0 = notch size, 1.0 = full size
    @State private var expansion: CGFloat = 0
    @State private var contentVisible = false
    @State private var extraHeight: CGFloat = 0
    @State private var dragStartHeight: CGFloat = -1
    @State private var isHovering: Bool = false

    // Timer-based scroll for classic & silence-paused modes
    @State private var timerWordProgress: Double = 0
    @State private var isPaused: Bool = false
    @State private var isUserScrolling: Bool = false
    // R50: throttled from 20Hz → 10Hz. 50 ms is overkill for scroll-position
    // updates (eye perceives ~24Hz+ as smooth); 100 ms is indistinguishable
    // but cuts body re-runs for NotchOverlayView in half in classic mode.
    private let scrollTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    // Auto next page countdown
    @State private var countdownRemaining: Int = 0
    @State private var countdownTimer: Timer? = nil

    private let topInset: CGFloat = 16
    private let collapsedInset: CGFloat = 8

    // macOS notch dimensions (approximate)
    private let notchHeight: CGFloat = 37
    private let notchWidth: CGFloat = 200  // Hardware notch is ~200px wide

    private var listeningMode: ListeningMode {
        NotchSettings.shared.listeningMode
    }

    /// Convert fractional word index to char offset using actual word lengths.
    /// R52: now O(1) via prefix sum (`content.wordCharOffsets`) instead of an
    /// O(N) loop over `words`. content is shared OverlayContent; the prefix
    /// sum is rebuilt on every page change. As a safety fallback, if the
    /// prefix sum is somehow missing we fall back to the legacy O(N) walk.
    private func charOffsetForWordProgress(_ progress: Double) -> Int {
        let offsets = content.wordCharOffsets
        if offsets.count == words.count + 1, !words.isEmpty {
            let whole = max(0, min(Int(progress), words.count))
            let frac = progress - Double(whole)
            let base = offsets[whole]
            let added = Int(Double(words[whole].count) * frac)
            return min(base + added, totalCharCount)
        }
        // Fallback: legacy O(N) path (never expected to run in production,
        // but keeps the function total if the prefix sum is missing).
        let wholeWord = Int(progress)
        let frac = progress - Double(wholeWord)
        var offset = 0
        for i in 0..<min(wholeWord, words.count) {
            offset += words[i].count + 1 // +1 for space
        }
        if wholeWord < words.count {
            offset += Int(Double(words[wholeWord].count) * frac)
        }
        return min(offset, totalCharCount)
    }

    /// Convert char offset back to fractional word index (for taps)
    private func wordProgressForCharOffset(_ charOffset: Int) -> Double {
        var offset = 0
        for (i, word) in words.enumerated() {
            let end = offset + word.count
            if charOffset <= end {
                let frac = Double(charOffset - offset) / Double(max(1, word.count))
                return Double(i) + frac
            }
            offset = end + 1
        }
        return Double(words.count)
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

    // Interpolated values based on expansion
    private var currentTopInset: CGFloat {
        collapsedInset + (topInset - collapsedInset) * expansion
    }

    private var currentBottomRadius: CGFloat {
        8 + (18 - 8) * expansion
    }

    var body: some View {
        // R74: cache all NotchSettings.shared singletons + listeningMode +
        // isDone at body outer. The previous body (lines 803-937 before this
        // edit) read NotchSettings.shared.* inline (overlayTransparency,
        // overlayTransparencyOpacity, showElapsedTime, autoNextPage,
        // scrollSpeed) and listeningMode 4+ times (each read goes through
        // the @Observable singleton tracker via the `listeningMode` computed
        // property at line 736). Body re-renders at 20 Hz in classic /
        // silencePaused modes (scrollTimer drives timerWordProgress), so
        // this was 200+ singleton reads/sec from one body. Hoisting to body
        // outer lets every inner closure (GeometryReader, scrollTimer,
        // onChange) reuse the same captured values via Swift's enclosing-
        // scope capture rule.
        let mode = listeningMode
        let done = isDone
        let speed = NotchSettings.shared.scrollSpeed
        let showElapsed = NotchSettings.shared.showElapsedTime
        let autoNext = NotchSettings.shared.autoNextPage
        let isTransparent = NotchSettings.shared.overlayTransparency
        let transparencyOpacity = NotchSettings.shared.overlayTransparencyOpacity
        return GeometryReader { geo in
            let targetHeight = menuBarHeight + baseTextHeight + extraHeight
            let currentHeight = notchHeight + (targetHeight - notchHeight) * expansion
            let currentWidth = notchWidth + (geo.size.width - notchWidth) * expansion

            ZStack(alignment: .top) {
                // Container shape — solid black or transparent with blur
                // R74: served from body-cached `isTransparent` and
                // `transparencyOpacity`. The previous GeometryReader
                // closure re-read NotchSettings.shared.* inline; the body-
                // level cache removes those reads (they now happen once per
                // body render, not once per GeometryReader re-evaluation).
                if isTransparent {
                    // Blurred background layer clipped to the Dynamic Island shape
                    NotchBlurView()
                        .clipShape(DynamicIslandShape(
                            topInset: currentTopInset,
                            bottomRadius: currentBottomRadius
                        ))
                        .frame(width: currentWidth, height: currentHeight)

                    // Dark tint overlay so text remains readable
                    DynamicIslandShape(
                        topInset: currentTopInset,
                        bottomRadius: currentBottomRadius
                    )
                    .fill(.black.opacity(1.0 - transparencyOpacity))
                    .frame(width: currentWidth, height: currentHeight)
                } else {
                    DynamicIslandShape(
                        topInset: currentTopInset,
                        bottomRadius: currentBottomRadius
                    )
                    .fill(.black)
                    .frame(width: currentWidth, height: currentHeight)
                }

                // Content - appears after container expands
                if contentVisible {
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            // R74: served from body-cached `showElapsed`.
                            if showElapsed {
                                ElapsedTimeView(fontSize: 11)
                                    .padding(.trailing, 12)
                            }
                        }
                        .frame(height: menuBarHeight)

                        if content.showPagePicker {
                            pagePickerView
                        // R74: served from body-cached `mode` and `done`.
                        } else if done && (mode == .wordTracking || hasNextPage) {
                            doneView
                        } else {
                            prompterView
                        }
                    }
                    .padding(.horizontal, topInset)
                    .frame(width: currentWidth, height: targetHeight)
                    .clipped()
                    .transition(.opacity)
                }
            }
            .frame(width: currentWidth, height: currentHeight, alignment: .top)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .onChange(of: extraHeight) { _, _ in updateFrameTracker() }
        .onAppear {
            // Phase 1: Expand container with smooth easing
            withAnimation(.easeOut(duration: 0.4)) {
                expansion = 1
            }
            // Phase 2: Show content after container expands
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.easeOut(duration: 0.25)) {
                    contentVisible = true
                }
            }
        }
        .onChange(of: speechRecognizer.shouldDismiss) { _, shouldDismiss in
            if shouldDismiss {
                // Reverse: hide content first, then shrink container
                withAnimation(.easeIn(duration: 0.15)) {
                    contentVisible = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.easeIn(duration: 0.3)) {
                        expansion = 0
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.5), value: done)
        // R74: served from body-cached `done`, `mode`, `autoNext` via the
        // enclosing-scope capture rule. `.onChange(of: isDone)` fires on the
        // @Observable change; `done` is the body-render-captured value at
        // that moment. The closure also captures `mode` and `autoNext` from
        // body-level lets.
        .onChange(of: isDone) { _, d in
            if d {
                // In word tracking mode, stop listening when page is done
                if mode == .wordTracking {
                    speechRecognizer.stop()
                }
                if !hasNextPage {
                    // Only auto-dismiss in word tracking mode.
                    // In classic/silence-paused modes the speaker may still be
                    // talking after the auto-scroll finishes, so keep the text
                    // visible and let them dismiss manually (X button or Esc).
                    if mode == .wordTracking {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            speechRecognizer.shouldDismiss = true
                        }
                    }
                } else if autoNext {
                    startCountdown()
                }
            } else {
                cancelCountdown()
            }
        }
        // R74: scrollTimer closure (20 Hz in active scroll modes) now
        // captures `mode`, `done`, and `speed` from body outer — saves 3
        // singleton reads per tick. Previously read `isDone`, `listeningMode`,
        // and `NotchSettings.shared.scrollSpeed` inline at each tick.
        .onReceive(scrollTimer) { _ in
            guard !done, !isUserScrolling else { return }
            switch mode {
            case .classic:
                if !isPaused {
                    timerWordProgress += speed * 0.1
                }
            case .silencePaused:
                if !isPaused && speechRecognizer.isListening && speechRecognizer.isSpeaking {
                    timerWordProgress += speed * 0.1
                }
            case .wordTracking:
                break
            }
        }
        .onChange(of: content.totalCharCount) { _, _ in
            timerWordProgress = 0
        }
    }

    private func updateFrameTracker() {
        let targetHeight = menuBarHeight + baseTextHeight + extraHeight
        let fullWidth = NotchSettings.shared.notchWidth
        // R94: single IPC instead of two via per-property didSets. Drag tick
        // 30-60 Hz → halves WindowServer setFrame roundtrips per tick.
        frameTracker.applyFrame(height: targetHeight, width: fullWidth)
    }

    private var isEffectivelyListening: Bool {
        switch listeningMode {
        case .wordTracking, .silencePaused:
            return speechRecognizer.isListening
        case .classic:
            return !isPaused
        }
    }

    private var prompterView: some View {
        // R76: cache effectiveCharCount + listeningMode + 5 NotchSettings
        // reads at the top of this computed property. Previous body read
        // effectiveCharCount twice (highlightedCharCount + progress fraction),
        // listeningMode 4 times (onWordTap, smoothScroll, word-tracking text,
        // classic pause button), and 5 NotchSettings.shared singletons inline.
        // Body re-renders at 20 Hz in classic / silencePaused modes (scrollTimer
        // drives timerWordProgress), so prompterView was evaluating ~11 inline
        // reads per render × 20 Hz = ~220 reads/sec from this property alone.
        // Hoisting to locals deduplicates within the property's evaluation
        // scope — saves 7 reads per render × 20 Hz = ~140 reads/sec, plus 1
        // fewer effectiveCharCount call per render (it was called twice).
        let effective = effectiveCharCount
        let font = NotchSettings.shared.font
        let highlightColor = NotchSettings.shared.fontColorPreset.color
        let cueColor = NotchSettings.shared.cueColorPreset.color
        let cueUnread = NotchSettings.shared.cueBrightness.unreadOpacity
        let cueRead = NotchSettings.shared.cueBrightness.readOpacity
        let mode = listeningMode
        // R80: compute isEffectivelyListening inline using the cached `mode`
        // local. The previous call (`isListening: isEffectivelyListening`)
        // routed through a computed property that re-read
        // `NotchSettings.shared.listeningMode` (a 2nd singleton read after
        // the cached `mode` above) and then dispatched on it. Inlining the
        // switch uses the cached `mode` and re-reads only `isPaused` /
        // `speechRecognizer.isListening` (the genuinely dynamic inputs).
        // Saves 1 singleton read per render × 20 Hz = 20 reads/sec on this
        // prompterView; same fix on the other two prompterViews triples it.
        let effectiveListening: Bool
        switch mode {
        case .wordTracking, .silencePaused:
            effectiveListening = speechRecognizer.isListening
        case .classic:
            effectiveListening = !isPaused
        }
        return VStack(spacing: 0) {
            SpeechScrollView(
                words: words,
                highlightedCharCount: effective,
                font: font,
                highlightColor: highlightColor,
                cueColor: cueColor,
                cueUnreadOpacity: cueUnread,
                cueReadOpacity: cueRead,
                onWordTap: { charOffset in
                    if mode == .wordTracking {
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
                smoothScroll: mode != .wordTracking,
                smoothWordProgress: timerWordProgress,
                isListening: effectiveListening
            )
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))

            Group {
            HStack(alignment: .center, spacing: 8) {
                AudioWaveformProgressView(
                    levels: speechRecognizer.audioLevels,
                    progress: totalCharCount > 0 ? Double(effective) / Double(totalCharCount) : 0
                )
                .frame(width: 80, height: 24)
                .clipped()

                if let error = speechRecognizer.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(red90)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(error)
                } else if mode == .wordTracking {
                    // R83: use LastSpokenTailText wrapper instead of reading
                    // `speechRecognizer.lastSpokenTail3` directly. The
                    // wrapper's body reads only that property, so changes
                    // to lastSpokenTail3 (≈5 Hz on every ASR partial /
                    // final) re-render only the small Text — not the
                    // whole toolbar HStack. The toolbar currently reads
                    // audioLevels (43 Hz), isListening, isStarting,
                    // error, pageCount, etc., so the 5 Hz ASR tail churn
                    // was forcing the entire toolbar to rebuild 5 times
                    // /sec just to redraw three characters. With the
                    // wrapper, ASR tail updates don't add any toolbar
                    // re-renders — the parent only fires on the
                    // genuinely dynamic toolbar properties. Same fix
                    // applied to floatingPrompterView below.
                    LastSpokenTailText(recognizer: speechRecognizer, tailSize: 3, fontSize: 11)
                } else {
                    Spacer(minLength: 0)
                }

                if content.pageCount > 1 {
                    if hasNextPage {
                        Button {
                            speechRecognizer.shouldAdvancePage = true
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(white60)
                                .frame(width: 24, height: 24)
                                .background(white15)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in
                                    content.showPagePicker = true
                                }
                        )
                    } else {
                        Button {
                            content.jumpToPageIndex = 0
                        } label: {
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(white60)
                                .frame(width: 24, height: 24)
                                .background(white15)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in
                                    content.showPagePicker = true
                                }
                        )
                    }
                }

                if mode == .classic {
                    Button {
                        isPaused.toggle()
                    } label: {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isPaused ? white60 : yellow80)
                            .frame(width: 24, height: 24)
                            .background(white15)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        if speechRecognizer.isListening || speechRecognizer.isStarting {
                            speechRecognizer.stop()
                        } else {
                            speechRecognizer.resume()
                        }
                    } label: {
                        Group {
                            if speechRecognizer.isStarting {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(white80)
                            } else {
                                Image(systemName: speechRecognizer.isListening ? "mic.fill" : "mic.slash.fill")
                                    .font(.system(size: 10, weight: .bold))
                            }
                        }
                        .foregroundStyle(speechRecognizer.isListening ? yellow80 : white60)
                        .frame(width: 24, height: 24)
                        .background(white15)
                        .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    speechRecognizer.forceStop()
                    speechRecognizer.shouldDismiss = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(white60)
                        .frame(width: 24, height: 24)
                        .background(white15)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: 24)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            // Resize handle - only visible on hover
            if isHovering {
                VStack(spacing: 0) {
                    Spacer().frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(white25)
                        .frame(width: 36, height: 4)
                    Spacer().frame(height: 8)
                }
                .frame(height: 16)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { value in
                            if dragStartHeight < 0 {
                                dragStartHeight = extraHeight
                            }
                            let newExtra = dragStartHeight + value.translation.height
                            extraHeight = max(0, min(maxExtraHeight, newExtra))
                        }
                        .onEnded { _ in
                            dragStartHeight = -1
                        }
                )
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeUpDown.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isHovering = hovering
                }
            }
            .transition(.opacity)
        }
    }

    private var pagePickerView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                Text("跳转到页面")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(white50)
                    .padding(.bottom, 2)

                ForEach(0..<content.pageCount, id: \.self) { i in
                    let preview = i < content.pagePreviews.count ? content.pagePreviews[i] : ""
                    if !preview.isEmpty {
                        Button {
                            content.jumpToPageIndex = i
                            content.showPagePicker = false
                        } label: {
                            HStack(spacing: 8) {
                                Text("\(i + 1)")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(i == content.currentPageIndex ? .yellow : white80)
                                    .frame(width: 20)
                                Text(preview)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(i == content.currentPageIndex ? yellow70 : white50)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(i == content.currentPageIndex ? yellow10 : white05)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("点击页面跳转")
                    .font(.system(size: 10))
                    .foregroundStyle(white30)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .transition(.opacity)
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdownRemaining = NotchSettings.shared.autoNextPageDelay
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            DispatchQueue.main.async {
                countdownRemaining -= 1
                if countdownRemaining <= 0 {
                    timer.invalidate()
                    countdownTimer = nil
                    speechRecognizer.shouldAdvancePage = true
                }
            }
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownRemaining = 0
    }

    private var doneView: some View {
        VStack {
            Spacer()
            if hasNextPage {
                VStack(spacing: 6) {
                    if countdownRemaining > 0 {
                        Text("\(countdownRemaining)")
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.3), value: countdownRemaining)
                    }
                    Button {
                        cancelCountdown()
                        speechRecognizer.shouldAdvancePage = true
                    } label: {
                        VStack(spacing: 4) {
                            Text("下一页")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(white50)
                            Image(systemName: "forward.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("完成！")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            Spacer()
        }
        .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Glass Effect View

struct GlassEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .hudWindow
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

// MARK: - Floating Overlay View

struct FloatingOverlayView: View {
    @Bindable var content: OverlayContent
    @Bindable var speechRecognizer: SpeechRecognizer
    let baseHeight: CGFloat
    var followingCursor: Bool = false

    private var words: [String] { content.words }
    private var totalCharCount: Int { content.totalCharCount }
    private var hasNextPage: Bool { content.hasNextPage }

    @State private var appeared = false

    // Auto-advance countdown for follow-cursor mode (where buttons can't be clicked)
    @State private var countdownRemaining: Int = 0
    @State private var countdownTimer: Timer? = nil

    // Timer-based scroll for classic & silence-paused modes
    @State private var timerWordProgress: Double = 0
    @State private var isPaused: Bool = false
    @State private var isUserScrolling: Bool = false
    // R50: throttled from 20Hz → 10Hz. 50 ms is overkill for scroll-position
    // updates (eye perceives ~24Hz+ as smooth); 100 ms is indistinguishable
    // but cuts body re-runs for NotchOverlayView in half in classic mode.
    private let scrollTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private var listeningMode: ListeningMode {
        NotchSettings.shared.listeningMode
    }

    /// Convert fractional word index to char offset using actual word lengths.
    /// R52: now O(1) via prefix sum (`content.wordCharOffsets`) instead of an
    /// O(N) loop over `words`. See NotchOverlayView's copy for the same notes.
    private func charOffsetForWordProgress(_ progress: Double) -> Int {
        let offsets = content.wordCharOffsets
        if offsets.count == words.count + 1, !words.isEmpty {
            let whole = max(0, min(Int(progress), words.count))
            let frac = progress - Double(whole)
            let base = offsets[whole]
            let added = Int(Double(words[whole].count) * frac)
            return min(base + added, totalCharCount)
        }
        // Fallback: legacy O(N) path.
        let wholeWord = Int(progress)
        let frac = progress - Double(wholeWord)
        var offset = 0
        for i in 0..<min(wholeWord, words.count) {
            offset += words[i].count + 1
        }
        if wholeWord < words.count {
            offset += Int(Double(words[wholeWord].count) * frac)
        }
        return min(offset, totalCharCount)
    }

    /// Convert char offset back to fractional word index (for taps)
    private func wordProgressForCharOffset(_ charOffset: Int) -> Double {
        var offset = 0
        for (i, word) in words.enumerated() {
            let end = offset + word.count
            if charOffset <= end {
                let frac = Double(charOffset - offset) / Double(max(1, word.count))
                return Double(i) + frac
            }
            offset = end + 1
        }
        return Double(words.count)
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
            return !isPaused
        }
    }

    var body: some View {
        // R75: cache all NotchSettings.shared singletons + listeningMode +
        // isDone at body outer. Mirrors R74 for the NotchOverlayView body.
        // FloatingOverlayView body also re-renders at 20 Hz in classic /
        // silence-paused modes (scrollTimer drives timerWordProgress). The
        // body read NotchSettings.shared.showElapsedTime, floatingGlassEffect,
        // glassOpacity, autoNextPage, scrollSpeed inline and listeningMode
        // 4+ times per render. Hoisting saves 80+ singleton reads/sec.
        let mode = listeningMode
        let done = isDone
        let speed = NotchSettings.shared.scrollSpeed
        let showElapsed = NotchSettings.shared.showElapsedTime
        let floatingGlass = NotchSettings.shared.floatingGlassEffect
        let glassOpacity = NotchSettings.shared.glassOpacity
        return VStack(spacing: 0) {
            if content.showPagePicker {
                floatingPagePickerView
            // R75: served from body-cached `done` and `mode`.
            } else if done && (mode == .wordTracking || hasNextPage) {
                floatingDoneView
            } else {
                floatingPrompterView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            // R75: served from body-cached `showElapsed`.
            if showElapsed {
                ElapsedTimeView(fontSize: 11)
                    .padding(.top, 6)
                    .padding(.trailing, 10)
            }
        }
        .background(
            Group {
                // R75: served from body-cached `floatingGlass` and `glassOpacity`.
                if floatingGlass {
                    ZStack {
                        GlassEffectView()
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.black.opacity(glassOpacity))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.black)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.9)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) {
                appeared = true
            }
        }
        .onChange(of: speechRecognizer.shouldDismiss) { _, shouldDismiss in
            if shouldDismiss {
                withAnimation(.easeIn(duration: 0.25)) {
                    appeared = false
                }
            }
        }
        .animation(.easeInOut(duration: 0.5), value: done)
        // R75: served from body-cached `done`, `mode`, autoNext-via-line.
        .onChange(of: isDone) { _, d in
            if d {
                if mode == .wordTracking {
                    speechRecognizer.stop()
                }
                if !hasNextPage {
                    if mode == .wordTracking {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            speechRecognizer.shouldDismiss = true
                        }
                    }
                } else if followingCursor || NotchSettings.shared.autoNextPage {
                    startCountdown()
                }
            } else {
                cancelCountdown()
            }
        }
        // R75: scrollTimer closure (20 Hz in active scroll modes) now
        // captures `mode`, `done`, and `speed` from body outer.
        .onReceive(scrollTimer) { _ in
            guard !done, !isUserScrolling else { return }
            switch mode {
            case .classic:
                if !isPaused {
                    timerWordProgress += speed * 0.1
                }
            case .silencePaused:
                if !isPaused && speechRecognizer.isListening && speechRecognizer.isSpeaking {
                    timerWordProgress += speed * 0.1
                }
            case .wordTracking:
                break
            }
        }
        .onChange(of: content.totalCharCount) { _, _ in
            timerWordProgress = 0
        }
    }

    private var floatingPrompterView: some View {
        // R76: same local-cache dedup as NotchOverlayView.prompterView.
        // Previous body read effectiveCharCount twice (highlightedCharCount +
        // progress), listeningMode 4 times (onWordTap, smoothScroll, word-
        // tracking text, no-followingCursor mic-button else-branch), and 5
        // NotchSettings.shared singletons inline. FloatingOverlayView body
        // re-renders at 20 Hz in classic / silencePaused modes, so this was
        // ~11 reads per render × 20 Hz = ~220 reads/sec from this property
        // alone. Hoisting to locals saves 7 reads per render × 20 Hz =
        // ~140 reads/sec, plus 1 fewer effectiveCharCount call per render.
        let effective = effectiveCharCount
        let font = NotchSettings.shared.font
        let highlightColor = NotchSettings.shared.fontColorPreset.color
        let cueColor = NotchSettings.shared.cueColorPreset.color
        let cueUnread = NotchSettings.shared.cueBrightness.unreadOpacity
        let cueRead = NotchSettings.shared.cueBrightness.readOpacity
        let mode = listeningMode
        // R80: inline isEffectivelyListening switch on the cached `mode`
        // local (see main prompterView comment for rationale).
        let effectiveListening: Bool
        switch mode {
        case .wordTracking, .silencePaused:
            effectiveListening = speechRecognizer.isListening
        case .classic:
            effectiveListening = !isPaused
        }
        return VStack(spacing: 0) {
            SpeechScrollView(
                words: words,
                highlightedCharCount: effective,
                font: font,
                highlightColor: highlightColor,
                cueColor: cueColor,
                cueUnreadOpacity: cueUnread,
                cueReadOpacity: cueRead,
                onWordTap: { charOffset in
                    if mode == .wordTracking {
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
                smoothScroll: mode != .wordTracking,
                smoothWordProgress: timerWordProgress,
                isListening: effectiveListening
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)

            HStack(alignment: .center, spacing: 8) {
                AudioWaveformProgressView(
                    levels: speechRecognizer.audioLevels,
                    progress: totalCharCount > 0 ? Double(effective) / Double(totalCharCount) : 0
                )
                .frame(width: 160, height: 24)

                if let error = speechRecognizer.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(red90)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(error)
                } else if mode == .wordTracking {
                    // R83: companion fix to the floatingPrompterView
                    // toolbar. Same rationale as the prompterView call
                    // site above — replace the direct lastSpokenTail3
                    // read with the wrapper struct so ASR tail updates
                    // don't force the whole toolbar to re-render.
                    LastSpokenTailText(recognizer: speechRecognizer, tailSize: 3, fontSize: 11)
                } else {
                    Spacer()
                }

                if !followingCursor && content.pageCount > 1 {
                    if hasNextPage {
                        Button {
                            speechRecognizer.shouldAdvancePage = true
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(white60)
                                .frame(width: 24, height: 24)
                                .background(white15)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in
                                    content.showPagePicker = true
                                }
                        )
                    } else {
                        Button {
                            content.jumpToPageIndex = 0
                        } label: {
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(white60)
                                .frame(width: 24, height: 24)
                                .background(white15)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in
                                    content.showPagePicker = true
                                }
                        )
                    }
                }

                if !followingCursor {
                    if mode == .classic {
                        Button {
                            isPaused.toggle()
                        } label: {
                            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(isPaused ? white60 : yellow80)
                                .frame(width: 24, height: 24)
                                .background(white15)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            if speechRecognizer.isListening || speechRecognizer.isStarting {
                                speechRecognizer.stop()
                            } else {
                                speechRecognizer.resume()
                            }
                        } label: {
                            Group {
                                if speechRecognizer.isStarting {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .tint(white80)
                                } else {
                                    Image(systemName: speechRecognizer.isListening ? "mic.fill" : "mic.slash.fill")
                                        .font(.system(size: 10, weight: .bold))
                                }
                            }
                            .foregroundStyle(speechRecognizer.isListening ? yellow80 : white60)
                            .frame(width: 24, height: 24)
                            .background(white15)
                            .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        speechRecognizer.forceStop()
                        speechRecognizer.shouldDismiss = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(white60)
                            .frame(width: 24, height: 24)
                            .background(white15)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 24)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdownRemaining = NotchSettings.shared.autoNextPageDelay
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            DispatchQueue.main.async {
                countdownRemaining -= 1
                if countdownRemaining <= 0 {
                    timer.invalidate()
                    countdownTimer = nil
                    speechRecognizer.shouldAdvancePage = true
                }
            }
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownRemaining = 0
    }

    private var floatingPagePickerView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                Text("跳转到页面")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(white50)
                    .padding(.bottom, 4)

                ForEach(0..<content.pageCount, id: \.self) { i in
                    let preview = i < content.pagePreviews.count ? content.pagePreviews[i] : ""
                    if !preview.isEmpty {
                        Button {
                            content.jumpToPageIndex = i
                            content.showPagePicker = false
                        } label: {
                            HStack(spacing: 10) {
                                Text("\(i + 1)")
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundStyle(i == content.currentPageIndex ? .yellow : white80)
                                    .frame(width: 24)
                                Text(preview)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(i == content.currentPageIndex ? yellow70 : white50)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(i == content.currentPageIndex ? yellow10 : white05)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("点击页面跳转")
                    .font(.system(size: 11))
                    .foregroundStyle(white30)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .transition(.opacity)
    }

    private var floatingDoneView: some View {
        VStack {
            Spacer()
            if hasNextPage {
                VStack(spacing: 6) {
                    if countdownRemaining > 0 {
                        Text("\(countdownRemaining)")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.3), value: countdownRemaining)
                    }
                    if followingCursor {
                        Text("下一页")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Button {
                            cancelCountdown()
                            speechRecognizer.shouldAdvancePage = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("下一页")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("完成！")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            Spacer()
        }
        .transition(.scale.combined(with: .opacity))
    }
}
