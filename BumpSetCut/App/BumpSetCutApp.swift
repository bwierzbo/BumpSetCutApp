//
//  BumpSetCutApp.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/7/25.
//

import SwiftUI
import AVFoundation

@main struct BumpSetCutApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var authService = AuthenticationService()
    @State private var networkMonitor = NetworkMonitor()
    @State private var offlineQueue = OfflineQueue()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .withAppSettings()
                .environment(authService)
                .task {
                    await authService.restoreSession()
                }
                .onChange(of: networkMonitor.isConnected) { _, isConnected in
                    if isConnected {
                        Task {
                            await offlineQueue.drain(using: SupabaseAPIClient.shared)
                        }
                    }
                }
        }
    }
}

// MARK: App Delegate
class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.all

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Configure audio session for video playback with audio
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            print("✅ Audio session configured for video playback")
        } catch {
            print("❌ Failed to configure audio session: \(error)")
        }

        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { AppDelegate.orientationLock }
}
