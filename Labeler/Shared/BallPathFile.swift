//
//  BallPathFile.swift
//  RallyLab (macOS and iPhone)
//
//  The pipeline's sightings of the ball over a whole video, kept small:
//  one row per frame it was seen on — time, centre x and y (Vision-
//  normalised, bottom-up, upright) and how big it looked. Made on the Mac
//  (BallPathBuilder), sent to the phone next to the video's clip, and read
//  into BallPath so a press while marking snaps to where the ball changed
//  course anywhere in the video, not just inside rallies tracked by hand.
//

import CoreGraphics
import Foundation

struct BallPathFile: Codable {
    /// [time, x, y, size] per sighting, in time order.
    var seen: [[Double]]

    init(samples: [BallPath.Sample]) {
        func r(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
        seen = samples.sorted { $0.time < $1.time }.map { [r($0.time), r($0.center.x), r($0.center.y), r($0.size)] }
    }

    var samples: [BallPath.Sample] {
        seen.compactMap { row in
            guard row.count == 4 else { return nil }
            return BallPath.Sample(time: row[0], center: CGPoint(x: row[1], y: row[2]), size: row[3])
        }
    }

    /// The file's name next to a clip at `clipPath` in the labeling bucket.
    static func remotePath(forClip clipPath: String) -> String { clipPath + ".ballpath.json" }

    static func load(_ url: URL) -> BallPathFile? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(BallPathFile.self, from: $0) }
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
