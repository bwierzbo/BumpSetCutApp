//
//  SaveVideoView.swift
//  BumpSetCut
//
//  Updated to save videos internally instead of to photo library
//

import SwiftUI
import AVKit

struct SaveVideoView: View {
    @EnvironmentObject var model: CameraModel
    @StateObject private var storageManager = VideoStorageManager.shared
    
    @State private var saved = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var player: AVPlayer?
    
    private let headerHeight: CGFloat = 90.0

    var body: some View {
        GeometryReader { geometry in
            if let url = model.movieFileUrl {
                ZStack {
                    // Video player
                    if let player = player {
                        VideoPlayer(player: player)
                            .ignoresSafeArea()
                            .onAppear {
                                player.play()
                            }
                    } else {
                        Color.black
                            .ignoresSafeArea()
                    }
                    
                    // Control overlay
                    VStack {
                        buttonsView()
                            .frame(height: headerHeight)
                            .frame(maxWidth: .infinity)
                            .background(.black.opacity(0.7))
                        
                        Spacer()
                    }
                }
                .background(Color.black)
                .onAppear {
                    player = AVPlayer(url: url)
                }
                .onDisappear {
                    player?.pause()
                    player = nil
                    
                    // Clean up temp file only if we're leaving without saving
                    if !saved {
                        Task {
                            try? FileManager().removeItem(at: url)
                        }
                    }
                }
                .alert("Error", isPresented: $showError) {
                    Button("OK") { }
                } message: {
                    Text(errorMessage)
                }
                .statusBarHidden(true)
            }
        }
    }
    
    private func buttonsView() -> some View {
        HStack {
            Button {
                // Go back without saving
                model.movieFileUrl = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.white)
            }

            Spacer()

            Button {
                guard let url = model.movieFileUrl else { return }
                
                // Save to internal storage
                storageManager.saveVideo(from: url) { result in
                    switch result {
                    case .success:
                        withAnimation {
                            self.saved = true
                        }
                        
                        // Wait a moment to show checkmark, then dismiss
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            model.movieFileUrl = nil
                        }
                        
                    case .failure(let error):
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            } label: {
                Image(systemName: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                    .foregroundStyle(saved ? Color.green : Color.white)
            }
            .disabled(saved)

        }
        .font(.system(size: 32))
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 32)
        .padding(.top, 32)
    }
}
