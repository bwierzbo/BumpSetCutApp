//
//  ContentViewModel.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/12/25.
//



import Foundation

@MainActor @Observable class ContentViewModel {
    private(set) var uploadedMedia: [CapturedMedia] = []
}

// MARK: Interaction With Data
extension ContentViewModel {
    func addMedia(_ media: Any) async {
        guard let capturedMedia = await CapturedMedia(media) else { return }
        uploadedMedia.append(capturedMedia)
    }
    func deleteMedia(_ media: CapturedMedia) {
        guard let index = uploadedMedia.firstIndex(of: media) else { return }
        uploadedMedia.remove(at: index)
    }
}


extension ContentViewModel {
    func presentCaptureMediaView() { Task {
        await CapturePicturePopup(viewModel: self).present()
    }}
}
