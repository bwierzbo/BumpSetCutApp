//
//  MetadataOverlayView.swift
//  BumpSetCut
//
//  Created for Metadata Video Processing - Task 006
//

import SwiftUI
import AVFoundation
import CoreGraphics

/// SwiftUI Canvas-based overlay component that renders ball trajectories, rally boundaries,
/// and confidence indicators in real-time during video playback
struct MetadataOverlayView: View {
    // MARK: - Properties

    /// Processing metadata containing trajectory and rally data
    let processingMetadata: ProcessingMetadata

    /// Current video playback time for synchronization
    let currentTime: Double

    /// Video size for coordinate system mapping
    let videoSize: CGSize

    /// Toggle visibility for overlay elements
    var showTrajectories: Bool = true
    var showRallyBoundaries: Bool = true
    var showConfidenceIndicators: Bool = true

    /// Performance tracking
    @State private var lastRenderTime = Date()
    @State private var renderFPS: Double = 60.0

    /// Configuration
    private let trajectoryHistoryDuration: Double = 2.0 // Show 2 seconds of trajectory history
    private let maxTrajectoryPoints = 60 // Limit points for performance (2 seconds at 30fps)

    var body: some View {
        Canvas { context, size in
            // Track rendering performance
            trackRenderingPerformance()

            // Transform coordinate system for video overlay
            let transform = createCoordinateTransform(canvasSize: size, videoSize: videoSize)

            // Draw rally boundaries (background layer)
            if showRallyBoundaries {
                drawRallyBoundaries(in: context, canvasSize: size, transform: transform)
            }

            // Draw ball trajectories (foreground layer)
            if showTrajectories {
                drawTrajectories(in: context, canvasSize: size, transform: transform)
            }

            // Draw confidence indicators (overlay layer)
            if showConfidenceIndicators {
                drawConfidenceIndicators(in: context, canvasSize: size, transform: transform)
            }

            // Draw time cursor for current playback position
            drawTimeCursor(in: context, canvasSize: size)

            // Draw performance HUD in debug builds
            #if DEBUG
            drawPerformanceHUD(in: context, canvasSize: size)
            #endif
        }
        .background(Color.clear)
        .allowsHitTesting(false) // Overlay should not intercept touch events
    }
}

// MARK: - Coordinate System Transformation

private extension MetadataOverlayView {
    /// Creates coordinate transformation from normalized video coordinates to canvas coordinates
    func createCoordinateTransform(canvasSize: CGSize, videoSize: CGSize) -> CGAffineTransform {
        // Scale from normalized coordinates (0-1) to canvas size
        let scaleX = canvasSize.width
        let scaleY = canvasSize.height

        return CGAffineTransform(scaleX: scaleX, y: scaleY)
    }

    /// Transforms a normalized point to canvas coordinates
    func transformPoint(_ point: CGPoint, with transform: CGAffineTransform) -> CGPoint {
        return point.applying(transform)
    }
}

// MARK: - Rally Boundary Rendering

private extension MetadataOverlayView {
    func drawRallyBoundaries(in context: GraphicsContext, canvasSize: CGSize, transform: CGAffineTransform) {
        // Find current rally for highlighting
        let currentRally = getCurrentRally()

        for (index, rally) in processingMetadata.rallySegments.enumerated() {
            let isCurrentRally = (currentRally?.id == rally.id)
            let isActive = currentTime >= rally.startTime && currentTime <= rally.endTime

            // Draw rally boundary indicators
            drawRallyBoundary(
                rally: rally,
                index: index,
                isActive: isActive,
                isCurrent: isCurrentRally,
                in: context,
                canvasSize: canvasSize
            )
        }
    }

    func drawRallyBoundary(
        rally: RallySegment,
        index: Int,
        isActive: Bool,
        isCurrent: Bool,
        in context: GraphicsContext,
        canvasSize: CGSize
    ) {
        let colors = getRallyColors(isActive: isActive, isCurrent: isCurrent, quality: rally.quality)

        // Draw top boundary bar
        let barHeight: CGFloat = isActive ? 8 : 4
        let topBar = CGRect(x: 0, y: 0, width: canvasSize.width, height: barHeight)

        context.fill(
            Path(topBar),
            with: .color(colors.boundary)
        )

        // Draw rally start/end markers
        if isCurrent {
            drawRallyMarkers(rally: rally, in: context, canvasSize: canvasSize, colors: colors)
        }

        // Draw rally quality indicator
        if isCurrent {
            drawQualityIndicator(rally: rally, in: context, canvasSize: canvasSize, colors: colors)
        }
    }

