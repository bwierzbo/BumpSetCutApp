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
    func onImageCaptured(_ image: UIImage, _ controller: MCamera.Controller) { Task {
        await mediaStore.addMedia(image)
        controller.closeMCamera()
    }}
    func onVideoCaptured(_ videoURL: URL, _ controller: MCamera.Controller) { Task {
        if let savedURL = saveVideoToDocuments(originalURL: videoURL) {
                await mediaStore.addMedia(savedURL)
            } else {
                print("❌ Failed to save video to Documents")
            }
            controller.closeMCamera()
    }}
    func saveVideoToDocuments(originalURL: URL) -> URL? {
        let fileManager = FileManager.default
        let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let filename = UUID().uuidString + ".mp4"
        let destinationURL = docsURL.appendingPathComponent(filename)

        do {
            try fileManager.moveItem(at: originalURL, to: destinationURL)
            return destinationURL
        } catch {
            print("❌ Error moving video to Documents: \(error)")
            return nil
        }
    }

}
