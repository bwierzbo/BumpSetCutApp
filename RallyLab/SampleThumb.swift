//
//  SampleThumb.swift
//  RallyLab
//
//  One frame in the Sampler filmstrip: the thumbnail with its boxes, a strip
//  in its source's colour, and its review state.
//

import SwiftUI

struct SampleThumb: View {
    let sample: FrameSample
    let isSelected: Bool
    @State private var hovering = false

    private static let height: CGFloat = 66
    /// The frame's own shape, so portrait video shows narrow thumbnails
    /// rather than a sliver in a wide black box.
    private var width: CGFloat {
        let aspect = CGFloat(sample.thumbnail.width) / CGFloat(max(sample.thumbnail.height, 1))
        return min(max(Self.height * aspect, 44), 118)
    }

    var body: some View {
        Canvas { ctx, size in
            let imgSize = CGSize(width: sample.thumbnail.width, height: sample.thumbnail.height)
            let fit = OverlayGeometry.fittedRect(content: imgSize, in: size)
            ctx.draw(Image(decorative: sample.thumbnail, scale: 1, orientation: .up), in: fit)
            for box in sample.boxes {
                let r = OverlayGeometry.rect(box.rect, turns: 0, in: fit)
                let color = ReviewStyle.color(box, confirmed: sample.reviewed && sample.keep)
                // Balls are a pixel or two here: mark them with a dot-ring.
                let ring = max(r.width, r.height) / 2 + 3
                ctx.stroke(Path(ellipseIn: CGRect(x: r.midX - ring, y: r.midY - ring, width: 2 * ring, height: 2 * ring)),
                           with: .color(color), lineWidth: 1.5)
            }
            if !sample.keep {
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.6)))
            }
        }
        .frame(width: width, height: Self.height)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            ReviewStyle.sourceColor(sample.source).frame(height: 3)
        }
        .overlay(alignment: .topTrailing) {
            if sample.reviewed {
                Image(systemName: !sample.keep ? "eye.slash.fill" : sample.boxes.isEmpty ? "circle.slash" : "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(sample.keep && !sample.boxes.isEmpty ? ReviewStyle.yours : Color.white.opacity(0.85))
                    .background(Circle().fill(.black.opacity(0.5)).padding(-1))
                    .padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(hovering ? 0.35 : 0.08),
                              lineWidth: isSelected ? 2.5 : 1)
        )
        .shadow(color: isSelected ? Color.accentColor.opacity(0.45) : .clear, radius: 6)
        .scaleEffect(isSelected ? 1.04 : 1)
        .opacity(sample.keep ? 1 : 0.55)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .onHover { hovering = $0 }
        .help(sample.source == .file
              ? (sample.file as NSString).lastPathComponent
              : String(format: "%@ · %.1f s", ReviewStyle.sourceName(sample.source), sample.time))
    }
}
