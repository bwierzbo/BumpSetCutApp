//
//  RallyPlayerView+Gestures.swift
//  BumpSetCut
//
//  Card gestures for the rally player: swipe actions, viewing pinch/zoom,
//  and trim-mode direct manipulation (pinch zoom · twist angle · drag pan).
//

import SwiftUI

extension RallyPlayerView {
    // MARK: - Gesture Handling

    func swipeGesture(geometry: GeometryProxy) -> some Gesture {
        DragGesture()
            .onChanged { value in
                // Ignore gestures during transitions
                guard !viewModel.isTransitioning, !viewModel.isPerformingAction else { return }

                viewModel.isDragging = true

                if viewModel.isZoomed {
                    // Pan within zoomed content
                    let newOffset = CGSize(
                        width: viewModel.baseZoomOffset.width + value.translation.width,
                        height: viewModel.baseZoomOffset.height + value.translation.height
                    )
                    viewModel.zoomOffset = clampedOffset(newOffset, scale: viewModel.zoomScale, cardSize: geometry.size)
                } else {
                    // Lock drag axis after initial movement exceeds threshold
                    if viewModel.dragAxis == nil {
                        let absW = abs(value.translation.width)
                        let absH = abs(value.translation.height)
                        if absW > 10 || absH > 10 {
                            viewModel.dragAxis = absW >= absH ? .horizontal : .vertical
                            // Subtle tick the moment the swipe direction is committed.
                            UIImpactFeedbackGenerator.light()
                        }
                    }

                    switch viewModel.dragAxis {
                    case .horizontal, .none:
                        viewModel.dragOffset = CGSize(width: value.translation.width, height: 0)
                    case .vertical:
                        // Only track upward drags (negative height)
                        let clampedHeight = min(value.translation.height, 0)
                        viewModel.dragOffset = CGSize(width: 0, height: clampedHeight)
                    }
                }
            }
            .onEnded { value in
                // Ignore gestures during transitions
                guard !viewModel.isTransitioning, !viewModel.isPerformingAction else { return }

                let lockedAxis = viewModel.dragAxis
                viewModel.isDragging = false
                viewModel.dragAxis = nil

                if viewModel.isZoomed {
                    // Snap offset to bounds
                    viewModel.baseZoomOffset = viewModel.zoomOffset
                    return
                }

                let actionThreshold: CGFloat = 150

                if lockedAxis == .vertical {
                    // Vertical swipe-up → favorite
                    let verticalOffset = viewModel.dragOffset.height  // negative = up
                    let verticalVelocity = value.velocity.height       // negative = up
                    let triggeredByVelocity = verticalVelocity < -300
                    let triggeredByDistance = verticalOffset < -actionThreshold

                    if triggeredByVelocity || triggeredByDistance {
                        viewModel.performAction(.favorite, direction: .up, fromDragOffset: viewModel.dragOffset.height)
                        return
                    }
                } else {
                    // Horizontal swipe → save/remove
                    let horizontalOffset = viewModel.dragOffset.width
                    let horizontalVelocity = value.velocity.width
                    let dragWidth = viewModel.dragOffset.width

                    let triggeredByVelocity = abs(horizontalVelocity) > 300
                    let triggeredByDistance = abs(horizontalOffset) > actionThreshold

                    if triggeredByVelocity || triggeredByDistance {
                        if horizontalOffset < 0 || (triggeredByVelocity && horizontalVelocity < -300) {
                            viewModel.performAction(.remove, direction: .left, fromDragOffset: dragWidth)
                            return
                        } else if horizontalOffset > 0 || (triggeredByVelocity && horizontalVelocity > 300) {
                            viewModel.performAction(.save, direction: .right, fromDragOffset: dragWidth)
                            return
                        }
                    }
                }

                // No action - animate back to center
                withAnimation(.bscSwipe) {
                    viewModel.dragOffset = .zero
                }
            }
    }

    // MARK: - Pinch-to-Zoom

