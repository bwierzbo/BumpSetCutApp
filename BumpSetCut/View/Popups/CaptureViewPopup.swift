//
//  CaptureViewPopup.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/12/25.
//


import SwiftUI
import MijickCamera
import MijickPopups

struct CapturePicturePopup: BottomPopup {
    let mediaStore: MediaStore
    @State private var shouldShowCamera: Bool = false


    func configurePopup(config: BottomPopupConfig) -> BottomPopupConfig { config
        .heightMode(.fullscreen)
        .backgroundColor(.black)
        .enableDragGesture(false)
    }
    var body: some View {
        ZStack { if shouldShowCamera {
            MCamera()
                .lockCameraInPortraitOrientation(AppDelegate.self)
                .setCameraOutputType(.video)
                .setCloseMCameraAction(closeMCameraAction)
                .onVideoCaptured(onVideoCaptured)
                .startSession()
        }}
        .frame(maxHeight: .infinity)
        .onAppear(perform: onAppear)
    }
}

private extension CapturePicturePopup {
    func onAppear() { Task {
        try await Task.sleep(nanoseconds: 500_000_000)
        shouldShowCamera = true
    }}
    func closeMCameraAction() { Task {
        await dismissLastPopup()
    }}
   // func onImageCaptured(_ image: UIImage, _ controller: MCamera.Controller) { Task {
   //     await mediaStore.addMedia(image)
   //     controller.closeMCamera()
   // }}
    func onVideoCaptured(_ videoURL: URL, _ controller: MCamera.Controller) { Task {
        let fileName = UUID().uuidString + ".mp4"
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let destinationURL = documentsURL.appendingPathComponent(fileName)

            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: videoURL, to: destinationURL)
            } catch {
                print("Failed to move video: \(error)")
            }
        controller.closeMCamera()
    }}
}
