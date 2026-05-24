//
//  PanHandleView.swift
//

import SwiftUI
import UIKit

struct PanHandleView: UIViewRepresentable {
    var isEnabled: Bool
    var onTap: (() -> Void)? = nil
    var onBegan: (() -> Void)? = nil
    var onChanged: (CGFloat) -> Void
    var onEnded: (_ translationY: CGFloat, _ velocityY: CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onTap: onTap,
            onBegan: onBegan,
            onChanged: onChanged,
            onEnded: onEnded
        )
    }

    func makeUIView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        view.backgroundColor = .clear

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator

        tap.require(toFail: pan)

        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(pan)

        context.coordinator.tapRecognizer = tap
        context.coordinator.panRecognizer = pan

        return view
    }

    func updateUIView(_ uiView: PassthroughView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded

        context.coordinator.tapRecognizer?.isEnabled = isEnabled
        context.coordinator.panRecognizer?.isEnabled = isEnabled
        uiView.isUserInteractionEnabled = isEnabled
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (() -> Void)?
        var onBegan: (() -> Void)?
        var onChanged: (CGFloat) -> Void
        var onEnded: (_ translationY: CGFloat, _ velocityY: CGFloat) -> Void

        weak var tapRecognizer: UITapGestureRecognizer?
        weak var panRecognizer: UIPanGestureRecognizer?

        init(
            onTap: (() -> Void)?,
            onBegan: (() -> Void)?,
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (_ translationY: CGFloat, _ velocityY: CGFloat) -> Void
        ) {
            self.onTap = onTap
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc
        func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onTap?()
        }

        @objc
        func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translationY = recognizer.translation(in: recognizer.view).y
            let velocityY = recognizer.velocity(in: recognizer.view).y

            switch recognizer.state {
            case .began:
                onBegan?()
            case .changed:
                onChanged(translationY)
            case .ended, .cancelled, .failed:
                onEnded(translationY, velocityY)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if let pan = gestureRecognizer as? UIPanGestureRecognizer,
               let view = pan.view {
                let velocity = pan.velocity(in: view)
                return abs(velocity.y) > abs(velocity.x)
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

final class PassthroughView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
