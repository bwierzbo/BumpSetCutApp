//
//  BumpSetCutApp.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/7/25.
//

import SwiftUI

// App delegate to control orientation
class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.portrait
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
}

@main
struct BumpSetCutApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // Lock app to portrait by default
                    AppDelegate.orientationLock = .portrait
                    UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
                }
        }
    }
}

// Helper function to force orientation (can be used anywhere in your app)
func setOrientation(_ orientation: UIInterfaceOrientationMask) {
    if orientation == .portrait {
        UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
    }
    AppDelegate.orientationLock = orientation
    
    // Force the orientation update
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
    }
}
