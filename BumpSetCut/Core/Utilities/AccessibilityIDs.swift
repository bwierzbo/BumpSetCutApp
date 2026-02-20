//
//  AccessibilityIDs.swift
//  BumpSetCut
//
//  Centralized accessibility identifiers for UI testing.
//  Use .accessibilityIdentifier() — separate from user-facing .accessibilityLabel().
//

import Foundation

enum AccessibilityID {

    enum Tab {
        static let home = "tab.home"
        static let feed = "tab.feed"
        static let search = "tab.search"
        static let profile = "tab.profile"
    }

    enum Home {
        static let viewLibrary = "home.viewLibrary"
        static let favoriteRallies = "home.favoriteRallies"
        static let upload = "home.upload"
        static let process = "home.process"
        static let help = "home.help"
        static let settings = "home.settings"
        static let statsCard = "home.statsCard"
    }

    enum Onboarding {
        static let skip = "onboarding.skip"
        static let next = "onboarding.next"
        static let getStarted = "onboarding.getStarted"
        static func page(_ index: Int) -> String { "onboarding.page.\(index)" }
    }

    enum Settings {
        static let done = "settings.done"
        static let analytics = "settings.analytics"
        static let thoroughAnalysis = "settings.thoroughAnalysis"
        static let themeLight = "settings.theme.light"
        static let themeDark = "settings.theme.dark"
        static let themeSystem = "settings.theme.system"
        static let signOut = "settings.signOut"
        static let upgrade = "settings.upgrade"
        static let privacyPolicy = "settings.privacyPolicy"
        static let termsOfService = "settings.termsOfService"
        static let communityGuidelines = "settings.communityGuidelines"
        static let appName = "settings.appName"
        static let appVersion = "settings.appVersion"
    }

    enum Library {
        static let emptyState = "library.emptyState"
        static let sortMenu = "library.sortMenu"
        static let createFolder = "library.createFolder"
        static let folderNameField = "library.folderNameField"
        static let filterAll = "library.filter.all"
        static let filterProcessed = "library.filter.processed"
        static let filterUnprocessed = "library.filter.unprocessed"
    }

    enum Favorites {
        static let emptyState = "favorites.emptyState"
        static let sortMenu = "favorites.sortMenu"
        static let createFolder = "favorites.createFolder"
        static let rallyCount = "favorites.rallyCount"
    }

    enum AuthGate {
        static let emailSignIn = "authGate.emailSignIn"
        static let skip = "authGate.skip"
    }

    enum Export {
        static let individualOption = "export.individual"
        static let combinedOption = "export.combined"
        static let shareButton = "export.share"
        static let retryButton = "export.retry"
        static let cancelButton = "export.cancel"
        static let doneButton = "export.done"
    }
}