    func drawRallyMarkers(
        rally: RallySegment,
        in context: GraphicsContext,
        canvasSize: CGSize,
        colors: RallyColors
    ) {
        let markerWidth: CGFloat = 3
        let markerHeight: CGFloat = canvasSize.height * 0.8

        // Start marker (left side)
        let startMarker = CGRect(x: 0, y: canvasSize.height * 0.1, width: markerWidth, height: markerHeight)
        context.fill(Path(startMarker), with: .color(colors.startMarker))

        // End marker (right side)
        let endMarker = CGRect(x: canvasSize.width - markerWidth, y: canvasSize.height * 0.1, width: markerWidth, height: markerHeight)
        context.fill(Path(endMarker), with: .color(colors.endMarker))
    }

    func drawQualityIndicator(
        rally: RallySegment,
        in context: GraphicsContext,
        canvasSize: CGSize,
        colors: RallyColors
    ) {
        let indicatorSize: CGFloat = 12
        let position = CGPoint(x: canvasSize.width - indicatorSize - 8, y: indicatorSize + 8)

        let indicator = CGRect(
            x: position.x - indicatorSize/2,
            y: position.y - indicatorSize/2,
            width: indicatorSize,
            height: indicatorSize
        )

        context.fill(
            Path(ellipseIn: indicator),
            with: .color(colors.quality)
        )
    }

    func getRallyColors(isActive: Bool, isCurrent: Bool, quality: Double) -> RallyColors {
        let qualityColor: Color = {
            switch quality {
            case 0.8...1.0: return .green
            case 0.6..<0.8: return .yellow
            case 0.4..<0.6: return .orange
            default: return .red
            }
        }()

        return RallyColors(
            boundary: isActive ? .green.opacity(0.8) : .gray.opacity(0.4),
            startMarker: isCurrent ? .blue : .gray,
            endMarker: isCurrent ? .purple : .gray,
            quality: qualityColor
        )
    }

    struct RallyColors {
        let boundary: Color
        let startMarker: Color
        let endMarker: Color
        let quality: Color
    }
}

// MARK: - Trajectory Rendering

private extension MetadataOverlayView {
    func drawTrajectories(in context: GraphicsContext, canvasSize: CGSize, transform: CGAffineTransform) {
        guard let trajectoryData = processingMetadata.trajectoryData else { return }

        // Get trajectories within time window
        let relevantTrajectories = getRelevantTrajectories(trajectoryData)

        for trajectory in relevantTrajectories {
            drawTrajectory(
                trajectory: trajectory,
                in: context,
                canvasSize: canvasSize,
                transform: transform
            )
        }
    }

    func drawTrajectory(
        trajectory: ProcessingTrajectoryData,
        in context: GraphicsContext,
        canvasSize: CGSize,
        transform: CGAffineTransform
    ) {
        let points = getTrajectoryPointsForCurrentTime(trajectory)
        guard points.count >= 2 else { return }

        // Create trajectory path
        var path = Path()
        let firstPoint = transformPoint(points[0].position, with: transform)
        path.move(to: firstPoint)

        for point in points.dropFirst() {
            let canvasPoint = transformPoint(point.position, with: transform)
            path.addLine(to: canvasPoint)
        }

        // Get trajectory colors based on confidence and movement type
        let colors = getTrajectoryColors(trajectory)

        // Draw trajectory path with confidence-based styling
        let pathStyle = StrokeStyle(
            lineWidth: getTrajectoryLineWidth(trajectory),
            lineCap: .round,
            lineJoin: .round,
            dash: trajectory.movementType?.isValidProjectile == true ? [] : [8, 4]
        )

        context.stroke(path, with: .color(colors.trajectory), style: pathStyle)

        // Draw trajectory points for detailed visualization
        if showConfidenceIndicators {
            drawTrajectoryPoints(
                points: points,
                colors: colors,
                in: context,
                canvasSize: canvasSize,
                transform: transform
            )
        }
    }

