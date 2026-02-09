import SwiftUI

// MARK: - Card Stack View

/// Main card stack container with depth effect and stable layering
/// Integrates SwipeableCard and CardActionButtons with CardStackViewModel
struct CardStackView: View {
    // MARK: - Properties

    @State private var viewModel: CardStackViewModel

    // MARK: - Initialization

    init(cards: [CardStackItem]) {
        self._viewModel = State(wrappedValue: CardStackViewModel(cards: cards))
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Color.bscMediaBackground.ignoresSafeArea()

                // Card stack with depth effect
                ZStack {
                    ForEach(viewModel.visibleCardIndices, id: \.self) { cardIndex in
                        let position = viewModel.stackPosition(for: cardIndex)
                        let card = viewModel.cards[cardIndex]

                        SwipeableCard(
                            dragOffset: $viewModel.dragOffset,
                            onSwipeLeft: { viewModel.performAction(.remove) },
                            onSwipeRight: { viewModel.performAction(.save) }
                        ) {
                            placeholderContent(
                                for: card,
                                position: position,
                                size: geometry.size
                            )
                        }
                        .scaleEffect(scaleForPosition(position))
                        .offset(y: offsetForPosition(position))
                        .opacity(opacityForPosition(position))
                        .animation(.bscSwipe, value: position)  // Smooth depth effect transitions
                        .zIndex(viewModel.zIndexForPosition(position))  // EXPLICIT ZINDEX
                    }
                }

                // Action buttons overlay (only on current card)
                if viewModel.currentCard != nil {
                    VStack {
                        Spacer()
                        CardActionButtons(
                            onRemove: { viewModel.performAction(.remove) },
                            onSave: { viewModel.performAction(.save) }
                        )
                    }
                    .zIndex(200)  // Above all cards
                }
            }
        }
        .edgesIgnoringSafeArea(.all)
    }

    // MARK: - Placeholder Content

    private func placeholderContent(for card: CardStackItem, position: Int, size: CGSize) -> some View {
        ZStack {
            // Background gradient (varies by card index)
            let cardNumber = viewModel.cards.firstIndex(where: { $0.id == card.id }) ?? 0
            let gradientColors = gradientColorsForCard(cardNumber)

            LinearGradient(
                colors: gradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Content
            VStack(spacing: 24) {
                Spacer()

                // Large card number
                Text("\(cardNumber + 1)")
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))

                // Card info
                Text("Card \(cardNumber + 1) of \(viewModel.totalCards)")
                    .font(.title2)
                    .fontWeight(.medium)
                    .foregroundColor(.white.opacity(0.7))

                Spacer()

                // Visual reference for button positions
                HStack(spacing: 60) {
                    VStack(spacing: 8) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 32))
                        Text("Swipe Left")
                            .font(.caption)
                    }
                    .foregroundColor(.white.opacity(0.4))

                    VStack(spacing: 8) {
                        Image(systemName: "heart.circle")
                            .font(.system(size: 32))
                        Text("Swipe Right")
                            .font(.caption)
                    }
                    .foregroundColor(.white.opacity(0.4))
                }
                .padding(.bottom, 120)  // Space for actual buttons
            }
        }
        .frame(width: size.width, height: size.height)
        .cornerRadius(position == 0 ? 0 : 20)  // Only round corners on background cards
        .shadow(radius: position == 0 ? 0 : 10)
    }

    // MARK: - Depth Effect Calculations

    /// Scale effect for card stack - no scaling, cards directly behind
    private func scaleForPosition(_ position: Int) -> CGFloat {
        return 1.0  // All cards same size (no depth scaling)
    }

    /// Y-offset for card stack - no offset, cards directly behind
    private func offsetForPosition(_ position: Int) -> CGFloat {
        return 0  // All cards aligned (no depth offset)
    }

    /// Opacity for card stack visibility
    private func opacityForPosition(_ position: Int) -> Double {
        switch position {
        case -1: return 0.0   // Previous (hidden)
        case 0: return 1.0    // Current (fully visible)
        case 1: return 0.8    // Next (slightly dimmed for depth)
        default: return 0.0   // Further cards (hidden)
        }
    }

    // MARK: - Gradient Colors

    private func gradientColorsForCard(_ index: Int) -> [Color] {
        let colorSets: [[Color]] = [
            [.blue, .purple],
            [.orange, .red],
            [.green, .teal],
            [.pink, .purple],
            [.cyan, .blue],
            [.yellow, .orange],
            [.mint, .green],
            [.indigo, .purple],
            [.red, .pink],
            [.teal, .cyan]
        ]

        return colorSets[index % colorSets.count]
    }
}

// MARK: - Preview

#Preview {
    CardStackView(cards: [
        CardStackItem(content: "Card 1"),
        CardStackItem(content: "Card 2"),
        CardStackItem(content: "Card 3")
    ])
}
