//
//  MediaStore.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/30/25.
//

import Foundation

protocol CaptureDelegate: AnyObject {
    func presentCaptureInterface()
}

@MainActor @Observable class MediaStore {
    weak var captureDelegate: CaptureDelegate?
}


extension MediaStore {
    func presentCapturePopup() {
        captureDelegate?.presentCaptureInterface()
    }
}