    func drawTrajectoryPoints(
        points: [ProcessingTrajectoryPoint],
        colors: TrajectoryColors,
        in context: GraphicsContext,
        canvasSize: CGSize,
        transform: CGAffineTransform
    ) {
        for point in points {
            let canvasPoint = transformPoint(point.position, with: transform)
            let pointSize = getPointSize(for: point.confidence)

            let pointRect = CGRect(
                x: canvasPoint.x - pointSize/2,
                y: canvasPoint.y - pointSize/2,
                width: pointSize,
                height: pointSize
            )

            context.fill(
                Path(ellipseIn: pointRect),
                with: .color(colors.point.opacity(point.confidence))
            )
        }
    }

    func getRelevantTrajectories(_ trajectoryData: [ProcessingTrajectoryData]) -> [ProcessingTrajectoryData] {
        // Filter trajectories that are active within the current time window
        let timeWindow = currentTime - trajectoryHistoryDuration...currentTime + 0.5

        return trajectoryData.filter { trajectory in
            // Check if trajectory overlaps with current time window
            let trajectoryRange = trajectory.startTime...trajectory.endTime
            return trajectoryRange.overlaps(timeWindow)
        }
    }

    func getTrajectoryPointsForCurrentTime(_ trajectory: ProcessingTrajectoryData) -> [ProcessingTrajectoryPoint] {
        // Get points within the current time window for smooth animation
        let windowStart = max(currentTime - trajectoryHistoryDuration, trajectory.startTime)
        let windowEnd = min(currentTime + 0.1, trajectory.endTime) // Small look-ahead

        return trajectory.points.filter { point in
            point.timestamp >= windowStart && point.timestamp <= windowEnd
        }.suffix(maxTrajectoryPoints).map { $0 }
    }

    func getTrajectoryColors(_ trajectory: ProcessingTrajectoryData) -> TrajectoryColors {
        let baseColor: Color = {
            if let movementType = trajectory.movementType {
                switch movementType {
                case .airborne: return .blue
                case .carried: return .orange
                case .rolling: return .brown
                case .unknown: return .gray
                }
            } else {
                return .white
            }
        }()

        let confidenceAlpha = min(1.0, max(0.3, trajectory.confidence))

        return TrajectoryColors(
            trajectory: baseColor.opacity(confidenceAlpha),
            point: baseColor,
            confidence: getConfidenceColor(trajectory.confidence)
        )
    }

    func getTrajectoryLineWidth(_ trajectory: ProcessingTrajectoryData) -> CGFloat {
        // Line width based on trajectory confidence and quality
        let baseWidth: CGFloat = 2.0
        let confidenceMultiplier = 0.5 + (trajectory.confidence * 1.5)
        let qualityMultiplier = 0.8 + (trajectory.quality * 0.4)

        return baseWidth * confidenceMultiplier * qualityMultiplier
    }

    func getPointSize(for confidence: Double) -> CGFloat {
        return 3.0 + (confidence * 4.0) // 3-7 pixels based on confidence
    }

    struct TrajectoryColors {
        let trajectory: Color
        let point: Color
        let confidence: Color
    }
}

// MARK: - Confidence Indicators

private extension MetadataOverlayView {
    func drawConfidenceIndicators(in context: GraphicsContext, canvasSize: CGSize, transform: CGAffineTransform) {
        // Draw overall confidence meter
        drawOverallConfidenceMeter(in: context, canvasSize: canvasSize)

        // Draw trajectory-specific confidence indicators
        drawTrajectoryConfidenceIndicators(in: context, canvasSize: canvasSize, transform: transform)
    }

    func drawOverallConfidenceMeter(in context: GraphicsContext, canvasSize: CGSize) {
        let currentRally = getCurrentRally()
        let confidence = currentRally?.confidence ?? 0.0

        let meterWidth: CGFloat = 100
        let meterHeight: CGFloat = 8
        let meterPosition = CGPoint(x: canvasSize.width - meterWidth - 16, y: 20)

        // Background
        let backgroundRect = CGRect(
            x: meterPosition.x,
            y: meterPosition.y,
            width: meterWidth,
            height: meterHeight
        )
        context.fill(Path(backgroundRect), with: .color(.gray.opacity(0.3)))

        // Confidence fill
        let fillWidth = meterWidth * confidence
        let fillRect = CGRect(
            x: meterPosition.x,
            y: meterPosition.y,
            width: fillWidth,
            height: meterHeight
        )

        let confidenceColor = getConfidenceColor(confidence)
        context.fill(Path(fillRect), with: .color(confidenceColor))

        // Text label
        let confidenceText = String(format: "%.0f%%", confidence * 100)
        context.draw(
            Text(confidenceText)
                .font(.caption2.monospacedDigit())
                .foregroundColor(.white),
            at: CGPoint(x: meterPosition.x + meterWidth/2, y: meterPosition.y + meterHeight + 12),
            anchor: .center
        )
    }

