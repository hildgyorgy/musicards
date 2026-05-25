//
//  WindowAccessor.swift
//

#if os(macOS)
import SwiftUI
import AppKit

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()

        DispatchQueue.main.async {
            guard let window = view.window else { return }

            let size = MacWindowMetrics.contentSize
            window.setContentSize(size)
            window.contentMinSize = size
            window.contentMaxSize = size
            window.contentAspectRatio = size

            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.remove(.titled)

            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovableByWindowBackground = true

            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
