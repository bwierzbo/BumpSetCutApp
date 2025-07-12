//
//  ContentView.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/9/25.
//

import SwiftUI
import MijickCamera

struct ContentView: View {
    @State private var showCamera = false
    @State private var showSavedVideos = false

    var body: some View {
        NavigationView {
            VStack(spacing: 40) {
                Text("🏐 Beach Volleyball MVP")
                    .font(.largeTitle)
                    .bold()

                VStack(spacing: 20) {
                    Button(action: {
                        showCamera = true
                    }) {
                        HStack {
                            Image(systemName: "video.circle.fill")
                                .font(.title2)
                            Text("Start New Game")
                                .font(.title2)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }

                    Button(action: {
                        showSavedVideos = true
                    }) {
                        HStack {
                            Image(systemName: "play.rectangle.fill")
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
                .padding(.horizontal)

                Spacer()
                
            }
            .padding()
            .navigationTitle("Home")
            .navigationBarHidden(true)
            .fullScreenCover(isPresented: $showCamera) {
                CameraView()
            }
        }
    }
}
