//
//  OnboardingPage.swift
//  BumpSetCut
//
//  Data model for onboarding tutorial pages
//

import SwiftUI

// MARK: - Onboarding Page

struct OnboardingPage: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let icon: String
    let color: Color

    // MARK: - All Pages

    static let allPages: [OnboardingPage] = [
        OnboardingPage(
            title: "Welcome to BumpSetCut",
            description: "AI-powered rally detection for volleyball videos. Find the best moments automatically.",
            icon: "volleyball.fill",
            color: .bscOrange
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
            color: .bscTeal
        ),
        OnboardingPage(
            title: "Swipe Through Rallies",
            description: "Browse rallies TikTok-style. Save your favorites or remove clips you don't need.",
            icon: "play.circle.fill",
            color: .bscOrange
        ),
        OnboardingPage(
            title: "You're Ready!",
            description: "Start by uploading your first volleyball video and let the AI do the rest.",
            icon: "checkmark.circle.fill",
            color: .bscSuccess
        )
    ]
}
