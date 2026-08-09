//
//  PanHandleView.swift
//

#if os(macOS)
import SwiftUI
import AppKit

struct PanHandleView: NSViewRepresentable {
    var isEnabled: Bool
    var onTap: (() -> Void)? = nil
    var onBegan: (() -> Void)? = nil
    var onChanged: (CGFloat) -> Void
    var onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true

        let pan = NSPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick(_:))
        )
        click.delegate = context.coordinator
        view.addGestureRecognizer(click)

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var parent: PanHandleView

        init(_ parent: PanHandleView) {
            self.parent = parent
        }

        @objc func handleClick(_ recognizer: NSClickGestureRecognizer) {
            guard parent.isEnabled else { return }

            if recognizer.state == .ended {
                parent.onTap?()
            }
        }

        @objc func handlePan(_ recognizer: NSPanGestureRecognizer) {
            guard parent.isEnabled, let view = recognizer.view else { return }

            let translation = recognizer.translation(in: view).y
            let velocity = recognizer.velocity(in: view).y

            switch recognizer.state {
            case .began:
                parent.onBegan?()

            case .changed:
                parent.onChanged(translation)

            case .ended, .cancelled, .failed:
                parent.onEnded(translation, velocity)

            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif
