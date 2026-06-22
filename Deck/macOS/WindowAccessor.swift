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

                if window.toolbar == nil {
                    let customToolbar = NSToolbar()
                    window.toolbar = customToolbar
                }

                window.collectionBehavior.remove(.fullScreenPrimary)
                window.collectionBehavior.remove(.fullScreenAuxiliary)
                
                if let zoomButton = window.standardWindowButton(.zoomButton) {
                    zoomButton.target = window
                    zoomButton.action = #selector(NSWindow.performZoom(_:))
                }
            }

            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }
#endif
