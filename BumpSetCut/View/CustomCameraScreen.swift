//
//  CustomCameraScreen.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/12/25.
//


//
//  CustomCameraView.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/12/25.
//

import SwiftUI
import MijickCamera

struct CustomCameraScreen: MCameraScreen {
    @ObservedObject var cameraManager: CameraManager
    let namespace: Namespace.ID
    let closeMCameraAction: () -> ()


    var body: some View {
        VStack(spacing: 0) {
            createNavigationBar()
            createCameraOutputView()
            createCaptureButton()
        }
    }
}
private extension CustomCameraScreen {
    func createNavigationBar() -> some View {
        Text("This is a Custom Camera View")
            .padding(.top, 12)
            .padding(.bottom, 12)
    }
    func createCaptureButton() -> some View {
        Button(action: captureOutput) { Text("Click to capture") }
            .padding(.top, 12)
            .padding(.bottom, 12)
    }
}
