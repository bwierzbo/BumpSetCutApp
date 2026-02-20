//
//  GestureTipsOverlay.swift
//  BumpSetCut
//
//  Animated overlay showing swipe gesture hints for Rally Player
//

import SwiftUI

// MARK: - GestureTipsOverlay

struct GestureTipsOverlay: View {
    let onDismiss: () -> Void
    @State private var showingContent = false

    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.9)
                .ignoresSafeArea()
                .opacity(showingContent ? 1 : 0)

            VStack(spacing: 40) {
                // Title
                Text("Swipe Actions")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
                    .opacity(showingContent ? 1 : 0)
                    .offset(y: showingContent ? 0 : -20)

                // Center gesture diagram with animated arrows
                ZStack {
                    // UP arrow - Favorite
                    GestureArrow(direction: .up, label: "Favorite", icon: "star.fill", color: .bscPrimary)
                        .offset(y: -140)
                        .opacity(showingContent ? 1 : 0)

                    // LEFT arrow - Remove
                    GestureArrow(direction: .left, label: "Remove", icon: "xmark", color: .bscError)
                        .offset(x: -140)
                        .opacity(showingContent ? 1 : 0)

                    // RIGHT arrow - Save
                    GestureArrow(direction: .right, label: "Save", icon: "heart.fill", color: .bscSuccess)
                        .offset(x: 140)
                        .opacity(showingContent ? 1 : 0)

                    // Center card representation
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.bscSurfaceGlass)
                        .frame(width: 90, height: 130)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                        .overlay(
                            VStack(spacing: BSCSpacing.sm) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(.bscPrimary)
                                Text("Rally")
                                    .font(.caption.bold())
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        )
                        .scaleEffect(showingContent ? 1 : 0.8)
                        .opacity(showingContent ? 1 : 0)
                }
                .frame(height: 240)

                // Additional tips
                VStack(spacing: BSCSpacing.md) {
                    // Hold to trim hint
                    HStack(spacing: BSCSpacing.sm) {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Hold to Trim")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, BSCSpacing.md)
                    .padding(.vertical, BSCSpacing.sm)
                    .background(Color.bscPrimary.opacity(0.25))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.bscPrimary.opacity(0.4), lineWidth: 1)
                    )

                    // Tap counter for overview hint
                    HStack(spacing: BSCSpacing.sm) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Tap Counter for Overview")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, BSCSpacing.md)
                    .padding(.vertical, BSCSpacing.sm)
                    .background(Color.bscPrimary.opacity(0.25))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.bscPrimary.opacity(0.4), lineWidth: 1)
                    )
                }
                .opacity(showingContent ? 1 : 0)
                .offset(y: showingContent ? 0 : 10)

                // Dismiss hint
                Text("Tap anywhere to continue")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.5))
                    .opacity(showingContent ? 1 : 0)
                    .offset(y: showingContent ? 0 : 20)
            }
            .padding(.horizontal, BSCSpacing.xl)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.2)) {
                showingContent = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                onDismiss()
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
                showingContent = true
            }
        }
    }
}

// MARK: - GestureArrow

private struct GestureArrow: View {
    let direction: ArrowDirection
    let label: String
    let icon: String
    let color: Color

    @State private var isAnimating = false

    enum ArrowDirection {
        case up, down, left, right
    }

    var body: some View {
        VStack(spacing: BSCSpacing.sm) {
            if direction == .down {
                labelView
            }

            // Animated arrow
            Image(systemName: arrowIcon)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(color)
                .offset(animationOffset)

            if direction != .down {
                labelView
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }

    private var labelView: some View {
        HStack(spacing: BSCSpacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(label)
                .font(.system(size: 13, weight: .bold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, BSCSpacing.md)
        .padding(.vertical, BSCSpacing.sm)
        .background(color.opacity(0.25))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(color.opacity(0.4), lineWidth: 1)
        )
    }

    private var arrowIcon: String {
        switch direction {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        }
    }

    private var animationOffset: CGSize {
        let distance: CGFloat = isAnimating ? 8 : 0
        switch direction {
        case .up: return CGSize(width: 0, height: -distance)
        case .down: return CGSize(width: 0, height: distance)
        case .left: return CGSize(width: -distance, height: 0)
        case .right: return CGSize(width: distance, height: 0)
        }
    }
}

// MARK: - Preview

#Preview {
    GestureTipsOverlay(onDismiss: {})
}
