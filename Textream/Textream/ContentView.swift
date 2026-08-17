//
//  ContentView.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import SwiftUI
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

struct ContentView: View {
    @ObservedObject private var service = TextreamService.shared
    @State private var isRunning = false
    @State private var dictation = DictationManager()
    @State private var dictationHighlightRange: NSRange? = nil
    @State private var dictationCaretPosition: Int? = nil
    @State private var editorCaretPosition: Int = 0
    @State private var isDroppingPresentation = false
    @State private var dropError: String?
    @State private var dropAlertTitle: String = "导入失败"
    @State private var showSettings = false
    @State private var showAbout = false
    @State private var showWelcome = !UserDefaults.standard.bool(forKey: "hasShownWelcome")
    @State private var showHookTemplates = false
    @State private var languageSuggestion: SpeechLanguageSuggestion?
    @State private var ignoredLanguageIdentifier: String?
    @State private var languageDetectionTask: Task<Void, Never>?
    @FocusState private var isTextFocused: Bool

    private let defaultText = ""

    private var languageLabel: String {
        let locale = NotchSettings.shared.speechLocale
        return Locale.current.localizedString(forIdentifier: locale)
            ?? locale
    }

    private var currentText: Binding<String> {
        Binding(
            get: {
                guard service.currentPageIndex < service.pages.count else { return "" }
                return service.pages[service.currentPageIndex]
            },
            set: { newValue in
                guard service.currentPageIndex < service.pages.count else { return }
                service.pages[service.currentPageIndex] = newValue
            }
        )
    }

