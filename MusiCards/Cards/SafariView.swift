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
            return webView
        }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

}
#endif
