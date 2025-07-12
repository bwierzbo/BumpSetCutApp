//
//  CameraViewModel.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/12/25.
//


import Foundation

@MainActor @Observable class CameraViewModel {
    private(set) var uploadedMedia: [CapturedMedia] = []
}

// MARK: Interaction With Data
extension CameraViewModel {
    func addMedia(_ media: Any) async {
        guard let capturedMedia = await CapturedMedia(media) else { return }
        uploadedMedia.append(capturedMedia)
    }
    func deleteMedia(_ media: CapturedMedia) {
        guard let index = uploadedMedia.firstIndex(of: media) else { return }
        uploadedMedia.remove(at: index)
    }
}

