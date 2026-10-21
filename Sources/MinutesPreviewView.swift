import AppKit
import SwiftUI

/// A rendered Markdown document with native selection, copying and find support.
struct MinutesPreviewView: NSViewRepresentable {
    let documentID: UUID
    let text: String

    func makeNSView(context: Context) -> MinutesTextScrollView {
        MinutesTextScrollView()
    }

    func updateNSView(_ view: MinutesTextScrollView, context: Context) {
        view.show(text: text, documentID: documentID)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MinutesTextScrollView, context: Context) -> CGSize? {
        // SwiftUI's sheet also asks for zero/infinite ideal sizes. The viewport
        // stays bounded; document height belongs to the native scroll view.
        CGSize(width: proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 700,
               height: proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 450)
    }
}

final class MinutesTextScrollView: NSScrollView {
    let minutesTextView: NSTextView
    private var displayedDocumentID: UUID?
    private var displayedText: String?

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 668, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        minutesTextView = MinutesReadOnlyTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 450), textContainer: container)
        super.init(frame: NSRect(x: 0, y: 0, width: 700, height: 450))
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = true
        backgroundColor = .white
        minutesTextView.isEditable = false
        minutesTextView.isSelectable = true
        minutesTextView.isRichText = true
        minutesTextView.importsGraphics = false
        minutesTextView.allowsUndo = false
        minutesTextView.isVerticallyResizable = true
        minutesTextView.isHorizontallyResizable = false
        minutesTextView.autoresizingMask = [.width]
        minutesTextView.minSize = NSSize(width: 0, height: 0)
        minutesTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        minutesTextView.textContainerInset = NSSize(width: 28, height: 26)
        minutesTextView.backgroundColor = .white
        minutesTextView.usesFindBar = true
        minutesTextView.isIncrementalSearchingEnabled = true
        minutesTextView.setAccessibilityLabel("회의록 미리보기")
        documentView = minutesTextView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show(text: String, documentID: UUID) {
        let changedDocument = displayedDocumentID != documentID
        guard changedDocument || displayedText != text else { return }
        let origin = contentView.bounds.origin
        let selections = minutesTextView.selectedRanges
        let rendered = MinutesMarkdownRenderer.render(text)
        minutesTextView.textStorage?.setAttributedString(rendered)
        displayedDocumentID = documentID
        displayedText = text
        if changedDocument {
            minutesTextView.setSelectedRange(NSRange(location: 0, length: 0))
            contentView.scroll(to: .zero)
            minutesTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        } else {
            let length = rendered.length
            minutesTextView.selectedRanges = selections.map { value in
                let range = value.rangeValue
                let start = min(range.location, length)
                return NSValue(range: NSRange(location: start, length: min(range.length, length - start)))
            }
            contentView.scroll(to: origin)
        }
        reflectScrolledClipView(contentView)
    }
}

private final class MinutesReadOnlyTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, openFindBar(for: event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !openFindBar(for: event) { super.keyDown(with: event) }
    }

    private func openFindBar(for event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard event.type == .keyDown, modifiers == .command,
              event.charactersIgnoringModifiers?.lowercased() == "f" else { return false }
        let command = NSMenuItem(title: "찾기", action: nil, keyEquivalent: "")
        command.tag = NSTextFinder.Action.showFindInterface.rawValue
        performFindPanelAction(command)
        return true
    }
}
