//
//  TrimFilmstrip.swift
//  RallyLab
//
//  Thumbnails across a window of the video with the selection bright
//  between two handles and the rest dimmed; click to show a moment, drag a
//  handle to move that end. The trim step and the rally check both use it.
//

import AVFoundation
import SwiftUI

struct TrimFilmstrip: View {
    let asset: AVAsset?
    let window: ClosedRange<Double>
    @Binding var start: Double
    @Binding var end: Double
    let time: Double
    let onScrub: (Double) -> Void
    /// A handle was let go at the strip's start (true) or end edge.
    let onEdge: (Bool) -> Void
    @State private var thumbs: [CGImage] = []
    @State private var dragging: Bool?

    /// The filmstrip covers this much either side of a rally to begin with.
    static let reach = 3.0
    private static let count = 12
    static let minLength = 0.5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, span = max(window.upperBound - window.lowerBound, 0.1)
            let x = { (t: Double) in CGFloat((t - window.lowerBound) / span) * w }
            let t = { (x: CGFloat) in window.lowerBound + Double(min(max(x, 0), w) / w) * span }
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(thumbs.indices, id: \.self) { i in
                        Image(decorative: thumbs[i], scale: 1)
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: w / CGFloat(Self.count), height: geo.size.height).clipped()
                    }
                }
                .frame(width: w, height: geo.size.height, alignment: .leading)
                .background(Color.black)
                Color.black.opacity(0.6).frame(width: max(0, x(start)))
                Color.black.opacity(0.6).frame(width: max(0, w - x(end))).offset(x: x(end))
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange, lineWidth: 3)
                    .frame(width: max(8, x(end) - x(start))).offset(x: x(start))
                    .allowsHitTesting(false)
                Rectangle().fill(.white).frame(width: 2).offset(x: x(time) - 1).allowsHitTesting(false)
                handle.offset(x: x(start) - 7)
                handle.offset(x: x(end) - 7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    // The handle nearest where the drag began moves; a click
                    // away from both just shows that moment.
                    if dragging == nil {
                        let a = abs(drag.startLocation.x - x(start)), b = abs(drag.startLocation.x - x(end))
                        dragging = min(a, b) < 18 ? (a <= b) : nil
                        if dragging == nil { onScrub(t(drag.location.x)); return }
                    }
                    guard let isStart = dragging else { return }
                    let v = t(drag.location.x)
                    if isStart { start = min(v, end - Self.minLength) } else { end = max(v, start + Self.minLength) }
                    onScrub(isStart ? start : end)
                }
                .onEnded { _ in
                    // Pushed to the edge: there's more video that way.
                    if let isStart = dragging {
                        let slack = 0.02 * (window.upperBound - window.lowerBound)
                        if isStart ? start - window.lowerBound < slack : window.upperBound - end < slack { onEdge(isStart) }
                    }
                    dragging = nil
                })
        }
        // Again once the clip's length is known (the window widens to it).
        .task(id: "\(asset != nil) \(window)") { await loadThumbs() }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.orange)
            .frame(width: 14)
            .overlay(Capsule().fill(.white.opacity(0.85)).frame(width: 3, height: 18))
            .allowsHitTesting(false)
    }

    private func loadThumbs() async {
        guard let asset else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let step = (window.upperBound - window.lowerBound) / Double(Self.count)
        var images: [CGImage] = []
        for i in 0..<Self.count {
            let at = CMTime(seconds: window.lowerBound + (Double(i) + 0.5) * step, preferredTimescale: 600)
            guard let image = try? await generator.image(at: at).image else { continue }
            images.append(image)
        }
        thumbs = images
    }
}
