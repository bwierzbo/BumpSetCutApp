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
    var viewModel: ContentViewModel = .init()
    
    //@State private var showCamera = false
    //@State private var showSavedVideos = false
    
    var body: some View {
        VStack(spacing: 0) {
            createScrollableView()
        }
        .padding(.horizontal, 20)
        .background(Color(.systemBackground).ignoresSafeArea())
        .preferredColorScheme(.light)
    }
}

private extension ContentView {
    func createScrollableView() -> some View {
        ScrollView {
            VStack(spacing: 36) {
                createCaptureMediaView()
                createUploadedMediaView()
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
            viewModel.presentCaptureMediaView()
        }
    }
    
    func createUploadedMediaView() -> some View {
        MediaButton {
            viewModel.self
        }
    }
}
