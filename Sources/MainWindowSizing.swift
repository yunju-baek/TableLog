import AppKit
import SwiftUI

/// Size the owning window once, independently of engine readiness and keyboard focus.
struct MainWindowSizing: NSViewRepresentable {
    static let preferredContentSize = NSSize(width: 1600, height: 960)

    func makeNSView(context: Context) -> WindowAttachmentView { WindowAttachmentView() }
    func updateNSView(_ nsView: WindowAttachmentView, context: Context) {}

    final class WindowAttachmentView: NSView {
        private weak var configuredWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, configuredWindow !== window else { return }
            configuredWindow = window
            // Let SwiftUI attach its content before applying the initial frame.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window,
                      !window.styleMask.contains(.fullScreen),
                      let screen = window.screen ?? NSScreen.main else { return }
                let available = screen.visibleFrame.insetBy(dx: 20, dy: 20)
                let preferred = window.frameRect(forContentRect:
                    NSRect(origin: .zero, size: MainWindowSizing.preferredContentSize)).size
                let size = NSSize(width: min(preferred.width, available.width),
                                  height: min(preferred.height, available.height))
                let frame = NSRect(x: available.midX - size.width / 2,
                                   y: available.midY - size.height / 2,
                                   width: size.width, height: size.height)
                window.setFrame(frame, display: true)
            }
        }
    }
}
