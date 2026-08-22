//
//  BarcodeScannerView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 21..
//

#if os(iOS)
import OSLog
import SwiftUI
import VisionKit

struct BarcodeScannerView: UIViewControllerRepresentable {
    nonisolated private static let logger = Logger(
        subsystem: "com.hildgyorgy.MusiCards",
        category: "BarcodeScanner"
    )

    let onCodeScanned: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )

        controller.delegate = context.coordinator

        do {
            try controller.startScanning()
        } catch {
            let nsError = error as NSError
            Self.logger.error(
                "Failed to start barcode scanner domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) detail=\(nsError.localizedDescription, privacy: .private)"
            )
        }

        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCodeScanned: (String) -> Void
        private var didScan = false

        init(onCodeScanned: @escaping (String) -> Void) {
            self.onCodeScanned = onCodeScanned
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !didScan else { return }

            for item in addedItems {
                if case .barcode(let barcode) = item,
                   let payload = barcode.payloadStringValue {
                    didScan = true
                    onCodeScanned(payload)
                    break
                }
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            let nsError = error as NSError
            BarcodeScannerView.logger.error(
                "Barcode scanner became unavailable domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) detail=\(nsError.localizedDescription, privacy: .private)"
            )
        }
    }
}
#endif
