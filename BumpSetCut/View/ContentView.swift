//
//  ContentView.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/9/25.
//

import SwiftUI

struct ContentView: View {
    @State private var showCamera = false

    var body: some View {
        NavigationView {
            VStack(spacing: 40) {
                Text("🏐 Beach Volleyball MVP")
                    .font(.largeTitle)
                    .bold()

                Button(action: {
                    showCamera = true
                }) {
                    Text("Start New Game")
                        .font(.title2)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Home")
            .fullScreenCover(isPresented: $showCamera) {
                CameraView()
            }
        }
    }
}

#Preview {
    ContentView()
}
