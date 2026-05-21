//
//  SafariView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 08..
//

import SwiftUI

#if os(iOS)
import SafariServices

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

#elseif os(macOS)
import WebKit

struct SafariView: NSViewRepresentable {
    let url: URL
    var onDismiss: (() -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()

        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: url))

        // Add close button as a native subview of the WKWebView
        if let dismiss = onDismiss {
            let button = NSButton(
                            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!,
                            target: context.coordinator,
                            action: #selector(Coordinator.closeTapped)
                        )
                        button.isBordered = false
                        button.contentTintColor = .white
                        button.wantsLayer = true
                        button.layer?.backgroundColor = NSColor.systemBlue.cgColor
                        button.layer?.cornerRadius = 24
            button.translatesAutoresizingMaskIntoConstraints = false

            webView.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: webView.topAnchor, constant: 14),
                button.trailingAnchor.constraint(equalTo: webView.trailingAnchor, constant: -16),
                button.widthAnchor.constraint(equalToConstant: 42),
                button.heightAnchor.constraint(equalToConstant: 42)
            ])

            context.coordinator.onDismiss = dismiss
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject {
        var onDismiss: (() -> Void)?

        @objc func closeTapped() {
            onDismiss?()
        }
    }
}
#endif
