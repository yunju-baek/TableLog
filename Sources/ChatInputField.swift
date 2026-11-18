import AppKit
import SwiftUI

/// Native text input keeps Korean IME composition separate from the send shortcut.
final class ChatInputTextView: NSTextView {
    var submit: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let modifiers=event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if [UInt16(36), UInt16(76)].contains(event.keyCode), !hasMarkedText() {
            if modifiers.contains(.shift) || modifiers.contains(.option) {
                insertNewline(nil)
            } else if !modifiers.contains(.control), !event.isARepeat {
                submit?()
            }
            return
        }
        super.keyDown(with:event)
    }
}

private final class ChatInputScrollView: NSScrollView {
    var measure: (() -> Void)?
    override func layout() {
        super.layout()
        if let view=documentView as? NSTextView,view.frame.width != contentSize.width {
            view.setFrameSize(NSSize(width:contentSize.width,height:max(contentSize.height,view.frame.height)))
        }
        measure?()
    }
}

struct ChatInputField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let fontSize: CGFloat
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context:Context) -> NSScrollView {
        let scroll=ChatInputScrollView()
        scroll.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true
        let view=ChatInputTextView(frame:.zero)
        view.isRichText=false;view.isEditable=true;view.isSelectable=true;view.allowsUndo=true
        view.drawsBackground=false;view.textColor = .labelColor
        view.isAutomaticQuoteSubstitutionEnabled=false;view.isAutomaticDashSubstitutionEnabled=false
        view.isVerticallyResizable=true;view.isHorizontallyResizable=false;view.autoresizingMask=[.width]
        view.minSize = .zero;view.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        view.textContainerInset=NSSize(width:5,height:6)
        view.textContainer?.widthTracksTextView=true
        view.textContainer?.containerSize=NSSize(width:0,height:CGFloat.greatestFiniteMagnitude)
        view.setAccessibilityLabel("회의 편집 요청")
        view.setAccessibilityHelp("Enter로 전송, Shift+Enter로 줄바꿈")
        view.delegate=context.coordinator
        scroll.documentView=view
        context.coordinator.textView=view
        scroll.measure={ [weak coordinator=context.coordinator] in coordinator?.measure() }
        updateNSView(scroll,context:context)
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let view=scroll.documentView as? ChatInputTextView else { return }
        context.coordinator.parent=self
        view.submit=onSubmit
        if view.font?.pointSize != fontSize { view.font = .systemFont(ofSize:fontSize) }
        if view.string != text {
            view.string=text
            view.setSelectedRange(NSRange(location:(text as NSString).length,length:0))
        }
        context.coordinator.measure()
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent:ChatInputField
        weak var textView:ChatInputTextView?
        init(_ parent:ChatInputField) { self.parent=parent }
        func textDidChange(_ notification:Notification) {
            guard let view=textView else { return }
            parent.text=view.string;measure()
        }
        func measure() {
            guard let view=textView,let container=view.textContainer,let layout=view.layoutManager else { return }
            layout.ensureLayout(for:container)
            let line=ceil(parent.fontSize*1.35)
            let value=min(line*6+12,max(line*2+12,ceil(layout.usedRect(for:container).height)+12))
            guard abs(parent.height-value)>0.5 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,abs(self.parent.height-value)>0.5 else { return }
                self.parent.height=value
            }
        }
    }
}
