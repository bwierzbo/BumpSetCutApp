import SwiftUI

// MARK: - Rally Gesture State

/// Manages all gesture-related state: drag, zoom, swipe offsets, rotation,
/// and peek preview. Marked @Observable so SwiftUI tracks property changes
/// for rendering.
@MainActor
@Observable
final class RallyGestureState {
    // MARK: - Drag Axis Lock

    enum DragAxis {
        case horizontal
        case vertical
    }

    var dragAxis: DragAxis?

    // MARK: - Drag State

    var dragOffset: CGSize = .zero
    var isDragging: Bool = false
    var bounceOffset: CGFloat = 0.0

    // MARK: - Zoom State

    var zoomScale: CGFloat = 1.0
    var zoomOffset: CGSize = .zero
    var baseZoomScale: CGFloat = 1.0
    var baseZoomOffset: CGSize = .zero

    var isZoomed: Bool { zoomScale > 1.01 }

    // MARK: - Swipe / Transition Offsets

    var swipeOffset: CGFloat = 0.0
    var swipeOffsetY: CGFloat = 0.0
    var swipeRotation: Double = 0.0
    var actionSwipeOffsetY: CGFloat = 0.0

    // MARK: - Peek State

    var peekProgress: Double = 0.0
    var currentPeekDirection: RallyPeekDirection?
    var peekThumbnail: UIImage?

    // MARK: - Zoom Methods

    func resetZoom() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            zoomScale = 1.0
            zoomOffset = .zero
        }
        baseZoomScale = 1.0
        baseZoomOffset = .zero
    }

    // MARK: - Swipe Methods

    func resetSwipeState() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            swipeOffset = 0
            swipeOffsetY = 0
            swipeRotation = 0
            actionSwipeOffsetY = 0
            dragOffset = .zero
        }
        dragAxis = nil
    }

    // MARK: - Peek Methods

    func updatePeekProgress(translation: CGSize, dimension: CGFloat, isPortrait: Bool) {
        let primaryTranslation = isPortrait ? -translation.height : translation.width
        let threshold = dimension * 0.15

        let rawProgress = abs(primaryTranslation) / threshold
        peekProgress = min(1.0, rawProgress)

        if isPortrait {
            currentPeekDirection = translation.height < 0 ? .next : .previous
        } else {
            currentPeekDirection = translation.width > 0 ? .previous : .next
        }
    }

    func resetPeekProgress() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            peekProgress = 0.0
            currentPeekDirection = nil
            peekThumbnail = nil
        }
    }

    func loadPeekThumbnail(currentIndex: Int, urls: [URL], thumbnailCache: RallyThumbnailCache) {
        guard let direction = currentPeekDirection else { return }

        let targetIndex = direction == .next ? currentIndex + 1 : currentIndex - 1
        guard targetIndex >= 0 && targetIndex < urls.count else { return }

        let url = urls[targetIndex]
        peekThumbnail = thumbnailCache.getThumbnail(for: url)
    }
}
