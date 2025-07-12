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
        MCamera()
            .setCameraScreen(CustomCameraScreen.init)
            .startSession()
        
    }
}

