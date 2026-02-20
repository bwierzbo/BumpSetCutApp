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
    @State private var appSettings = AppSettings.shared
    @State private var authService = AuthenticationService()
    @State private var networkMonitor = NetworkMonitor.shared
    @State private var offlineQueue = OfflineQueue()

    init() {
        // UI Testing launch arguments
        if CommandLine.arguments.contains("--uitesting") {
            if CommandLine.arguments.contains("--skip-onboarding") {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            }
            if CommandLine.arguments.contains("--reset-onboarding") {
                UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
            }
            UserDefaults.standard.set(true, forKey: "hasSeenRallyTips")
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
