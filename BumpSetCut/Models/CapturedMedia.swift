
//
//  CapturedMedia.swift of Camera Demo
//
//  Created by Tomasz Kurylik. Sending ❤️ from Kraków!
//    - Mail: tomasz.kurylik@mijick.com
//    - GitHub: https://github.com/FulcrumOne
//    - Medium: https://medium.com/@mijick
//
//  Copyright ©2024 Mijick. All rights reserved.


import SwiftUI
import AVKit

@MainActor struct CapturedMedia: Equatable {
    let id = UUID()
    let filePath: String
    let image: Image
    let title: String
    let date: Date
    let duration: Duration?

    var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent(filePath)
    }

    init?(_ data: Any) async {
        if let image = data as? UIImage { self.init(image: image) }
        else if let videoURL = data as? URL { await self.init(videoURL: videoURL) }
        else { return nil }
    }
}
private extension CapturedMedia {
    init(image: UIImage) {
        self.image = .init(uiImage: image)
        self.title = UUID().uuidString
        self.date = .init()
        self.duration = nil
        self.filePath = ""
    }
    init?(videoURL: URL) async {
        guard let (videoDuration, videoThumbnail) = try? await AVURLAsset(url: videoURL).getVideoDetails() else { return nil }

        self.image = .init(uiImage: videoThumbnail)
        self.title = UUID().uuidString
        self.date = .init()
        self.duration = videoDuration
        self.filePath = videoURL.lastPathComponent
    }
}