    private var hasAnyContent: Bool {
        service.pages.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var isRecording: Bool {
        dictation.isRecording || dictation.isStarting
    }

    private func scheduleLanguageDetection(for text: String) {
        languageDetectionTask?.cancel()
        languageSuggestion = nil
        let pageIndex = service.currentPageIndex
        let localeIdentifier = NotchSettings.shared.speechLocale

        languageDetectionTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 2_500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  service.currentPageIndex == pageIndex,
                  service.currentPageText == text,
                  NotchSettings.shared.speechLocale == localeIdentifier else { return }

            let suggestion = SpeechLanguageDetector.suggestion(
                for: text,
                currentLocaleIdentifier: localeIdentifier
            )
            guard !Task.isCancelled,
                  suggestion?.detectedLanguageIdentifier != ignoredLanguageIdentifier else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                languageSuggestion = suggestion
            }
        }
    }

    private func languageSuggestionBanner(_ suggestion: SpeechLanguageSuggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "character.bubble.fill")
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("这段文字像是 \(suggestion.languageName)。")
                    .font(.system(size: 12, weight: .semibold))
                Text("当前语音识别语言是 \(languageLabel)。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("切换到 \(suggestion.languageName)") {
                if isRecording {
                    stopRecording()
                }
                ignoredLanguageIdentifier = nil
                languageSuggestion = nil
                NotchSettings.shared.speechLocale = suggestion.localeIdentifier
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Switch speech recognition to \(suggestion.localeName)")

            Button {
                ignoredLanguageIdentifier = suggestion.detectedLanguageIdentifier
                withAnimation(.easeInOut(duration: 0.2)) {
                    languageSuggestion = nil
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭语言建议")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.2))
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var waveformPill: some View {
        let pill = AudioWaveformView(levels: dictation.audioLevels, color: .red)
            .frame(height: 34)
            .frame(maxWidth: 240)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            pill
                .glassEffect(in: .capsule)
        } else {
            pill
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
        #else
        pill
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        #endif
    }

    @State private var highlightClearTimer: Timer?

    // Segment tracking: each recognition session is a "segment"
    @State private var segmentStart: Int = 0
    @State private var segmentLength: Int = 0
    @State private var segmentNeedsSeparator: Bool = false
    // How many chars of the raw recognition result to skip (already committed before cursor move)
    @State private var spokenSkipOffset: Int = 0
    @State private var lastRawSpokenLength: Int = 0
    // True after the user manually moves the editor caret or scrolls away from
    // the ASR-tracked position. When true, ASR partials no longer overwrite the
    // text or force the caret back to its inferred position — the user is in
    // control. Reset when the user types again or stops recording.
    @State private var userManualOverride: Bool = false

    private func beginNewSegment() {
        let pageIndex = service.currentPageIndex
        guard pageIndex < service.pages.count else { return }
        let text = service.pages[pageIndex]
        let caret = min(editorCaretPosition, text.count)

        // Skip everything already recognized up to this point
        spokenSkipOffset = lastRawSpokenLength

        // Check if we need a space before the new segment
        let charBefore = caret > 0 ? text[text.index(text.startIndex, offsetBy: caret - 1)] : "\n"
        segmentNeedsSeparator = !(charBefore == " " || charBefore == "\n" || caret == 0)
        segmentStart = caret
        segmentLength = 0
    }

    private func startRecording() {
        lastRawSpokenLength = 0
        spokenSkipOffset = 0
        userManualOverride = false
        beginNewSegment()

        dictation.onNewSegment = { [self] in
            // Recognition restarted — raw counter resets to 0
            lastRawSpokenLength = 0
            spokenSkipOffset = 0
            userManualOverride = false
            beginNewSegment()
        }

        dictation.onTextUpdate = { [self] spokenText in
            // Track raw length regardless of override so resume-from-pause still works.
            lastRawSpokenLength = spokenText.count
            // User has taken control (clicked elsewhere / scrolled). Don't let ASR
            // partials overwrite their text or steal the caret.
            guard !userManualOverride else { return }

            // Only use the portion after the skip offset
            let effectiveText: String
            if spokenSkipOffset < spokenText.count {
                effectiveText = String(spokenText.suffix(spokenText.count - spokenSkipOffset))
            } else {
                effectiveText = ""
            }
            guard !effectiveText.isEmpty else { return }

            let pageIndex = service.currentPageIndex
            guard pageIndex < service.pages.count else { return }
            var text = service.pages[pageIndex]

            // Remove the old segment text
            let safeStart = min(segmentStart, text.count)
            let removeStart = text.index(text.startIndex, offsetBy: safeStart)
            let safeLen = min(segmentLength, text.count - safeStart)
            let removeEnd = text.index(removeStart, offsetBy: safeLen)
            text.removeSubrange(removeStart..<removeEnd)

            // Build the new segment content
            let sep = segmentNeedsSeparator ? " " : ""
            let newSegment = sep + effectiveText
            text.insert(contentsOf: newSegment, at: text.index(text.startIndex, offsetBy: min(segmentStart, text.count)))

            let prevLen = segmentLength
            segmentLength = newSegment.count
            service.pages[pageIndex] = text

            // Highlight only the newly added characters
            let newChars = segmentLength - prevLen
            if newChars > 0 {
                let highlightStart = segmentStart + prevLen
                dictationHighlightRange = NSRange(location: highlightStart, length: newChars)
            }

            // Move caret to end of segment
            dictationCaretPosition = segmentStart + segmentLength

            // Clear highlight after 1s of silence
            highlightClearTimer?.invalidate()
            highlightClearTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                DispatchQueue.main.async {
                    dictationHighlightRange = nil
                }
            }
        }
        dictation.start()
    }

    private func stopRecording() {
        highlightClearTimer?.invalidate()
        highlightClearTimer = nil
        dictationHighlightRange = nil
        userManualOverride = false
        dictation.stop()
        dictation.onTextUpdate = nil
        dictation.onNewSegment = nil
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if let languageSuggestion {
                languageSuggestionBanner(languageSuggestion)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ZStack {
                HighlightingTextEditor(
                    text: currentText,
                    font: .systemFont(ofSize: 16, weight: .regular).rounded,
                    highlightRange: dictationHighlightRange,
                    caretPosition: $dictationCaretPosition,
                    editorCaretPosition: $editorCaretPosition,
                    onUserEdit: { userManualOverride = false }
                )
                .onChange(of: editorCaretPosition) { _, newPos in
                    guard isRecording else { return }
                    // If caret moved away from end of current segment, the user clicked
                    // or scrolled to a different position. Hand control back: ASR will
                    // stop overwriting text/selection until the user types again.
                    let segmentEnd = segmentStart + segmentLength
                    if newPos != segmentEnd {
                        userManualOverride = true
                        beginNewSegment()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white, location: 0.03),
                            .init(color: .white, location: 0.93),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // Bottom bar
                VStack {
                    Spacer()
                    ZStack {
                        // Waveform pill centered to full width
                        if dictation.isRecording {
                            waveformPill
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }

                        // Buttons pinned right
                        HStack(spacing: 12) {
                            Spacer()

                            Button {
                                if isRecording {
                                    stopRecording()
                                } else {
                                    startRecording()
                                }
                            } label: {
                                Group {
                                    if dictation.isStarting {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(.white)
                                    } else {
                                        Image(systemName: isRecording ? "pause.fill" : "mic.fill")
                                            .font(.system(size: 16, weight: .semibold))
                                    }
                                }
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(isRecording ? Color.orange : Color.red)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                            }
                            .buttonStyle(.plain)
                            .disabled(isRunning)
                            .opacity(isRunning ? 0.4 : 1)

                            Button {
                                if isRunning {
                                    stop()
                                } else {
                                    run()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isRunning ? "stop.fill" : "play.fill")
                                        .font(.system(size: 16, weight: .bold))
                                    Text(isRunning ? "停止" : "开始提词")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .frame(height: 44)
                                .background(isRunning ? Color.red : Color.accentColor)
                                .clipShape(Capsule())
                                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                            }
                            .buttonStyle(.plain)
                            .disabled((!isRunning && !hasAnyContent) || isRecording)
                            .opacity((!hasAnyContent && !isRunning) || isRecording ? 0.4 : 1)
                        }
                    }
                    .padding(20)
                }
                .animation(.easeInOut(duration: 0.25), value: isRecording)

                // Drop zone overlay — sits on top so TextEditor doesn't steal the drop
                if isDroppingPresentation {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Color.accentColor)
                    Text("拖入 PowerPoint (.pptx) 文件")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("Keynote 或 Google Slides 请先\n导出为 PPTX 再拖入。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .background(Color.accentColor.opacity(0.08).clipShape(RoundedRectangle(cornerRadius: 12)))
                )
                .padding(8)
            }

            // Invisible drop target covering entire window
            Color.clear
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], isTargeted: $isDroppingPresentation) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        let ext = url.pathExtension.lowercased()
                        if ext == "key" {
                            DispatchQueue.main.async {
                                dropAlertTitle = "需要先转换格式"
                                dropError = "无法直接导入 Keynote 文件。请先在 Keynote 中把演示文稿导出为 PowerPoint (.pptx) 格式，再拖入导出文件。"
                            }
                            return
                        }
                        guard ext == "pptx" else {
                            DispatchQueue.main.async {
                                dropAlertTitle = "不支持的文件"
                                dropError = "仅支持 PowerPoint (.pptx) 文件，请确认格式后重试。"
                            }
                            return
                        }
                        DispatchQueue.main.async {
                            handlePresentationDrop(url: url)
                        }
                    }
                    return true
                }
                .allowsHitTesting(isDroppingPresentation)
            }
        }
    }

    private var directorOverlay: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "megaphone.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            Text("导演台已连接")
                .font(.system(size: 22, weight: .bold))

            Text(service.directorIsReading ? "正在朗读导演推送的脚本…" : "等待导演推送脚本…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            if let ip = BrowserServer.localIPAddress() {
                let url = "http://\(ip):\(NotchSettings.shared.directorServerPort)"

                if let qrImage = generateDirectorQRCode(from: url) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 140, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 8) {
                    Text(url)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .textSelection(.enabled)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                showSettings = true
            } label: {
                Text("打开设置")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func generateDirectorQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let scale = 10.0
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    var body: some View {
        Group {
            if NotchSettings.shared.directorModeEnabled {
                directorOverlay
            } else {
                NavigationSplitView {
                    pageSidebar
                } detail: {
                    mainContent
                }
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 260)
            }
        }
        .alert(dropAlertTitle, isPresented: Binding(get: { dropError != nil }, set: { if !$0 { dropError = nil } })) {
            Button("好") { dropError = nil }
        } message: {
            Text(dropError ?? "")
        }
        .alert("麦克风不可用", isPresented: Binding(
            get: { dictation.error != nil },
            set: { if !$0 { dictation.error = nil } }
        )) {
            Button("好") { dictation.error = nil }
        } message: {
            Text(dictation.error ?? "")
        }
        .frame(minWidth: 360, minHeight: 240)
        .background(.ultraThinMaterial)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 8) {
                    Button {
                        if isRecording {
                            stopRecording()
                        }
                        service.openFile()
                    } label: {
                        HStack(spacing: 4) {
                            if service.currentFileURL != nil && service.pages != service.savedPages {
                                Circle()
                                    .fill(.orange)
                                    .frame(width: 6, height: 6)
                            }
                            Text(service.currentFileURL?.deletingPathExtension().lastPathComponent ?? "未命名")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)

                    // Add page button in toolbar
                    Button {
                        if isRecording {
                            stopRecording()
                        }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            service.pages.append("")
                            service.currentPageIndex = service.pages.count - 1
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                            Text("加页")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    // Hook 模板入口（Andy题词 新增）
                    Button {
                        showHookTemplates = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10, weight: .semibold))
                            Text("金句")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Color.andyGold)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showSettings = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: NotchSettings.shared.listeningMode.icon)
                                .font(.system(size: 10))
                            Text(NotchSettings.shared.listeningMode == .wordTracking
                                 ? languageLabel
                                 : NotchSettings.shared.listeningMode.label)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: NotchSettings.shared)
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeView(isPresented: $showWelcome)
        }
        .sheet(isPresented: $showHookTemplates) {
            HookTemplateSheet(onSelect: { template in
                let filled = template.fill(with: "") + "\n\n"
                let insertAt = currentText.wrappedValue.isEmpty ? "" : "\n"
                currentText.wrappedValue = filled + insertAt + currentText.wrappedValue
                showHookTemplates = false
            })
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAbout)) { _ in
            showAbout = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Sync button state when app is re-activated (e.g. dock click)
            isRunning = service.overlayController.isShowing
        }
        .onChange(of: service.currentPageText, initial: true) { _, text in
            scheduleLanguageDetection(for: text)
        }
        .onChange(of: service.currentPageIndex) { _, _ in
            if isRecording {
                stopRecording()
            }
            ignoredLanguageIdentifier = nil
            scheduleLanguageDetection(for: service.currentPageText)
        }
        .onChange(of: NotchSettings.shared.speechLocale) { _, _ in
            if isRecording {
                stopRecording()
            }
            ignoredLanguageIdentifier = nil
            scheduleLanguageDetection(for: service.currentPageText)
        }
        .onDisappear {
            languageDetectionTask?.cancel()
            if isRecording {
                stopRecording()
            }
        }
        .onAppear {
            // Set default text for the first page if empty
            if service.pages.count == 1 && service.pages[0].isEmpty {
                service.pages[0] = defaultText
            }
            // Sync button state with overlay
            if service.overlayController.isShowing {
                isRunning = true
            }
            if TextreamService.shared.launchedExternally {
                DispatchQueue.main.async {
                    for window in NSApp.windows where !(window is NSPanel) {
                        window.orderOut(nil)
                    }
                }
            } else {
                isTextFocused = true
            }
        }
    }

    // MARK: - Page Sidebar

    private func pagePreview(_ page: String) -> String {
        let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "空白页" }
        let words = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let preview = words.prefix(5).joined(separator: " ")
        return preview.count > 30 ? String(preview.prefix(30)) + "…" : preview
    }

    private var sidebarSelection: Binding<Int?> {
        Binding<Int?>(
            get: { service.currentPageIndex },
            set: { newValue in
                if let index = newValue {
                    if isRecording {
                        stopRecording()
                    }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        service.currentPageIndex = index
                    }
                }
            }
        )
    }

    private var pageSidebar: some View {
        List(selection: sidebarSelection) {
            ForEach(Array(service.pages.enumerated()), id: \.offset) { index, page in
                Label {
                    Text(pagePreview(page))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } icon: {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(width: 20, height: 20)
                        .background(service.readPages.contains(index) ? Color.green.opacity(0.3) : Color.primary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .tag(index)
                .contextMenu {
                    if service.pages.count > 1 {
                        Button(role: .destructive) {
                            removePage(at: index)
                        } label: {
                            Label("删除页", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                if isRecording {
                    stopRecording()
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    service.pages.append("")
                    service.currentPageIndex = service.pages.count - 1
                }
            } label: {
                Label("添加页面", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    private func removePage(at index: Int) {
        guard service.pages.count > 1 else { return }
        if isRecording {
            stopRecording()
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            service.pages.remove(at: index)
            if service.currentPageIndex >= service.pages.count {
                service.currentPageIndex = service.pages.count - 1
            } else if service.currentPageIndex > index {
                service.currentPageIndex -= 1
            }
        }
    }

    private func run() {
        guard hasAnyContent else { return }
        // Resign text editor focus before hiding the window to avoid ViewBridge crashes
        isTextFocused = false
        service.onOverlayDismissed = { [self] in
            isRunning = false
            service.readPages.removeAll()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        service.readPages.removeAll()
        // If the current page is empty, find the first non-empty page
        let currentText = service.currentPageText.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentText.isEmpty {
            if let firstNonEmpty = service.pages.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                service.currentPageIndex = firstNonEmpty
            }
        }
        service.readCurrentPage()
        isRunning = true
    }

    @State private var isImporting = false

    private func handlePresentationDrop(url: URL) {
        guard service.confirmDiscardIfNeeded() else { return }
        if isRecording {
            stopRecording()
        }
        isImporting = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let notes = try PresentationNotesExtractor.extractNotes(from: url)
                DispatchQueue.main.async {
                    service.pages = notes
                    service.savedPages = notes
                    service.currentPageIndex = 0
                    service.readPages.removeAll()
                    service.currentFileURL = nil
                    isImporting = false
                }
            } catch {
                DispatchQueue.main.async {
                    dropError = error.localizedDescription
                    isImporting = false
                }
            }
        }
    }

    private func stop() {
        service.overlayController.dismiss()
        service.readPages.removeAll()
        isRunning = false
    }
}

// MARK: - About View

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 16) {
            // App icon
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }

            // App name & version
            VStack(spacing: 4) {
                Text("Andy题词")
                    .font(.system(size: 20, weight: .bold))
                Text("版本 \(appVersion)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // Description
            Text("中文口播创作者的智能提词器，朗读时高亮当前字词，自动跟随你的声音推进。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            // Links
            HStack(spacing: 12) {
                Link(destination: URL(string: "https://github.com/AIPMAndy/andytici")!) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                        Text("GitHub 仓库")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
                }

                Link(destination: URL(string: "https://github.com/AIPMAndy/andytici/blob/main/docs/PRIVACY.md")!) {
                    HStack(spacing: 5) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("隐私政策")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
                }

                #if !APP_STORE
                Link(destination: URL(string: "https://github.com/AIPMAndy/andytici/issues")!) {
                    HStack(spacing: 5) {
                        Image(systemName: "ladybug.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("反馈")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.andyGold.opacity(0.15))
                    .clipShape(Capsule())
                }
                #endif
            }

            Divider().padding(.horizontal, 20)

            VStack(spacing: 4) {
                Text("Andy题词 · 中文口播创作者专用")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Andy题词 修改与维护 · MIT · © 2026 Andy")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Button("好的") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Andy题词 Hook 模板选择
struct HookTemplateSheet: View {
    let onSelect: (HookTemplate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "text.bubble.fill")
                    .foregroundColor(.andyGold)
                Text("Hook 模板")
                    .font(.title2.bold())
                Spacer()
            }
            Text("点击下方模板，会插入到脚本开头")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(HookTemplate.Category.allCases, id: \.self) { category in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category.rawValue)
                                .font(.headline)
                                .foregroundColor(.andyGold)
                            ForEach(HookTemplate.all.filter { $0.category == category }) { template in
                                Button(action: { onSelect(template) }) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(template.template)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text(template.exampleFilled)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(.ultraThinMaterial)
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 480)
    }
}

extension Color {
    static let andyGold = Color(red: 1.0, green: 0.843, blue: 0.0)
}

#Preview {
    ContentView()
}
