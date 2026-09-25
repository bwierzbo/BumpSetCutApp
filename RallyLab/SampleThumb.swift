//
//  SampleThumb.swift
//  RallyLab
//
//  One frame in the Sampler filmstrip: the thumbnail with its boxes, source
//  and review state.
//

import SwiftUI

struct SampleThumb: View {
    let sample: FrameSample
    let isSelected: Bool

    var body: some View {
        Canvas { ctx, size in
            let imgSize = CGSize(width: sample.thumbnail.width, height: sample.thumbnail.height)
            let fit = OverlayGeometry.fittedRect(content: imgSize, in: size)
            ctx.draw(Image(decorative: sample.thumbnail, scale: 1, orientation: .up), in: fit)
            for box in sample.boxes {
                ctx.stroke(Path(OverlayGeometry.rect(box.rect, turns: 0, in: fit)),
                           with: .color(box.confidence == nil ? .green : .yellow), lineWidth: 1.5)
            }
            if !sample.keep {
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.6)))
            }
        }
        .frame(width: 168, height: 100)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 3) {
                Circle().fill(sourceColor).frame(width: 6, height: 6)
                Text(caption)
            }
            .font(.system(size: 9, design: .monospaced))
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(.black.opacity(0.55))
            .foregroundStyle(.white)
            .padding(3)
        }
        .overlay(alignment: .topTrailing) {
            if sample.reviewed {
                Image(systemName: sample.keep ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(sample.keep ? .green : .red)
                    .padding(3)
            }
        }
        .opacity(sample.keep ? 1 : 0.6)
    }

    private var caption: String {
        if case .file = sample.source {
            return (sample.file as NSString).lastPathComponent
        }
        return String(format: "%.1fs · %@", sample.time, sample.source.label)
    }

    private var sourceColor: Color {
        switch sample.source {
        case .rally: return .yellow
        case .missed: return .orange
        case .random: return .cyan
        case .file: return .purple
        }
    }
}
