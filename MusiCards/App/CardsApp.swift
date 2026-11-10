//
//  CardsApp.swift
//  Cards
//
//  Created by Hild György on 2026. 04. 05..
//

import SwiftUI

@main
struct CardsApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(DeviceOrientationDelegate.self) private var orientationDelegate
    #endif
    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            ContentView()
                .frame(
                    width: MacWindowMetrics.contentSize.width,
                    height: MacWindowMetrics.contentSize.height
                )
                .containerBackground(.clear, for: .window)
                .background(WindowAccessor())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(
            width: MacWindowMetrics.contentSize.width,
            height: MacWindowMetrics.contentSize.height
        )
        .windowResizability(.contentSize)
        #else
            WindowGroup {
                ContentView()
            }
        #endif
    }
}

#if os(iOS)
/// Foldable displays and iPads rotate; conventional phones retain portrait.
final class DeviceOrientationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        if let window {
            if #available(iOS 27.1, *),
               !window.reservedRegions(kind: .division, options: .includeInactive).isEmpty {
                return .all
            }
        }
        return [.portrait, .portraitUpsideDown]
    }
}
#endif
