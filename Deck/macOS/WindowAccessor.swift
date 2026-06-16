//
//  WindowAccessor.swift
//

#if os(macOS)
    import SwiftUI
    import AppKit

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    struct WindowAccessor: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let view = PassthroughView()

            DispatchQueue.main.async {
                guard let window = view.window else { return }

                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = true
                window.hasShadow = true

                window.collectionBehavior.remove(.fullScreenPrimary)
                window.collectionBehavior.insert(.fullScreenNone)
            }

            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }
#endif
