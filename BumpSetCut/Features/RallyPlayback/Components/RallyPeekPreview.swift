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
                    .animation(.bscSnappy, value: peekProgress)
                    .animation(.bscSnappy, value: peekDirection)
            }
        }
    }

    private func peekStickyNoteView(direction: RallyPeekDirection) -> some View {
        peekFrameContent
            .frame(width: min(geometry.size.width * 0.9, geometry.size.width - BSCSpacing.xxl))
            .aspectRatio(16/9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg))
            .scaleEffect(calculateStickyNoteScale())
            .rotationEffect(calculateStickyNoteRotation())
            .offset(calculateStickyNoteOffset(direction: direction))
            .opacity(calculateStickyNoteOpacity())
            .animation(.bscSnappy, value: peekProgress)
            .animation(.bscSnappy, value: videoScale)
            .animation(.bscSnappy, value: swipeRotation)
            .zIndex(1.5)
    }

    private var peekFrameContent: some View {
        ZStack {
            Color.bscMediaBackground
                .aspectRatio(16/9, contentMode: .fit)

            if let image = thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            } else {
                VStack(spacing: BSCSpacing.sm) {
                    Image(systemName: "video.fill")
                        .bscFont(size: 30)
                        .foregroundColor(.bscOnMediaSecondary)

                    Text("Preview")
                        .bscFont(size: 12)
                        .foregroundColor(.bscOnMediaSecondary)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: BSCRadius.lg)
                .stroke(Color.bscOnMedia.opacity(0.2), lineWidth: 1)
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
            Color.bscMediaBackground
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
