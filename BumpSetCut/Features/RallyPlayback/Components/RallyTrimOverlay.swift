import SwiftUI
import AVFoundation

// MARK: - Rally Trim Overlay (Apple Photos-style filmstrip)

struct RallyTrimOverlay: View {
    @Binding var trimBefore: Double
    @Binding var trimAfter: Double
    let rallyStartTime: Double
    let rallyEndTime: Double
    let videoURL: URL
    let videoDuration: Double
    let onScrub: (Double) -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private let maxBuffer: Double = 3.0
    private let handleWidth: CGFloat = 14
    private let barHeight: CGFloat = 56
    private let borderThickness: CGFloat = 3
    private let minSelectionDuration: Double = 1.0

    @State private var thumbnails: [UIImage] = []
    @State private var leftDragBase: Double?
    @State private var rightDragBase: Double?

    // Time window visible in the filmstrip
    private var windowStart: Double { max(0, rallyStartTime - maxBuffer) }
    private var windowEnd: Double { min(videoDuration, rallyEndTime + maxBuffer) }
    private var windowDuration: Double { windowEnd - windowStart }

    // Current effective trim boundaries
    private var effectiveStart: Double { rallyStartTime - trimBefore }
    private var effectiveEnd: Double { rallyEndTime + trimAfter }
    private var selectionDuration: Double { effectiveEnd - effectiveStart }

