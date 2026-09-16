//
//  OnboardingPage.swift
//  BumpSetCut
//
//  Data model for onboarding tutorial pages
//

import SwiftUI

// MARK: - Onboarding Page

struct OnboardingPage: Identifiable {
    /// Pages that do something beyond Next — the footer adapts its buttons.
    enum Kind {
        case info
        /// Explains Photos access (background iCloud imports), then the
        /// primary button triggers the real system prompt ("Not Now" skips).
        case photoLibrary
        /// Explains notifications, then the primary button triggers the real
        /// system prompt (with a "Not Now" escape).
        case notifications

        var isPermission: Bool { self != .info }
    }

    let id = UUID()
    let title: String
    let description: String
    let icon: String
    let color: Color
    var kind: Kind = .info

    // MARK: - All Pages

    static let allPages: [OnboardingPage] = [
        OnboardingPage(
            title: "Welcome to BumpSetCut",
            description: "AI-powered rally detection for volleyball videos. Find the best moments automatically.",
            icon: "volleyball.fill",
            color: .bscPrimary
        ),
        OnboardingPage(
            title: "Upload Your Videos",
            description: "Import volleyball videos from your photo library to get started.",
            icon: "square.and.arrow.up",
            color: .bscBlue
        ),
        OnboardingPage(
            title: "AI Processing",
            description: "Our AI analyzes your footage and detects volleyball rallies automatically.",
            icon: "brain.head.profile",
            color: .bscTealText
        ),
        OnboardingPage(
            title: "Swipe Through Rallies",
            description: "Browse rallies in a full-screen swipe feed. Save your favorites or remove clips you don't need.",
            icon: "play.circle.fill",
            color: .bscPrimary
        ),
        OnboardingPage(
            title: "Import Straight from iCloud",
            description: "Allow Photos access so the videos you pick download in the background — even big ones still in iCloud. Keep using the app while they arrive.",
            icon: "photo.on.rectangle.angled",
            color: .bscTealText,
            kind: .photoLibrary
        ),
        OnboardingPage(
            title: "Stay in the Loop",
            description: "Get a heads-up the moment your rallies are ready, and when teammates follow, like, or comment on your posts.",
            icon: "bell.badge.fill",
            color: .bscBlue,
            kind: .notifications
        ),
        OnboardingPage(
            title: "You're Ready!",
            description: "Start by uploading your first volleyball video and let the AI do the rest.",
            icon: "checkmark.circle.fill",
            color: .bscSuccessText
        )
    ]
}
