import SwiftUI

// MARK: - Rally Peek Preview

struct RallyPeekPreview: View {
    let peekProgress: Double
    let peekDirection: RallyPeekDirection?
    let thumbnail: UIImage?
    let videoScale: CGFloat
    let swipeRotation: Double
    let geometry: GeometryProxy

    var body: some View {
        Group {
            if peekProgress > 0.0, let direction = peekDirection {
                peekStickyNoteView(direction: direction)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: peekProgress)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: peekDirection)
            }
        }
    }

    private func peekStickyNoteView(direction: RallyPeekDirection) -> some View {
        peekFrameContent
            .frame(width: min(geometry.size.width * 0.9, geometry.size.width - 40))
            .aspectRatio(16/9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .scaleEffect(calculateStickyNoteScale())
            .rotationEffect(calculateStickyNoteRotation())
            .offset(calculateStickyNoteOffset(direction: direction))
            .opacity(calculateStickyNoteOpacity())
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: peekProgress)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: videoScale)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: swipeRotation)
            .zIndex(1.5)
    }

    private var peekFrameContent: some View {
        ZStack {
            Color.black
                .aspectRatio(16/9, contentMode: .fit)

            if let image = thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.gray)

                    Text("Preview")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Calculations

    private func calculateStickyNoteScale() -> CGFloat {
        let baseScale: CGFloat = 0.95
        let peekScale = baseScale + (peekProgress * 0.05)
        return peekScale * videoScale
    }

    private func calculateStickyNoteRotation() -> Angle {
        let counterRotation = -swipeRotation * 0.3
        return Angle(degrees: counterRotation)
    }

    private func calculateStickyNoteOffset(direction: RallyPeekDirection) -> CGSize {
        let maxOffset: CGFloat = 30
        let progressOffset = maxOffset * (1.0 - peekProgress)

        switch direction {
        case .next:
            return CGSize(width: 0, height: progressOffset)
        case .previous:
            return CGSize(width: 0, height: -progressOffset)
        }
    }

    private func calculateStickyNoteOpacity() -> Double {
        return Double(peekProgress) * 0.85
    }
}

// MARK: - Preview

#Preview {
    GeometryReader { geometry in
        ZStack {
            Color.black
            RallyPeekPreview(
                peekProgress: 0.5,
                peekDirection: .next,
                thumbnail: nil,
                videoScale: 1.0,
                swipeRotation: 0.0,
                geometry: geometry
            )
        }
    }
}
