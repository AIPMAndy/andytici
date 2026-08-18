//
//  TextreamService.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

class TextreamService: NSObject, ObservableObject {
    static let shared = TextreamService()
    let overlayController = NotchOverlayController()
    let externalDisplayController = ExternalDisplayController()
    let browserServer = BrowserServer()
    let directorServer = DirectorServer()
    var onOverlayDismissed: (() -> Void)?
    var launchedExternally = false
    @Published var directorIsReading = false

    // R115: cached answer to "does any page have non-whitespace content?".
    // O(Pages × trim) on every ContentView body re-render was wasteful —
    // pages only change on actual edits / add / remove / import, so the
    // recompute belongs at the mutation site, not the render site. The view
    // still subscribes to `pages` via currentText.get, so reactivity is
    // preserved when didSet fires. Initial value `false` matches pages = [""].
    private(set) var hasAnyContent: Bool = false

    @Published var pages: [String] = [""] {
        didSet {
            hasAnyContent = !pages.isEmpty
                && pages.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }
    @Published var currentPageIndex: Int = 0
    @Published var readPages: Set<Int> = []

    // R86: shared tokenization helper. Previously the pair
    //   let words = splitTextIntoWords(text)
    //   let totalCharCount = words.reduce(0) { $0 + $1.count }
    //                        + max(0, words.count - 1)
    // was duplicated at 4 call sites (readText, jumpToPage,
    // setTextFromDirector, updateTextFromDirector). The 4 copies
    // encode the same rule: "total char count = sum of word lengths
    // plus single-space separators between words". Extracting a
    // single helper makes the rule auditable in one place and keeps
    // future tokenization tweaks (e.g. CJK character counting, locale
    // separators) to a single edit.
    private static func tokenize(_ text: String) -> (words: [String], totalCharCount: Int) {
        let words = splitTextIntoWords(text)
        let totalCharCount = words.reduce(0) { $0 + $1.count }
            + max(0, words.count - 1)
        return (words, totalCharCount)
    }

    var hasNextPage: Bool {
        for i in (currentPageIndex + 1)..<pages.count {
            if !pages[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    var currentPageText: String {
        guard currentPageIndex < pages.count else { return "" }
        return pages[currentPageIndex]
    }

    func readText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        launchedExternally = true
        hideMainWindow()

        // Also show on external display if configured (same parsing as overlay)
        let (words, totalCharCount) = Self.tokenize(trimmed)
        // Cache hasNextPage once — each property access is O(P) over remaining pages.
        let nextPage = hasNextPage

        overlayController.show(
            text: trimmed,
            words: words,
            totalCharCount: totalCharCount,
            hasNextPage: nextPage
        ) { [weak self] in
            self?.externalDisplayController.dismiss()
            self?.browserServer.hideContent()
            self?.onOverlayDismissed?()
        }
        updatePageInfo()
        externalDisplayController.show(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            totalCharCount: totalCharCount,
            hasNextPage: nextPage
        )

        if browserServer.isRunning {
            browserServer.showContent(
                speechRecognizer: overlayController.speechRecognizer,
                words: words,
                totalCharCount: totalCharCount,
                hasNextPage: nextPage
            )
        }
    }

    func readCurrentPage() {
        let trimmed = currentPageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        readPages.insert(currentPageIndex)
        readText(trimmed)
    }

    func advanceToNextPage() {
        // Skip empty pages
        var nextIndex = currentPageIndex + 1
        while nextIndex < pages.count {
            let text = pages[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { break }
            nextIndex += 1
        }
        guard nextIndex < pages.count else { return }
        jumpToPage(index: nextIndex)
    }

    func jumpToPage(index: Int) {
        guard index >= 0 && index < pages.count else { return }
        let text = pages[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Mute mic before switching page content
        let wasListening = overlayController.speechRecognizer.isListening
        if wasListening {
            overlayController.speechRecognizer.stop()
        }

        currentPageIndex = index
        readPages.insert(currentPageIndex)

        // `text` is already the trimmed version of pages[index]; no need to
        // re-trim via currentPageText (which is the same string anyway).
        guard !text.isEmpty else { return }

        // Compute words once and reuse across overlay, external display, and browser
        let (words, totalCharCount) = Self.tokenize(text)
        let nextPage = hasNextPage

        // Update content in-place without recreating the panel
        overlayController.show(
            text: text,
            words: words,
            totalCharCount: totalCharCount,
            hasNextPage: nextPage
        )
        updatePageInfo()

        // R103: external display content is automatically in sync because
        // both controllers now share OverlayContent.shared. The overlay's
        // setWords call above (line 142 in NotchOverlayController.show) is
        // already visible to the external display's @Bindable view bindings.
        // Previously this block held a duplicate setWords call on
        // externalDisplayController.overlayContent — removed.

        if browserServer.isRunning {
            browserServer.updateContent(
                words: words,
                totalCharCount: totalCharCount,
                hasNextPage: nextPage
            )
        }

        // Unmute after new page content is loaded
        if wasListening {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let recognizer = self?.overlayController.speechRecognizer,
                      !recognizer.isListening,
                      !recognizer.isStarting else { return }
                recognizer.resume()
            }
        }
    }

    // Cache pagePreviews keyed by a fingerprint of `pages` (count + content
    // hashes). readText and jumpToPage both call updatePageInfo, but pages
    // typically hasn't changed between calls — recomputing previews every
    // time is O(P × 40) of throwaway work.
    private var cachedPagesFingerprint: Int = 0
    private var cachedPagesCount: Int = 0
    private var cachedPagePreviews: [String] = []

    func updatePageInfo() {
        let content = overlayController.overlayContent
        content.pageCount = pages.count
        content.currentPageIndex = currentPageIndex

        var fp = pages.count
        for page in pages {
            fp = (fp &* 31) &+ page.hashValue
        }
        if fp != cachedPagesFingerprint || pages.count != cachedPagesCount {
            cachedPagesFingerprint = fp
            cachedPagesCount = pages.count
            cachedPagePreviews = pages.map { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return "" }
                let preview = String(trimmed.prefix(40))
                return preview + (trimmed.count > 40 ? "…" : "")
            }
        }
        content.pagePreviews = cachedPagePreviews
    }

    func startAllPages() {
        readPages.removeAll()
        currentPageIndex = 0
        readCurrentPage()
    }

    func hideMainWindow() {
        DispatchQueue.main.async {
            for window in NSApp.windows where !(window is NSPanel) {
                window.makeFirstResponder(nil)
                window.orderOut(nil)
            }
        }
    }

    @Published var currentFileURL: URL?
    @Published var savedPages: [String] = [""]

    // MARK: - File Operations

    func saveFile() {
        if let url = currentFileURL {
            saveToURL(url)
        } else {
            saveFileAs()
        }
    }

    func saveFileAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "andytici")!]
        panel.nameFieldStringValue = "未命名.andytici"
        panel.canCreateDirectories = true

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.saveToURL(url)
        }
    }

    private func saveToURL(_ url: URL) {
        do {
            let data = try JSONEncoder().encode(pages)
            try data.write(to: url, options: .atomic)
            currentFileURL = url
            savedPages = pages
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "保存失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    var hasUnsavedChanges: Bool {
        pages != savedPages
    }

    func openFile() {
        guard confirmDiscardIfNeeded() else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "andytici")!,
            .init(filenameExtension: "key")!,
            .init(filenameExtension: "pptx")!,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let ext = url.pathExtension.lowercased()
            if ext == "key" {
                let alert = NSAlert()
                alert.messageText = "无法直接导入 Keynote"
                alert.informativeText = "请先把 Keynote 演示文稿导出为 PowerPoint (.pptx) 格式：\n\n在 Keynote 中选择 文件 → 导出到 → PowerPoint"
                alert.alertStyle = .informational
                alert.runModal()
            } else if ext == "pptx" {
                self?.importPresentation(from: url)
            } else {
                self?.openFileAtURL(url)
            }
        }
    }

    func importPresentation(from url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let notes = try PresentationNotesExtractor.extractNotes(from: url)
                DispatchQueue.main.async {
                    self?.pages = notes
                    self?.savedPages = notes
                    self?.currentPageIndex = 0
                    self?.readPages.removeAll()
                    self?.currentFileURL = nil
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "导入失败"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    /// Returns true if it's safe to proceed (saved, discarded, or no changes).
    /// Returns false if the user cancelled.
    func confirmDiscardIfNeeded() -> Bool {
        guard hasUnsavedChanges else { return true }

        let alert = NSAlert()
        alert.messageText = "有未保存的修改"
        alert.informativeText = "当前脚本还有未保存的修改，打开新文件前要先保存吗？"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            saveFile()
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func openFileAtURL(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let loadedPages = try JSONDecoder().decode([String].self, from: data)
            guard !loadedPages.isEmpty else { return }
            pages = loadedPages
            savedPages = loadedPages
            currentPageIndex = 0
            readPages.removeAll()
            currentFileURL = url
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "打开失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Browser Server

    func updateBrowserServer() {
        if NotchSettings.shared.browserServerEnabled {
            if !browserServer.isRunning {
                browserServer.start()
            }
        } else {
            browserServer.stop()
        }
    }

    // MARK: - Director Server

    func updateDirectorServer() {
        if NotchSettings.shared.directorModeEnabled {
            if !directorServer.isRunning {
                directorServer.start()
                wireDirectorCallbacks()
            }
        } else {
            directorServer.stop()
            if directorIsReading {
                overlayController.dismiss()
                directorIsReading = false
            }
        }
    }

    private func wireDirectorCallbacks() {
        directorServer.onSetText = { [weak self] text in
            self?.setTextFromDirector(text)
        }
        directorServer.onUpdateText = { [weak self] text, readCharCount in
            self?.updateTextFromDirector(text, readCharCount: readCharCount)
        }
        directorServer.onStop = { [weak self] in
            self?.stopDirectorReading()
        }
    }

    func setTextFromDirector(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Director mode is single page
        pages = [trimmed]
        currentPageIndex = 0
        readPages.removeAll()

        // Force word tracking mode for director
        let savedMode = NotchSettings.shared.listeningMode
        NotchSettings.shared.listeningMode = .wordTracking

        directorIsReading = true

        // Compute words once and reuse across overlay, director server, external display, and browser
        let (words, totalCharCount) = Self.tokenize(trimmed)

        overlayController.show(
            text: trimmed,
            words: words,
            totalCharCount: totalCharCount,
            hasNextPage: false
        ) { [weak self] in
            self?.directorIsReading = false
            self?.directorServer.hideContent()
            self?.externalDisplayController.dismiss()
            self?.browserServer.hideContent()
            // Restore listening mode
            NotchSettings.shared.listeningMode = savedMode
        }

        // Feed director server with speech recognizer
        directorServer.showContent(
            speechRecognizer: overlayController.speechRecognizer,
            totalCharCount: totalCharCount
        )

        // Also show on external display & browser if configured
        externalDisplayController.show(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            totalCharCount: totalCharCount,
            hasNextPage: false
        )
        if browserServer.isRunning {
            browserServer.showContent(
                speechRecognizer: overlayController.speechRecognizer,
                words: words,
                totalCharCount: totalCharCount,
                hasNextPage: false
            )
        }
    }

    func updateTextFromDirector(_ text: String, readCharCount: Int) {
        guard directorIsReading else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        pages = [trimmed]

        // Preserve read progress: only update unread portion
        let preservedCharCount = overlayController.speechRecognizer.recognizedCharCount

        let (words, totalCharCount) = Self.tokenize(trimmed)

        // Update overlay content without resetting speech progress
        // R101: fold hasNextPage into setWords so all three props share one
        // mutator site (was 2 sequential writes before).
        overlayController.overlayContent.setWords(
            words,
            totalCharCount: totalCharCount,
            hasNextPage: false
        )

        // Update the speech recognizer with new full text but keep char count
        overlayController.speechRecognizer.updateText(trimmed, preservingCharCount: preservedCharCount)

        // Update director server
        directorServer.updateContent(totalCharCount: totalCharCount)

        // R103: external display is now auto-synced via the shared
        // OverlayContent singleton — no explicit setWords call needed.
        // Update browser (still has its own minimal state).
        if browserServer.isRunning {
            browserServer.updateContent(
                words: words,
                totalCharCount: totalCharCount,
                hasNextPage: false
            )
        }
    }

    func stopDirectorReading() {
        guard directorIsReading else { return }
        overlayController.dismiss()
        directorIsReading = false
    }

    // macOS Services handler
    @objc func readInAndyTici(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string) else {
            error.pointee = "No text found on pasteboard" as NSString
            return
        }
        readText(text)
    }

    // URL scheme handler: andytici://read?text=Hello%20World
    func handleURL(_ url: URL) {
        guard url.scheme == "andytici" else { return }

        if url.host == "read" || url.path == "/read" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let textParam = components.queryItems?.first(where: { $0.name == "text" })?.value {
                readText(textParam)
            }
        }
    }
}