    func pinchGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let clamped = min(max(viewModel.baseZoomScale * value, 1.0), 5.0)
                // Tick once when first reaching the zoom cap.
                if clamped == 5.0 && viewModel.zoomScale < 5.0 {
                    UIImpactFeedbackGenerator.light()
                }
                viewModel.zoomScale = clamped
            }
            .onEnded { value in
                let newScale = viewModel.baseZoomScale * value
                viewModel.zoomScale = min(max(newScale, 1.0), 5.0)
                viewModel.baseZoomScale = viewModel.zoomScale

                if viewModel.zoomScale <= 1.01 {
                    viewModel.resetZoom()
                }
            }
    }

    func toggleZoom(cardSize: CGSize) {
        if viewModel.isZoomed {
            viewModel.resetZoom()
        } else {
            withAnimation(.bscSnappy) {
                viewModel.zoomScale = 2.5
                viewModel.zoomOffset = .zero
            }
            viewModel.baseZoomScale = 2.5
            viewModel.baseZoomOffset = .zero
        }
    }

    // MARK: - Trim-Mode Editing (pinch zoom · twist angle · drag pan)

    /// Maximum crop zoom in trim mode.
    private static let trimZoomLimit: CGFloat = 3.0

    /// The live crop zoom (what confirmTrim saves), for the trim overlay's
    /// readout and its VoiceOver-adjustable zoom control.
    func liveTrimZoom(cardSize: CGSize) -> Binding<Double> {
        Binding(
            get: { Double(viewModel.zoomScale) },
            set: { newValue in
                let scale = min(max(CGFloat(newValue), 1.0), Self.trimZoomLimit)
                viewModel.zoomScale = scale
                viewModel.zoomOffset = clampedOffset(viewModel.zoomOffset, scale: scale, cardSize: cardSize)
                viewModel.baseZoomScale = scale
                viewModel.baseZoomOffset = viewModel.zoomOffset
            }
        )
    }

    func trimEditGesture(geometry: GeometryProxy) -> some Gesture {
        let zoomLimit = Self.trimZoomLimit
        let angleLimit: Double = 10.0

        let magnify = MagnificationGesture()
            .onChanged { value in
                let newScale = min(max(viewModel.baseZoomScale * value, 1.0), zoomLimit)
                // Tick once when first reaching the zoom cap.
                if newScale == zoomLimit && viewModel.zoomScale < zoomLimit {
                    UIImpactFeedbackGenerator.light()
                }
                viewModel.zoomScale = newScale
                viewModel.zoomOffset = clampedOffset(viewModel.zoomOffset, scale: newScale, cardSize: geometry.size)
            }
            .onEnded { _ in
                viewModel.baseZoomScale = viewModel.zoomScale
                viewModel.baseZoomOffset = viewModel.zoomOffset
            }

        let twist = RotationGesture()
            .onChanged { angle in
                if twistBaseRotation == nil { twistBaseRotation = viewModel.currentTrimRotation }
                let proposed = (twistBaseRotation ?? 0) + angle.degrees
                viewModel.currentTrimRotation = min(max(proposed, -angleLimit), angleLimit)
            }
            .onEnded { _ in
                twistBaseRotation = nil
            }

        let pan = DragGesture()
            .onChanged { value in
                let proposed = CGSize(
                    width: viewModel.baseZoomOffset.width + value.translation.width,
                    height: viewModel.baseZoomOffset.height + value.translation.height
                )
                viewModel.zoomOffset = clampedOffset(proposed, scale: viewModel.zoomScale, cardSize: geometry.size)
            }
            .onEnded { _ in
                viewModel.baseZoomOffset = viewModel.zoomOffset
            }

        return magnify.simultaneously(with: twist).simultaneously(with: pan)
    }

    /// Reset the live editing zoom/pan to 1× / centered (overlay reset button).
    func resetTrimZoom() {
        withAnimation(.bscSnappy) {
            viewModel.zoomScale = 1.0
            viewModel.zoomOffset = .zero
        }
        viewModel.baseZoomScale = 1.0
        viewModel.baseZoomOffset = .zero
    }

    /// Clamp pan offset so zoomed content stays visible
    private func clampedOffset(_ offset: CGSize, scale: CGFloat, cardSize: CGSize) -> CGSize {
        let maxX = max(0, (cardSize.width * scale - cardSize.width) / 2)
        let maxY = max(0, (cardSize.height * scale - cardSize.height) / 2)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }
}
