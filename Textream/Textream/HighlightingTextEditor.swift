//
//  HighlightingTextEditor.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 26.02.2026.
//

import SwiftUI
import AppKit

extension NSFont {
    var rounded: NSFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

struct HighlightingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: 16, weight: .regular)
    var isFocused: FocusState<Bool>.Binding?
    /// Range of newly dictated text to highlight with a bump effect
    var highlightRange: NSRange? = nil
    /// One-shot: set caret to this position, then nilled out
    @Binding var caretPosition: Int?
    /// Continuously reported current caret position in the editor
    @Binding var editorCaretPosition: Int
    /// Fires on every keystroke from the user (i.e. textView-driven edits).
    /// Useful for telling the parent "the user is typing, not ASR."
    var onUserEdit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = font
        textView.delegate = context.coordinator
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // Set initial text and apply highlighting
        textView.string = text
        context.coordinator.applyHighlighting(textView)

        updateWritingDirection(textView, text: text)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Keep the coordinator's callback in sync with the latest binding value.
        context.coordinator.onUserEdit = onUserEdit

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            let prevText = context.coordinator.lastAppliedText
            let prevLen = context.coordinator.lastAppliedTextLength
            let newLen = (text as NSString).length
            textView.string = text
            textView.selectedRanges = selectedRanges

            // Detect ASR append: the new text purely extends the previous
            // one. In that case only the new chars need their [bracket]
            // status checked. User edits flow through textDidChange and
            // reach updateNSView with textView.string already in sync, so
            // this branch is skipped for keystrokes.
            let isAppend = prevLen > 0
                && newLen > prevLen
                && text.hasPrefix(prevText)
            if isAppend {
                let extLeft = min(50, prevLen)
                let scanStart = prevLen - extLeft
                let scanRange = NSRange(location: scanStart, length: newLen - scanStart)
                context.coordinator.applyHighlighting(textView, onlyInRange: scanRange)
            } else {
                context.coordinator.applyHighlighting(textView)
            }
            context.coordinator.lastAppliedText = text
            context.coordinator.lastAppliedTextLength = newLen
        }
        updateWritingDirection(textView, text: text)

        // Apply bump highlight on newly dictated range
        if let range = highlightRange, range.location + range.length <= textView.string.count {
            context.coordinator.applyBumpHighlight(textView, range: range)
        }

        // Move caret to requested position (one-shot)
        if let pos = caretPosition, pos <= textView.string.count {
            let caretRange = NSRange(location: pos, length: 0)
            textView.setSelectedRange(caretRange)
            textView.scrollRangeToVisible(caretRange)
            DispatchQueue.main.async {
                self.caretPosition = nil
            }
        }
    }

    /// Set the text view's base writing direction based on the content's script.
    private func updateWritingDirection(_ textView: NSTextView, text: String) {
        switch textBaseDirection(in: text) {
        case .rightToLeft:
            textView.baseWritingDirection = .rightToLeft
        case .leftToRight:
            textView.baseWritingDirection = .leftToRight
        case .natural:
            textView.baseWritingDirection = .natural
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HighlightingTextEditor
        weak var textView: NSTextView?
        var onUserEdit: (() -> Void)?

        private static let annotationPattern = try! NSRegularExpression(
            pattern: "\\[[^\\]]+\\]",
            options: []
        )

        // Tracks the last text we applied highlighting to. When the text
        // binding changes from ASR (recognizedCharCount-driven), the new
        // text is almost always a pure append of the previous one. We can
        // then highlight only the newly appended range and skip the
        // full-text rewrite that runs every binding flush (~5 Hz in
        // dictation mode).
        // fileprivate so HighlightingTextEditor.updateNSView can read/write
        // across the class boundary (Swift's `private` is type-scoped).
        fileprivate var lastAppliedText: String = ""
        fileprivate var lastAppliedTextLength: Int = 0

        // Cached derived attributes. NSFontManager.shared.convert() and
        // NSColor.withAlphaComponent() are both non-trivial; recomputing
        // them per call (and per matched annotation) is wasted work.
        private static var cachedItalicFont: NSFont?
        private static var cachedAnnotationBgColor: NSColor?
        private static var cachedAnnotationFgColor: NSColor?
        private static var cachedDefaultFgColor: NSColor?
        private static var cachedBumpColor: NSColor?

        init(_ parent: HighlightingTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.updateWritingDirection(textView, text: textView.string)
            // NOTE: do not call applyHighlighting here. updateNSView will run
            // on the next binding flush and apply attribute resets exactly
            // once. Calling it again now causes a double full-rewrite of the
            // NSTextStorage for every keystroke.
            // Notify the parent that the user just typed — used to drop
            // the "manual override" flag so ASR can resume editing the segment.
            onUserEdit?()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let pos = textView.selectedRange().location
            if parent.editorCaretPosition != pos {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.editorCaretPosition = pos
                }
            }
        }

        private var bumpTimer: Timer?
        private var lastBumpRange: NSRange = NSRange(location: 0, length: 0)

        func applyBumpHighlight(_ textView: NSTextView, range: NSRange) {
            guard let textStorage = textView.textStorage else { return }
            guard range.length > 0, range.location + range.length <= textStorage.length else { return }

            let bumpColor = Self.cachedBumpColor ?? {
                let c = NSColor.controlAccentColor.withAlphaComponent(0.15)
                Self.cachedBumpColor = c
                return c
            }()
            textStorage.beginEditing()
            textStorage.addAttribute(.backgroundColor, value: bumpColor, range: range)
            textStorage.endEditing()

            // Remember which range was bumped so the fade timer can clear it
            // surgically rather than rewriting the whole text.
            lastBumpRange = range

            // Fade out after a short delay
            bumpTimer?.invalidate()
            bumpTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                self.clearBumpHighlight(textView)
            }
        }

        /// Surgical reset of the bump highlight: only touches the previously
        /// bumped range. Re-uses `applyHighlighting(_:onlyInRange:)` which
        /// resets defaults in the range AND re-scans for any [bracket]
        /// annotations that overlap it. Replaces the previous behavior of
        /// calling `applyHighlighting(textView)` which rewrote attributes
        /// over the entire text and re-ran the [bracket] regex every 0.6 s
        /// during active dictation.
        private func clearBumpHighlight(_ textView: NSTextView) {
            let range = lastBumpRange
            guard range.length > 0,
                  range.location + range.length <= textView.string.utf16.count else {
                lastBumpRange = NSRange(location: 0, length: 0)
                return
            }
            applyHighlighting(textView, onlyInRange: range)
            lastBumpRange = NSRange(location: 0, length: 0)
        }

        func applyHighlighting(_ textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: textStorage.length)
            let text = textStorage.string

            // Preserve selection
            let selectedRanges = textView.selectedRanges

            textStorage.beginEditing()

            // Reset to default style
            let defaultFg = Self.cachedDefaultFgColor ?? {
                let c = NSColor.labelColor
                Self.cachedDefaultFgColor = c
                return c
            }()
            let defaultAttributes: [NSAttributedString.Key: Any] = [
                .font: parent.font,
                .foregroundColor: defaultFg
            ]
            textStorage.setAttributes(defaultAttributes, range: fullRange)

            // Highlight [bracket] annotations. italicFont and tinted bg color
            // are cached so we don't reallocate per match.
            let italicFont = Self.cachedItalicFont ?? {
                let f = NSFontManager.shared.convert(parent.font, toHaveTrait: .italicFontMask)
                Self.cachedItalicFont = f
                return f
            }()
            let annotationFg = Self.cachedAnnotationFgColor ?? {
                let c = NSColor.secondaryLabelColor
                Self.cachedAnnotationFgColor = c
                return c
            }()
            let annotationBg = Self.cachedAnnotationBgColor ?? {
                let c = NSColor.secondaryLabelColor.withAlphaComponent(0.08)
                Self.cachedAnnotationBgColor = c
                return c
            }()
            let annotationAttributes: [NSAttributedString.Key: Any] = [
                .font: italicFont,
                .foregroundColor: annotationFg,
                .backgroundColor: annotationBg
            ]
            let matches = Self.annotationPattern.matches(in: text, options: [], range: fullRange)
            for match in matches {
                textStorage.addAttributes(annotationAttributes, range: match.range)
            }

            textStorage.endEditing()

            // Restore selection
            textView.selectedRanges = selectedRanges
        }

        /// Range-scoped variant of `applyHighlighting`. Resets default
        /// attributes only inside `range` and re-applies bracket annotations
        /// across the union of `range` and a small left buffer (to catch
        /// brackets that span the boundary, e.g. an existing `[` combined
        /// with newly appended `xyz]`).
        func applyHighlighting(_ textView: NSTextView, onlyInRange range: NSRange) {
            guard let textStorage = textView.textStorage else { return }
            let textLen = textStorage.length
            let extLeft = min(50, range.location)
            let scanStart = range.location - extLeft
            let scanRange = NSRange(location: scanStart, length: range.length + extLeft)
            guard scanRange.location + scanRange.length <= textLen else {
                applyHighlighting(textView)
                return
            }

            let selectedRanges = textView.selectedRanges

            // Cached attribute lookups (same as full version).
            let defaultFg = Self.cachedDefaultFgColor ?? {
                let c = NSColor.labelColor
                Self.cachedDefaultFgColor = c
                return c
            }()
            let italicFont = Self.cachedItalicFont ?? {
                let f = NSFontManager.shared.convert(parent.font, toHaveTrait: .italicFontMask)
                Self.cachedItalicFont = f
                return f
            }()
            let annotationFg = Self.cachedAnnotationFgColor ?? {
                let c = NSColor.secondaryLabelColor
                Self.cachedAnnotationFgColor = c
                return c
            }()
            let annotationBg = Self.cachedAnnotationBgColor ?? {
                let c = NSColor.secondaryLabelColor.withAlphaComponent(0.08)
                Self.cachedAnnotationBgColor = c
                return c
            }()
            let defaultAttributes: [NSAttributedString.Key: Any] = [
                .font: parent.font,
                .foregroundColor: defaultFg
            ]
            let annotationAttributes: [NSAttributedString.Key: Any] = [
                .font: italicFont,
                .foregroundColor: annotationFg,
                .backgroundColor: annotationBg
            ]

            textStorage.beginEditing()

            // Reset attributes only in the new range — the left buffer is
            // already correctly highlighted by the previous run.
            textStorage.setAttributes(defaultAttributes, range: range)

            // Scan the extended range for any [bracket] annotations that
            // may straddle the boundary.
            let sub = (textStorage.string as NSString).substring(with: scanRange)
            let subFullRange = NSRange(location: 0, length: (sub as NSString).length)
            let matches = Self.annotationPattern.matches(in: sub, options: [], range: subFullRange)
            for match in matches {
                let absRange = NSRange(
                    location: scanRange.location + match.range.location,
                    length: match.range.length
                )
                textStorage.addAttributes(annotationAttributes, range: absRange)
            }

            textStorage.endEditing()
            textView.selectedRanges = selectedRanges
        }
    }
}
