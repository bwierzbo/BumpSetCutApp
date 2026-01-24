import SwiftUI

// MARK: - Swipeable Card

/// Generic swipeable card component with gesture-driven animations
/// Accepts any content via @ViewBuilder and provides drag-to-swipe interactions
struct SwipeableCard<Content: View>: View {
    // MARK: - Properties

    let content: Content
    let onSwipeLeft: () -> Void
    let onSwipeRight: () -> Void

    @Binding var dragOffset: CGSize
    @State private var rotation: Double = 0

    // MARK: - Constants

    private let translationThreshold: CGFloat = 120
    private let velocityThreshold: CGFloat = 300
    private let maxRotation: Double = 15

    // MARK: - Initialization

    init(
        dragOffset: Binding<CGSize>,
        onSwipeLeft: @escaping () -> Void,
        onSwipeRight: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self._dragOffset = dragOffset
        self.onSwipeLeft = onSwipeLeft
        self.onSwipeRight = onSwipeRight
        self.content = content()
    }

    // MARK: - Body

    var body: some View {
        content
            .offset(x: dragOffset.width, y: dragOffset.height)
            .rotationEffect(.degrees(rotation))
            .gesture(dragGesture)
    }

    // MARK: - Gesture

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation

                // Calculate rotation during drag (research line 229-232)
                let rotationAmount = Double(value.translation.width) / 20.0
                rotation = max(-maxRotation, min(maxRotation, rotationAmount))
            }
            .onEnded { value in
                let horizontalOffset = value.translation.width
                let horizontalVelocity = value.velocity.width

                // Velocity OR distance triggers action (research line 330)
                if abs(horizontalVelocity) > velocityThreshold || abs(horizontalOffset) > translationThreshold {
                    if horizontalOffset < -translationThreshold {
                        // Swipe left - remove
                        onSwipeLeft()
                    } else if horizontalOffset > translationThreshold {
                        // Swipe right - save
                        onSwipeRight()
                    }
                }

                // Spring back to center (use .bscSnappy from AnimationTokens)
                withAnimation(.bscSnappy) {
                    dragOffset = .zero
                    rotation = 0
                }
            }
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var dragOffset: CGSize = .zero

    SwipeableCard(
        dragOffset: $dragOffset,
        onSwipeLeft: { print("Swiped left") },
        onSwipeRight: { print("Swiped right") }
    ) {
        RoundedRectangle(cornerRadius: 20)
            .fill(.blue)
            .frame(width: 300, height: 400)
            .overlay {
                Text("Swipe me!")
                    .font(.largeTitle)
                    .foregroundColor(.white)
            }
            .shadow(radius: 10)
    }
}
