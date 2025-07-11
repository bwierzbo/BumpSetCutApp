//
//  CameraView.swift
//  SwiftUIDemo2
//
//  Created by Itsuki on 2024/05/18.
//


import SwiftUI

struct CameraView: View {
    @StateObject private var model = CameraModel()

    var body: some View {
        ZStack {
            if let _ = model.movieFileUrl {
                SaveVideoView()
            } else {
                PreviewView()
                    .onAppear {
                        model.camera.isPreviewPaused = false
                    }
                    .onDisappear {
                        model.camera.isPreviewPaused = true
                    }
            }
        }
        .task {
            await model.camera.start()
        }
        .ignoresSafeArea(.all)
        .environmentObject(model)
    }
}

#Preview {
    @StateObject var model = CameraModel()
    return PreviewView()
        .environmentObject(model)
}
