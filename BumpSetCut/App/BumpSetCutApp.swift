//
//  BumpSetCutApp.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/7/25.
//

import SwiftUI
import AVFoundation
import GoogleSignIn

@main struct BumpSetCutApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appSettings = AppSettings.shared
    @State private var authService = AuthenticationService()
    @State private var networkMonitor = NetworkMonitor()
    @State private var offlineQueue = OfflineQueue()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .withAppSettings()
                .environment(authService)
                .preferredColorScheme(appSettings.appearanceMode.colorScheme)
                .task {
                    await authService.restoreSession()
                }
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                .onChange(of: networkMonitor.isConnected) { _, isConnected in
                    if isConnected {
                        Task {
                            await offlineQueue.drain(using: SupabaseAPIClient.shared)
                        }
                    }
                }
                .fullScreenCover(isPresented: Binding(
                    get: { authService.authState == .needsUsername },
                    set: { _ in }
                )) {
                    UsernamePickerView()
                        .environment(authService)
                        .interactiveDismissDisabled()
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
