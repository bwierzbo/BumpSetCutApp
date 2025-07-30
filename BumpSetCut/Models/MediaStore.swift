//
//  MediaStore.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/30/25.
//

import Foundation

@MainActor @Observable class MediaStore {
    private(set) var uploadedMedia: [CapturedMedia] = []
}

// MARK: Interaction With Data
extension MediaStore {
    func addMedia(_ media: Any) async {
        guard let capturedMedia = await CapturedMedia(media) else { return }
        uploadedMedia.append(capturedMedia)
    }
    func deleteMedia(_ media: CapturedMedia) {
        guard let index = uploadedMedia.firstIndex(of: media) else { return }
        uploadedMedia.remove(at: index)
    }
}


extension MediaStore {
    func presentCapturePopup() { Task {
        await CapturePicturePopup(mediaStore: self).present()
    }}
}