    func drawTrajectoryConfidenceIndicators(in context: GraphicsContext, canvasSize: CGSize, transform: CGAffineTransform) {
        guard let trajectoryData = processingMetadata.trajectoryData else { return }

        let relevantTrajectories = getRelevantTrajectories(trajectoryData)

        for trajectory in relevantTrajectories {
            drawTrajectoryConfidenceBadge(
                trajectory: trajectory,
                in: context,
                canvasSize: canvasSize,
                transform: transform
            )
        }
    }

    func drawTrajectoryConfidenceBadge(
        trajectory: ProcessingTrajectoryData,
        in context: GraphicsContext,
        canvasSize: CGSize,
        transform: CGAffineTransform
    ) {
        // Get the latest point for badge position
        guard let latestPoint = trajectory.points.last else { return }

        let badgePosition = transformPoint(latestPoint.position, with: transform)
        let badgeSize: CGFloat = 20
        let confidence = trajectory.confidence

        // Badge background
        let badgeRect = CGRect(
            x: badgePosition.x - badgeSize/2,
            y: badgePosition.y - badgeSize - 10,
            width: badgeSize,
            height: badgeSize
        )

        let confidenceColor = getConfidenceColor(confidence)
        context.fill(
            Path(ellipseIn: badgeRect),
            with: .color(confidenceColor.opacity(0.8))
        )

        // Confidence percentage text
        let confidenceText = String(format: "%.0f", confidence * 100)
        context.draw(
            Text(confidenceText)
                .font(.caption2.bold().monospacedDigit())
                .foregroundColor(.white),
            at: CGPoint(x: badgePosition.x, y: badgePosition.y - badgeSize/2 - 10),
            anchor: .center
        )
    }

    func getConfidenceColor(_ confidence: Double) -> Color {
        switch confidence {
        case 0.8...1.0: return .green
        case 0.6..<0.8: return .yellow
        case 0.4..<0.6: return .orange
        default: return .red
        }
    }
}

// MARK: - Time Cursor

private extension MetadataOverlayView {
    func drawTimeCursor(in context: GraphicsContext, canvasSize: CGSize) {
        // Draw a subtle time indicator line
        let cursorWidth: CGFloat = 2
        let cursorHeight = canvasSize.height * 0.1

        let cursorRect = CGRect(
            x: canvasSize.width/2 - cursorWidth/2,
            y: 0,
            width: cursorWidth,
            height: cursorHeight
        )

        context.fill(
            Path(cursorRect),
            with: .color(.white.opacity(0.6))
        )
    }
}

// MARK: - Performance Tracking

private extension MetadataOverlayView {
    func trackRenderingPerformance() {
        let now = Date()
        let deltaTime = now.timeIntervalSince(lastRenderTime)

        if deltaTime > 0 {
            let instantFPS = 1.0 / deltaTime
            // Smooth FPS using exponential moving average
            renderFPS = (renderFPS * 0.9) + (instantFPS * 0.1)
        }

        lastRenderTime = now
    }

    #if DEBUG
    func drawPerformanceHUD(in context: GraphicsContext, canvasSize: CGSize) {
        let fpsText = String(format: "FPS: %.1f", renderFPS)
        let fpsColor: Color = renderFPS >= 55 ? .green : renderFPS >= 30 ? .yellow : .red

        context.draw(
            Text(fpsText)
                .font(.caption.monospacedDigit())
                .foregroundColor(fpsColor),
            at: CGPoint(x: 16, y: canvasSize.height - 20),
            anchor: .bottomLeading
        )

        // Trajectory count
        let trajectoryCount = processingMetadata.trajectoryData?.count ?? 0
        let countText = "Trajectories: \(trajectoryCount)"

        context.draw(
            Text(countText)
                .font(.caption2.monospacedDigit())
                .foregroundColor(.gray),
            at: CGPoint(x: 16, y: canvasSize.height - 40),
            anchor: .bottomLeading
        )
    }
    #endif
}

// MARK: - Helper Methods

private extension MetadataOverlayView {
    func getCurrentRally() -> RallySegment? {
        return processingMetadata.rallySegments.first { rally in
            currentTime >= rally.startTime && currentTime <= rally.endTime
        }
    }
}

