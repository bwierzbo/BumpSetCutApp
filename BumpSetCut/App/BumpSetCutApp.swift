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
    // Skip the splash under UI testing so screenshots stay deterministic
    @State private var showSplash = !CommandLine.arguments.contains("--uitesting")

    init() {
        // Background continuation for video processing (iOS 26+) must
        // register its task handler before anything can submit one.
        ProcessingBackgroundKeeper.registerAll()

        #if DEBUG
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
            UserDefaults.standard.set(true, forKey: "hasUsedRallyTrim")
            AppSettings.shared.hasUsedRallyTrim = true
            UserDefaults.standard.set(true, forKey: "hasSeenFavoritesOnboarding")
            AppSettings.shared.hasSeenFavoritesOnboarding = true

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
        #endif

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
                        .bscFont(size: 15, weight: .medium)
                        .foregroundColor(.bscPrimaryText)
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
                            await FlywheelCaptureService.shared.drain(using: SupabaseAPIClient.shared)
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
                .overlay {
                    if showSplash {
                        LaunchSplashView {
                            withAnimation(.easeOut(duration: 0.35)) { showSplash = false }
                        }
                    }
                }
        }
    }
}

// MARK: App Delegate
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var orientationLock = UIInterfaceOrientationMask.all

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Configure the audio category for video playback, but do NOT activate
        // the session here. Holding a `.playback` session active app-wide stalls
        // keyboard presentation by seconds on real devices. AVPlayer activates
        // the session on demand when it plays; we release it on keyboard-show.
        AudioSessionManager.configureCategory()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { AppDelegate.orientationLock }

    // MARK: Remote Notifications

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            await DirectMessageService.shared.registerDeviceToken(deviceToken)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("⚠️ APNs registration failed: \(error.localizedDescription)")
    }

    /// Don't banner a message for the thread that's already open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        let conversationId = notification.request.content.userInfo["conversationId"] as? String
        if let conversationId, conversationId == DirectMessageService.shared.activeConversationId {
            return []
        }
        return [.banner, .sound, .badge]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               didReceive response: UNNotificationResponse) async {
        if let conversationId = response.notification.request.content.userInfo["conversationId"] as? String {
            DirectMessageService.shared.pendingConversationId = conversationId
        }
    }
}
