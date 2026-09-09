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

    private let initialBuffer: Double = 3.0
    private let handleWidth: CGFloat = 14
    private let barHeight: CGFloat = 56
    private let borderThickness: CGFloat = 3
    private let minSelectionDuration: Double = 1.0
    private let maxRotationDegrees: Double = 10.0
    private let rotationStepDegrees: Double = 0.5
    private let edgeZoneWidth: CGFloat = 20
    private let autoExtendRate: Double = 1.0   // video-seconds per second held at the edge
    private let autoExtendTickSeconds: Double = 0.1

    private enum ExtendDirection { case left, right }

    @State private var thumbnails: [UIImage] = []
    @State private var leftGrabOffset: CGFloat?
    @State private var rightGrabOffset: CGFloat?
    @State private var leftAtClamp = false
    @State private var rightAtClamp = false
    @State private var selectionHaptic = UISelectionFeedbackGenerator()
    @State private var autoExtendTask: Task<Void, Never>? = nil
    @State private var autoExtendDirection: ExtendDirection? = nil
    @State private var thumbnailTask: Task<Void, Never>? = nil
    @State private var lastThumbnailWindow: (start: Double, end: Double) = (0, 0)

    // Time window visible in the filmstrip. Starts at ±initialBuffer around the
    // rally (expanded to include any saved trim beyond that) and grows while a
    // handle is held at a strip edge.
    @State private var windowStart: Double = 0
    @State private var windowEnd: Double = 0
    @State private var windowInitialized = false
    private var windowDuration: Double { windowEnd - windowStart }

    // Current effective trim boundaries
    private var effectiveStart: Double { rallyStartTime - trimBefore }
    private var effectiveEnd: Double { rallyEndTime + trimAfter }
    private var selectionDuration: Double { effectiveEnd - effectiveStart }

    var body: some View {
        ZStack {
            // Dim backdrop — non-interactive so pinch/twist/drag reach the video
            // behind the overlay. Controls below stay interactive.
            Color.bscMediaScrim
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
                    Button(action: onCancel) {
                        Text("Cancel")
                            .bscFont(size: 16)
                            .foregroundColor(.bscOnMedia)
                            .frame(minHeight: BSCTouchTarget.standard)
                            .contentShape(Rectangle())
                    }
                    Spacer()
                    Text(formatDuration(selectionDuration))
                        .bscFont(size: 15, weight: .medium, design: .monospaced)
                        .foregroundColor(.bscOnMedia)
                    Spacer()
                    Button(action: onConfirm) {
                        Text("Done")
                            .bscFont(size: 16, weight: .semibold)
                            .foregroundColor(.bscPrimary)
                            .frame(minHeight: BSCTouchTarget.standard)
                            .contentShape(Rectangle())
                    }
                }
                .padding(.horizontal, BSCSpacing.lg)
                .background(Capsule().fill(Color.bscMediaScrim))
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
        .onAppear {
            initializeWindowIfNeeded()
            selectionHaptic.prepare()
        }
        .task {
            initializeWindowIfNeeded()
            maybeRefreshThumbnails(force: true)
        }
        .onDisappear {
            autoExtendTask?.cancel()
            autoExtendTask = nil
            autoExtendDirection = nil
            thumbnailTask?.cancel()
        }
    }

    private func initializeWindowIfNeeded() {
        guard !windowInitialized else { return }
        windowInitialized = true
        windowStart = max(0, min(rallyStartTime - initialBuffer, effectiveStart))
        windowEnd = min(videoDuration, max(rallyEndTime + initialBuffer, effectiveEnd))
    }

    // MARK: - Zoom Hint / Readout

    @ViewBuilder
    private var zoomHintRow: some View {
        HStack(spacing: BSCSpacing.sm) {
            Image(systemName: "hand.draw")
                .bscFont(size: 12, weight: .semibold)
            Text("Pinch zoom · Twist angle · Drag to pan")
                .bscFont(size: 12, weight: .medium)

            Spacer()

            Text(String(format: "%.1f×", trimZoom))
                .bscFont(size: 12, weight: .semibold, design: .monospaced)
                .foregroundColor(.bscPrimary)

            if trimZoom > 1.01 {
                Button { onResetZoom() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .bscFont(size: 12, weight: .semibold)
                        .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                        .contentShape(Rectangle())
                }
            }
        }
        .foregroundColor(.bscOnMedia)
    }

    // MARK: - Angle Control

    @ViewBuilder
    private var angleControl: some View {
        let max = maxRotationDegrees
        let step = rotationStepDegrees
        let binding = Binding(
            get: { trimRotation },
            set: { setRotation(snap(clampDeg($0, max: max), step: step)) }
        )

        HStack(spacing: BSCSpacing.md) {
            Button {
                setRotation(snap(clampDeg(trimRotation - step, max: max), step: step))
            } label: {
                Image(systemName: "minus")
                    .bscFont(size: 13, weight: .bold)
                    .foregroundColor(.bscOnMedia)
                    .frame(width: 28, height: 28)
                    .background(Color.bscOnMedia.opacity(0.15))
                    .clipShape(Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }

            Slider(value: binding, in: -max...max, step: step)
                .tint(.bscPrimary)

            Button {
                setRotation(snap(clampDeg(trimRotation + step, max: max), step: step))
            } label: {
                Image(systemName: "plus")
                    .bscFont(size: 13, weight: .bold)
                    .foregroundColor(.bscOnMedia)
                    .frame(width: 28, height: 28)
                    .background(Color.bscOnMedia.opacity(0.15))
                    .clipShape(Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }

            Text(formatDegrees(trimRotation))
                .bscFont(size: 13, weight: .medium, design: .monospaced)
                .foregroundColor(.bscPrimary)
                .frame(width: 56, alignment: .trailing)

            Button {
                setRotation(0)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .bscFont(size: 12, weight: .semibold)
                    .foregroundColor(Color.bscOnMedia.opacity(abs(trimRotation) < 0.01 ? 0.3 : 0.9))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(abs(trimRotation) < 0.01)
        }
    }

    /// Apply a snapped rotation value, ticking when it lands on a new 0.5° step.
    private func setRotation(_ value: Double) {
        guard value != trimRotation else { return }
        selectionHaptic.selectionChanged()
        selectionHaptic.prepare()
        trimRotation = value
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
                .fill(Color.bscMediaScrim)
                .frame(width: max(0, leftX), height: barHeight)
                .allowsHitTesting(false)

            // 3. Dim overlay right of selection
            Rectangle()
                .fill(Color.bscMediaScrim)
                .frame(width: max(0, totalWidth - rightX), height: barHeight)
                .offset(x: rightX)
                .allowsHitTesting(false)

            // 4. Yellow top/bottom borders between handles
            let innerWidth = max(0, rightX - leftX - 2 * handleWidth)
            VStack(spacing: 0) {
                Rectangle().fill(Color.bscPrimaryBright).frame(height: borderThickness)
                Spacer()
                Rectangle().fill(Color.bscPrimaryBright).frame(height: borderThickness)
            }
            .frame(width: innerWidth, height: barHeight)
            .offset(x: leftX + handleWidth)
            .allowsHitTesting(false)

            // 5. Left handle (offset accounts for hit padding)
            trimHandle(isLeft: true)
                .offset(x: leftX - handleHitPadding)
                .gesture(leftHandleDrag(totalWidth: totalWidth))
                .accessibilityElement()
                .accessibilityLabel("Trim start")
                .accessibilityValue(String(format: "%.1f seconds", effectiveStart))
                .accessibilityAdjustableAction { direction in
                    let delta = direction == .increment ? 0.5 : -0.5
                    let newTime = Swift.max(0, Swift.min(effectiveStart + delta, effectiveEnd - minSelectionDuration))
                    if newTime < windowStart {
                        windowStart = newTime
                        maybeRefreshThumbnails(force: true)
                    }
                    trimBefore = rallyStartTime - newTime
                    onScrub(newTime)
                }

            // 6. Right handle (offset accounts for hit padding)
            trimHandle(isLeft: false)
                .offset(x: rightX - handleWidth - handleHitPadding)
                .gesture(rightHandleDrag(totalWidth: totalWidth))
                .accessibilityElement()
                .accessibilityLabel("Trim end")
                .accessibilityValue(String(format: "%.1f seconds", effectiveEnd))
                .accessibilityAdjustableAction { direction in
                    let delta = direction == .increment ? 0.5 : -0.5
                    let newTime = Swift.min(videoDuration, Swift.max(effectiveEnd + delta, effectiveStart + minSelectionDuration))
                    if newTime > windowEnd {
                        windowEnd = newTime
                        maybeRefreshThumbnails(force: true)
                    }
                    trimAfter = newTime - rallyEndTime
                    onScrub(newTime)
                }
        }
        .coordinateSpace(name: "trimBar")
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm))
    }

    // MARK: - Filmstrip

    @ViewBuilder
    private func filmstrip(width: CGFloat) -> some View {
        if thumbnails.isEmpty {
            Rectangle()
                .fill(Color.bscOnMedia.opacity(0.1))
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
                    .bscFont(size: 15, weight: .heavy)
                    .foregroundColor(.bscOnMedia)
            )
            .allowsHitTesting(false)
        }
    }

    // MARK: - Gestures

    private func leftHandleDrag(totalWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("trimBar"))
            .onChanged { value in
                if leftGrabOffset == nil {
                    leftGrabOffset = value.startLocation.x - xForTime(effectiveStart, in: totalWidth)
                }
                let desiredX = value.location.x - (leftGrabOffset ?? 0)

                // Holding at the strip's left edge auto-extends the window
                // (while the loop runs, ticks own trimBefore — not the finger).
                if desiredX <= edgeZoneWidth && windowStart > 0 {
                    if autoExtendTask == nil {
                        selectionHaptic.selectionChanged()
                        selectionHaptic.prepare()
                        startAutoExtend(.left)
                    }
                    return
                }
                stopAutoExtend()

                let newTime = timeForX(desiredX, in: totalWidth)
                let clamped = max(windowStart, min(newTime, effectiveEnd - minSelectionDuration))
                tickAtClamp(isClamped: clamped != newTime, wasClamped: &leftAtClamp)
                trimBefore = rallyStartTime - clamped
                onScrub(clamped)
            }
            .onEnded { _ in
                stopAutoExtend()
                leftGrabOffset = nil
                leftAtClamp = false
            }
    }

    private func rightHandleDrag(totalWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("trimBar"))
            .onChanged { value in
                if rightGrabOffset == nil {
                    rightGrabOffset = value.startLocation.x - xForTime(effectiveEnd, in: totalWidth)
                }
                let desiredX = value.location.x - (rightGrabOffset ?? 0)

                if desiredX >= totalWidth - edgeZoneWidth && windowEnd < videoDuration {
                    if autoExtendTask == nil {
                        selectionHaptic.selectionChanged()
                        selectionHaptic.prepare()
                        startAutoExtend(.right)
                    }
                    return
                }
                stopAutoExtend()

                let newTime = timeForX(desiredX, in: totalWidth)
                let clamped = min(windowEnd, max(newTime, effectiveStart + minSelectionDuration))
                tickAtClamp(isClamped: clamped != newTime, wasClamped: &rightAtClamp)
                trimAfter = clamped - rallyEndTime
                onScrub(clamped)
            }
            .onEnded { _ in
                stopAutoExtend()
                rightGrabOffset = nil
                rightAtClamp = false
            }
    }

    // MARK: - Edge-Hold Auto-Extension

    private func startAutoExtend(_ direction: ExtendDirection) {
        autoExtendDirection = direction
        autoExtendTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(autoExtendTickSeconds * 1_000_000_000))
                guard !Task.isCancelled else { break }
                performExtendTick(direction)
            }
        }
    }

    /// Stop the extension loop (finger left the edge zone, drag ended, or a
    /// video bound was hit) and settle the filmstrip on the final window.
    private func stopAutoExtend() {
        guard autoExtendTask != nil else { return }
        autoExtendTask?.cancel()
        autoExtendTask = nil
        autoExtendDirection = nil
        maybeRefreshThumbnails(force: true)
    }

    private func performExtendTick(_ direction: ExtendDirection) {
        let tickStep = autoExtendRate * autoExtendTickSeconds
        switch direction {
        case .left:
            let step = min(tickStep, windowStart)
            guard step > 0 else {
                tickAtClamp(isClamped: true, wasClamped: &leftAtClamp)
                stopAutoExtend()
                return
            }
            windowStart -= step
            // Pin the handle at the strip edge while the window grows under it.
            trimBefore = rallyStartTime - windowStart
            onScrub(windowStart)
        case .right:
            let step = min(tickStep, videoDuration - windowEnd)
            guard step > 0 else {
                tickAtClamp(isClamped: true, wasClamped: &rightAtClamp)
                stopAutoExtend()
                return
            }
            windowEnd += step
            trimAfter = windowEnd - rallyEndTime
            onScrub(windowEnd)
        }
        maybeRefreshThumbnails()
    }

    /// Tick once when a handle drag first hits its clamp (min duration or window edge).
    private func tickAtClamp(isClamped: Bool, wasClamped: inout Bool) {
        if isClamped && !wasClamped {
            selectionHaptic.selectionChanged()
            selectionHaptic.prepare()
        }
        wasClamped = isClamped
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

    /// Regenerate the filmstrip for the current window — at most once per
    /// ≥1s of window growth during auto-extension unless forced.
    private func maybeRefreshThumbnails(force: Bool = false) {
        let grown = (lastThumbnailWindow.start - windowStart) + (windowEnd - lastThumbnailWindow.end)
        guard force || grown >= 1.0 else { return }
        thumbnailTask?.cancel()
        thumbnailTask = Task { await generateThumbnails() }
    }

    private func generateThumbnails() async {
        let url = videoURL
        let start = windowStart
        let duration = windowDuration
        let count = 12
        lastThumbnailWindow = (windowStart, windowEnd)

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
            guard !Task.isCancelled else { return }
            if let cgImage = try? imageResult.image {
                result.append(UIImage(cgImage: cgImage))
            }
        }

        guard !Task.isCancelled else { return }
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
        Color.bscMediaBackground
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
