//
//  CameraView.swift
//  BumpSetCut
//
//  Simplified camera using MijickCamera
//

import SwiftUI
import MijickCamera

struct CameraView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        MCamera()
            //.setErrorScreen(CustomCameraErrorScreen.init)
            .startSession()
        
    }
}
