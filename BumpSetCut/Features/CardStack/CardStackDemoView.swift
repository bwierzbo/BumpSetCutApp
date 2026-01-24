import SwiftUI

// MARK: - Card Stack Demo View

/// Demo view for testing card stack with placeholder cards
/// Provides manual testing interface before Phase 2 video integration
struct CardStackDemoView: View {
    // MARK: - State

    @State private var cards: [CardStackItem]

    // MARK: - Initialization

    init() {
        self._cards = State(wrappedValue: Self.generateSampleCards())
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                // Card stack
                CardStackView(cards: cards)

                // Debug overlay (top)
                VStack {
                    debugInfoOverlay
                    Spacer()
                }
            }
            .navigationTitle("Card Stack Demo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    resetButton
                }
            }
        }
    }

    // MARK: - Debug Info Overlay

    private var debugInfoOverlay: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total Cards: \(cards.count)")
                        .font(.caption)
                    Text("Saved: \(savedCount)")
                        .font(.caption)
                        .foregroundColor(.green)
                    Text("Removed: \(removedCount)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .cornerRadius(12)

                Spacer()
            }
        }
        .padding()
    }

    // MARK: - Reset Button

    private var resetButton: some View {
        Button(action: resetCards) {
            Image(systemName: "arrow.counterclockwise")
        }
    }

    // MARK: - Computed Properties

    private var savedCount: Int {
        cards.filter { $0.action == .save }.count
    }

    private var removedCount: Int {
        cards.filter { $0.action == .remove }.count
    }

    // MARK: - Actions

    private func resetCards() {
        withAnimation(.bscSpring) {
            cards = Self.generateSampleCards()
        }
    }

    // MARK: - Sample Data

    private static func generateSampleCards() -> [CardStackItem] {
        (1...10).map { index in
            CardStackItem(
                content: "Card \(index)"
            )
        }
    }
}

// MARK: - Preview

#Preview {
    CardStackDemoView()
}