    var body: some View {
        ZStack {
            // Dim backdrop (no tap-to-cancel — use Cancel button)
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Cancel / Duration / Done
                HStack {
                    Button("Cancel") { onCancel() }
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                    Spacer()
                    Text(formatDuration(selectionDuration))
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundColor(.bscPrimary)
                    Spacer()
                    Button("Done") { onConfirm() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.bscPrimary)
                }
                .padding(.horizontal, BSCSpacing.xl)
                .padding(.bottom, BSCSpacing.md)

                // Filmstrip trim bar
                GeometryReader { geo in
                    trimBar(totalWidth: geo.size.width)
                }
                .frame(height: barHeight)
                .padding(.horizontal, BSCSpacing.lg)
                .padding(.bottom, BSCSpacing.huge)
            }
        }
        .task { await generateThumbnails() }
    }

    // MARK: - Trim Bar

    @ViewBuilder
    private func trimBar(totalWidth: CGFloat) -> some View {
        let leftX = xForTime(effectiveStart, in: totalWidth)
        let rightX = xForTime(effectiveEnd, in: totalWidth)

        ZStack(alignment: .leading) {
            // 1. Filmstrip thumbnails (full width)
            filmstrip(width: totalWidth)

            // 2. Dim overlay left of selection
            Rectangle()
                .fill(Color.black.opacity(0.5))
                .frame(width: max(0, leftX), height: barHeight)
                .allowsHitTesting(false)

            // 3. Dim overlay right of selection
            Rectangle()
                .fill(Color.black.opacity(0.5))
                .frame(width: max(0, totalWidth - rightX), height: barHeight)
                .offset(x: rightX)
                .allowsHitTesting(false)

            // 4. Yellow top/bottom borders between handles
            let innerWidth = max(0, rightX - leftX - 2 * handleWidth)
            VStack(spacing: 0) {
                Rectangle().fill(Color.bscPrimary).frame(height: borderThickness)
                Spacer()
                Rectangle().fill(Color.bscPrimary).frame(height: borderThickness)
            }
            .frame(width: innerWidth, height: barHeight)
            .offset(x: leftX + handleWidth)
            .allowsHitTesting(false)

            // 5. Left handle (offset accounts for hit padding)
            trimHandle(isLeft: true)
                .offset(x: leftX - handleHitPadding)
                .gesture(leftHandleDrag(totalWidth: totalWidth))

            // 6. Right handle (offset accounts for hit padding)
            trimHandle(isLeft: false)
                .offset(x: rightX - handleWidth - handleHitPadding)
                .gesture(rightHandleDrag(totalWidth: totalWidth))
        }
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm))
    }

    // MARK: - Filmstrip

    @ViewBuilder
    private func filmstrip(width: CGFloat) -> some View {
        if thumbnails.isEmpty {
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: width, height: barHeight)
        } else {
            HStack(spacing: 0) {
                ForEach(thumbnails.indices, id: \.self) { i in
                    Image(uiImage: thumbnails[i])
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(thumbnails.count), height: barHeight)
                        .clipped()
                }
            }
            .frame(width: width, height: barHeight)
        }
    }

    // MARK: - Handle

    private let handleHitPadding: CGFloat = 12  // Extra hit area on each side

    @ViewBuilder
    private func trimHandle(isLeft: Bool) -> some View {
        ZStack {
            // Invisible wider hit area
            Color.clear
                .frame(width: handleWidth + handleHitPadding * 2, height: barHeight)
                .contentShape(Rectangle())

            // Visible handle
            UnevenRoundedRectangle(
                topLeadingRadius: isLeft ? BSCRadius.sm : 0,
                bottomLeadingRadius: isLeft ? BSCRadius.sm : 0,
                bottomTrailingRadius: isLeft ? 0 : BSCRadius.sm,
                topTrailingRadius: isLeft ? 0 : BSCRadius.sm
            )
            .fill(Color.bscPrimary)
            .frame(width: handleWidth, height: barHeight)
            .overlay(
                Image(systemName: isLeft ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.white)
            )
            .allowsHitTesting(false)
        }
    }

    // MARK: - Gestures

    private func leftHandleDrag(totalWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if leftDragBase == nil { leftDragBase = trimBefore }
                let baseX = xForTime(rallyStartTime - (leftDragBase ?? 0), in: totalWidth)
                let newTime = timeForX(baseX + value.translation.width, in: totalWidth)
                let clamped = max(windowStart, min(newTime, effectiveEnd - minSelectionDuration))
                trimBefore = rallyStartTime - clamped
                onScrub(clamped)
            }
            .onEnded { _ in leftDragBase = nil }
    }

    private func rightHandleDrag(totalWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if rightDragBase == nil { rightDragBase = trimAfter }
                let baseX = xForTime(rallyEndTime + (rightDragBase ?? 0), in: totalWidth)
                let newTime = timeForX(baseX + value.translation.width, in: totalWidth)
                let clamped = min(windowEnd, max(newTime, effectiveStart + minSelectionDuration))
                trimAfter = clamped - rallyEndTime
                onScrub(clamped)
            }
            .onEnded { _ in rightDragBase = nil }
    }

    // MARK: - Position Mapping

    private func xForTime(_ time: Double, in width: CGFloat) -> CGFloat {
        guard windowDuration > 0 else { return 0 }
        return CGFloat((time - windowStart) / windowDuration) * width
    }

    private func timeForX(_ x: CGFloat, in width: CGFloat) -> Double {
        guard width > 0 else { return windowStart }
        return windowStart + Double(x / width) * windowDuration
    }

    // MARK: - Thumbnails

    private func generateThumbnails() async {
        let url = videoURL
        let start = windowStart
        let duration = windowDuration
        let count = 12

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)

        let times: [CMTime] = (0..<count).map { i in
            let t = start + (duration * Double(i) / Double(count - 1))
            return CMTimeMakeWithSeconds(t, preferredTimescale: 600)
        }

        var result: [UIImage] = []
        for await imageResult in generator.images(for: times) {
            if let cgImage = try? imageResult.image {
                result.append(UIImage(cgImage: cgImage))
            }
        }

        thumbnails = result
    }

    // MARK: - Formatting

    private func formatDuration(_ seconds: Double) -> String {
        String(format: "%.1fs", max(0, seconds))
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black
        RallyTrimOverlay(
            trimBefore: .constant(0.0),
            trimAfter: .constant(0.0),
            rallyStartTime: 10.0,
            rallyEndTime: 14.2,
            videoURL: URL(fileURLWithPath: "/dev/null"),
            videoDuration: 60.0,
            onScrub: { _ in },
            onConfirm: {},
            onCancel: {}
        )
    }
}
