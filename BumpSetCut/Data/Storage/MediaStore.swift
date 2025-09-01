//
//  MediaStore.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/30/25.
//

import Foundation

@MainActor @Observable class MediaStore {
}


extension MediaStore {
    func presentCapturePopup() { Task {
        await CapturePicturePopup(mediaStore: self).present()
    }}
}


