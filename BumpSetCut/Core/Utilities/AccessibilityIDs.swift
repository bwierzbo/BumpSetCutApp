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
        static let toggleMode = "authGate.toggleMode"
        static let usernameField = "authGate.username"
        static let emailField = "authGate.email"
        static let passwordField = "authGate.password"
        static let confirmPasswordField = "authGate.confirmPassword"
        static let forgotPassword = "authGate.forgotPassword"
    }

    enum Feed {
        static let forYouTab = "feed.forYou"
        static let followingTab = "feed.following"
        static let emptyState = "feed.emptyState"
        static let refreshButton = "feed.refresh"
        static let highlightCard = "feed.highlightCard"
        static let likeButton = "feed.like"
        static let commentButton = "feed.comment"
        static let profileButton = "feed.profile"
    }

    enum Comments {
        static let inputField = "comments.input"
        static let sendButton = "comments.send"
        static let emptyState = "comments.emptyState"
        static let commentRow = "comments.row"
    }

    enum Profile {
        static let editProfileButton = "profile.editProfile"
        static let signOutButton = "profile.signOut"
        static let followButton = "profile.follow"
        static let highlightsCount = "profile.highlightsCount"
        static let followersCount = "profile.followersCount"
        static let followingCount = "profile.followingCount"
        static let highlightsGrid = "profile.highlightsGrid"
        static let username = "profile.username"
        static let bio = "profile.bio"
        static let emptyHighlights = "profile.emptyHighlights"
    }

    enum Search {
        static let searchField = "search.field"
        static let usersScope = "search.users"
        static let postsScope = "search.posts"
        static let trendingSection = "search.trending"
        static let userRow = "search.userRow"
        static let postCell = "search.postCell"
        static let emptyResult = "search.emptyResult"
    }

    enum Process {
        static let startButton = "process.startButton"
        static let cancelButton = "process.cancelButton"
        static let saveToLibrary = "process.saveToLibrary"
        static let viewRallies = "process.viewRallies"
        static let doneButton = "process.doneButton"
    }

    enum RallyPlayer {
        static let back = "rallyPlayer.back"
        static let counter = "rallyPlayer.counter"
        static let help = "rallyPlayer.help"
        static let remove = "rallyPlayer.remove"
        static let undo = "rallyPlayer.undo"
        static let save = "rallyPlayer.save"
        static let favorite = "rallyPlayer.favorite"
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
