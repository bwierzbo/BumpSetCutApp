//
//  ContentView.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/9/25.
//

import SwiftUI
import AVKit
import MijickCamera

struct ContentView: View {
    @State private var mediaStore = MediaStore()
    
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                createScrollableView()
            }
            .padding(.horizontal, 20)
            .background(Color(.systemBackground).ignoresSafeArea())
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Scrollable View
private extension ContentView {
    func createScrollableView() -> some View {
        ScrollView {
            VStack(spacing: 36) {
                createTitleHeader()
                createCaptureMediaView()
                createLibraryButton()
            }
            .padding(.top, 32)
            .padding(.bottom, 72)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Header
private extension ContentView {
    func createTitleHeader() -> some View {
        VStack(spacing: 8) {
            Text("🏐")
                .font(.system(size: 56))
            Text("Beach Volleyball MVP")
                .font(.largeTitle)
                .bold()
            Text("Capture rallies and build your highlight reel")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Capture Media
private extension ContentView {
    func createCaptureMediaView() -> some View {
        ActionButton {
            mediaStore.presentCapturePopup()
        }
    }
}

// MARK: - Library Navigation
private extension ContentView {
    func createLibraryButton() -> some View {
        NavigationLink(destination: LibraryView()) {
            HStack {
                Image(systemName: "video.circle.fill")
                    .font(.title2)
                Text("Saved Games")
                    .font(.title2)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [Color.green, Color.blue]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundColor(.white)
            .cornerRadius(12)
        }
    }
}