// MARK: - Overlay Controls

extension MetadataOverlayView {
    /// Creates a control panel for toggling overlay visibility
    static func createOverlayControls(
        showTrajectories: Binding<Bool>,
        showRallyBoundaries: Binding<Bool>,
        showConfidenceIndicators: Binding<Bool>
    ) -> some View {
        HStack(spacing: 16) {
            Toggle("Trajectories", isOn: showTrajectories)
                .toggleStyle(.button)
                .font(.caption)

            Toggle("Rally Bounds", isOn: showRallyBoundaries)
                .toggleStyle(.button)
                .font(.caption)

            Toggle("Confidence", isOn: showConfidenceIndicators)
                .toggleStyle(.button)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - Preview

#if DEBUG
struct MetadataOverlayView_Previews: PreviewProvider {
    static var previews: some View {
        // Create sample data for preview
        let sampleMetadata = createSampleMetadata()

        ZStack {
            Rectangle()
                .fill(.black)
                .frame(width: 400, height: 300)

            MetadataOverlayView(
                processingMetadata: sampleMetadata,
                currentTime: 5.0,
                videoSize: CGSize(width: 400, height: 300)
            )
        }
        .preferredColorScheme(.dark)
    }

    static func createSampleMetadata() -> ProcessingMetadata {
        // Create sample rally segments
        let rallySegments = [
            RallySegment(
                startTime: CMTime(seconds: 2.0, preferredTimescale: 600),
                endTime: CMTime(seconds: 8.0, preferredTimescale: 600),
                confidence: 0.85,
                quality: 0.92,
                detectionCount: 45,
                averageTrajectoryLength: 2.3
            )
        ]

        // Create sample trajectory data
        let trajectoryPoints = [
            ProcessingTrajectoryPoint(
                timestamp: CMTime(seconds: 4.0, preferredTimescale: 600),
                position: CGPoint(x: 0.3, y: 0.4),
                velocity: 15.0,
                acceleration: -9.8,
                confidence: 0.9
            ),
            ProcessingTrajectoryPoint(
                timestamp: CMTime(seconds: 5.0, preferredTimescale: 600),
                position: CGPoint(x: 0.5, y: 0.6),
                velocity: 12.0,
                acceleration: -9.8,
                confidence: 0.85
            )
        ]

        let trajectoryData = [
            ProcessingTrajectoryData(
                id: UUID(),
                startTime: 4.0,
                endTime: 6.0,
                points: trajectoryPoints,
                rSquared: 0.92,
                movementType: .airborne,
                confidence: 0.88,
                quality: 0.85
            )
        ]

        let processingStats = ProcessingStats(
            totalFrames: 300,
            processedFrames: 300,
            detectionFrames: 180,
            trackingFrames: 120,
            rallyFrames: 90,
            physicsValidFrames: 75,
            totalDetections: 450,
            validTrajectories: 12,
            averageDetectionsPerFrame: 1.5,
            averageConfidence: 0.82,
            processingDuration: 15.0,
            framesPerSecond: 20.0
        )

        let qualityMetrics = QualityMetrics(
            overallQuality: 0.85,
            averageRSquared: 0.88,
            trajectoryConsistency: 0.82,
            physicsValidationRate: 0.85,
            movementClassificationAccuracy: 0.90,
            confidenceDistribution: ConfidenceDistribution(high: 200, medium: 150, low: 100),
            qualityBreakdown: QualityBreakdown(
                velocityConsistency: 0.88,
                accelerationPattern: 0.85,
                smoothnessScore: 0.82,
                verticalMotionScore: 0.90,
                overallCoherence: 0.85
            )
        )

        let performanceMetrics = PerformanceData(
            processingStartTime: Date().addingTimeInterval(-20),
            processingEndTime: Date().addingTimeInterval(-5),
            averageFPS: 25.0,
            peakMemoryUsageMB: 85.0,
            averageMemoryUsageMB: 65.0,
            cpuUsagePercent: 45.0,
            processingOverheadPercent: 8.5,
            detectionLatencyMs: 35.0
        )

        return ProcessingMetadata.createWithEnhancedData(
            for: UUID(),
            with: ProcessorConfig(),
            rallySegments: rallySegments,
            stats: processingStats,
            quality: qualityMetrics,
            trajectories: trajectoryData,
            classifications: [],
            physics: [],
            performance: performanceMetrics
        )
    }
}
#endif