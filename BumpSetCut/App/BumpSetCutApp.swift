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
    @State private var appSettings = AppSettings.shared
    @State private var authService = AuthenticationService()
    @State private var networkMonitor = NetworkMonitor.shared
    @State private var offlineQueue = OfflineQueue()

    init() {
        // UI Testing launch arguments
        if CommandLine.arguments.contains("--uitesting") {
            if CommandLine.arguments.contains("--skip-onboarding") {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                AppSettings.shared.hasCompletedOnboarding = true
            }
            if CommandLine.arguments.contains("--reset-onboarding") {
                UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                AppSettings.shared.hasCompletedOnboarding = false
            }
            UserDefaults.standard.set(true, forKey: "hasSeenRallyTips")
            AppSettings.shared.hasSeenRallyTips = true

            // Clear library for a clean test slate
            if CommandLine.arguments.contains("--clear-library") {
                let storageDir = StorageManager.getPersistentStorageDirectory()
                try? FileManager.default.removeItem(at: storageDir)
            }
        }

        // Dev convenience: prefill library with sample videos
        if CommandLine.arguments.contains("--prefill-library") {
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            AppSettings.shared.hasCompletedOnboarding = true
            UserDefaults.standard.set(true, forKey: "hasSeenRallyTips")
            AppSettings.shared.hasSeenRallyTips = true
        }

        // Clear stale Keychain data on fresh install / reinstall
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            try? KeychainHelper.delete(for: "auth_token")
            try? KeychainHelper.delete(for: "cached_user")
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .withAppSettings()
                .environment(authService)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.bscOrange)
                    }
                }
                .preferredColorScheme(appSettings.appearanceMode.colorScheme)
                // Free the audio session as the keyboard comes up so text entry
                // isn't stalled by audio routing. No-op while video is playing.
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    AudioSessionManager.deactivateIfIdle()
                }
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
        // Configure the audio category for video playback, but do NOT activate
        // the session here. Holding a `.playback` session active app-wide stalls
        // keyboard presentation by seconds on real devices. AVPlayer activates
        // the session on demand when it plays; we release it on keyboard-show.
        AudioSessionManager.configureCategory()
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { AppDelegate.orientationLock }
}
