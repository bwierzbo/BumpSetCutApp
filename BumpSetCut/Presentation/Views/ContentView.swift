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

private extension ContentView {
    func createScrollableView() -> some View {
        ScrollView {
            VStack(spacing: 36) {
                createTitleHeader()
                createCaptureMediaView()
                createLibraryButton()
            }
            .padding(.top, 12)
            .padding(.bottom, 72)
        }
        .scrollIndicators(.hidden)
    }
}

private extension ContentView {
    func createTitleHeader() -> some View {
        Text("🏐 Beach Volleyball MVP")
            .font(.largeTitle)
            .bold()
    }
}
    
private extension ContentView {
    func createCaptureMediaView() -> some View {
        ActionButton{
                mediaStore.presentCapturePopup()
        }
    }
    
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
            .background(Color.green)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
    }
}
