//
//  CameraView.swift
//  BumpSetCut
//
//  Simplified camera using MijickCamera
//

import SwiftUI
import MijickCamera

struct CameraView: View {
    var viewModel: CameraViewModel = .init()
    
    var body: some View {
        ZStack {
            MCamera()
                .lockCameraInPortraitOrientation(AppDelegate.self)
                .setCameraOutputType(.video)
                .setCameraScreen(CustomCameraScreen.init)
                .onVideoCaptured(onVideoCaptured)
                .startSession()
        }
        .frame(maxHeight: .infinity)
    }
}

private extension CameraView {
    func onVideoCaptured(_ videoURL: URL, _ controller: MCamera.Controller) { Task {
        await viewModel.addMedia(videoURL)
        controller.closeMCamera()
    }}
}
