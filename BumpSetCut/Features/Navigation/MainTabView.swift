//
//  MainTabView.swift
//  BumpSetCut
//
//  Root tab container with Home, Feed, and Profile tabs.
//

import SwiftUI

enum AppTab: Int, CaseIterable {
    case home
    case feed
    case search
    case profile
}

struct MainTabView: View {
    @State private var selectedTab: AppTab = .home
    @State private var mediaStore = MediaStore()
    @State private var metadataStore = MetadataStore()
    @State private var navigationState = AppNavigationState()

    @Environment(AuthenticationService.self) private var authService

    var body: some View {
        TabView(selection: $selectedTab) {
            // Home
            NavigationStack {
                HomeView(mediaStore: mediaStore, metadataStore: metadataStore)
            }
            .tag(AppTab.home)
            .tabItem {
                Image(systemName: "house.fill")
                Text("Home")
            }

            // Feed
            NavigationStack {
                if authService.isAuthenticated {
                    SocialFeedView()
                } else {
                    AuthGateView()
                }
            }
            .tag(AppTab.feed)
            .tabItem {
                Image(systemName: "flame.fill")
                Text("Feed")
            }

            // Search
            NavigationStack {
                SearchCommunityView()
            }
            .tag(AppTab.search)
            .tabItem {
                Image(systemName: "magnifyingglass")
                Text("Search")
            }

            // Profile
            NavigationStack {
                ProfileTabView()
            }
            .tag(AppTab.profile)
            .tabItem {
                Image(systemName: "person.fill")
                Text("Profile")
            }
        }
        .tint(.bscOrange)
        .environment(navigationState)
        .onChange(of: navigationState.postedHighlight) { _, highlight in
            if highlight != nil {
                selectedTab = .feed
            }
        }
    }
}
