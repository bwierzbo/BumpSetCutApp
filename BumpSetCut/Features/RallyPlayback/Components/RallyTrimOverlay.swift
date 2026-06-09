import SwiftUI
import AVFoundation

// MARK: - Rally Trim Overlay (Apple Photos-style filmstrip)

struct RallyTrimOverlay: View {
    @Binding var trimBefore: Double
    @Binding var trimAfter: Double
    @Binding var trimRotation: Double
    @Binding var trimZoom: Double
    let rallyStartTime: Double
    let rallyEndTime: Double
    let videoURL: URL
    let videoDuration: Double
    let onScrub: (Double) -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void
    var onResetZoom: () -> Void = {}
    var showsAngleControl: Bool = true
    var showsZoomControl: Bool = false

    private let maxBuffer: Double = 3.0
    private let handleWidth: CGFloat = 14
    private let barHeight: CGFloat = 56
    private let borderThickness: CGFloat = 3
    private let minSelectionDuration: Double = 1.0
    private let maxRotationDegrees: Double = 10.0
    private let rotationStepDegrees: Double = 0.5

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
            // Dim backdrop — non-interactive so pinch/twist/drag reach the video
            // behind the overlay. Controls below stay interactive.
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer()

                // Gesture hint + zoom readout
                if showsZoomControl {
                    zoomHintRow
                        .padding(.horizontal, BSCSpacing.lg)
                        .padding(.bottom, BSCSpacing.md)
                }

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

                // Angle adjustment row
                if showsAngleControl {
                    angleControl
                        .padding(.horizontal, BSCSpacing.lg)
                        .padding(.bottom, BSCSpacing.md)
                }

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

    // MARK: - Zoom Hint / Readout

    @ViewBuilder
    private var zoomHintRow: some View {
        HStack(spacing: BSCSpacing.sm) {
            Image(systemName: "hand.draw")
                .font(.system(size: 12, weight: .semibold))
            Text("Pinch zoom · Twist angle · Drag to pan")
                .font(.system(size: 12, weight: .medium))

            Spacer()

            Text(String(format: "%.1f×", trimZoom))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.bscPrimary)

            if trimZoom > 1.01 {
                Button { onResetZoom() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
        }
        .foregroundColor(.white.opacity(0.85))
    }

    // MARK: - Angle Control

    @ViewBuilder
    private var angleControl: some View {
        let max = maxRotationDegrees
        let step = rotationStepDegrees
        let binding = Binding(
            get: { trimRotation },
            set: { trimRotation = snap(clampDeg($0, max: max), step: step) }
        )

        HStack(spacing: BSCSpacing.md) {
            Button {
                trimRotation = snap(clampDeg(trimRotation - step, max: max), step: step)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
            }

            Slider(value: binding, in: -max...max, step: step)
                .tint(.bscPrimary)

            Button {
                trimRotation = snap(clampDeg(trimRotation + step, max: max), step: step)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
            }

            Text(formatDegrees(trimRotation))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.bscPrimary)
                .frame(width: 56, alignment: .trailing)

            Button {
                trimRotation = 0
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(abs(trimRotation) < 0.01 ? 0.3 : 0.9))
                    .frame(width: 28, height: 28)
            }
            .disabled(abs(trimRotation) < 0.01)
        }
    }

    private func snap(_ value: Double, step: Double) -> Double {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }

    private func clampDeg(_ value: Double, max: Double) -> Double {
        min(max, Swift.max(-max, value))
    }

    private func formatDegrees(_ value: Double) -> String {
        String(format: "%+.1f°", value)
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
            trimRotation: .constant(0.0),
            trimZoom: .constant(1.4),
            rallyStartTime: 10.0,
            rallyEndTime: 14.2,
            videoURL: URL(fileURLWithPath: "/dev/null"),
            videoDuration: 60.0,
            onScrub: { _ in },
            onConfirm: {},
            onCancel: {},
            showsZoomControl: true
        )
    }
}
