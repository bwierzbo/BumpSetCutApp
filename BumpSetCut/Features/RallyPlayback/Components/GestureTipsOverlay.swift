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
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    // The arrow diagram must be tall enough to CONTAIN the offset arrows —
    // an undersized frame let the up arrow spill over the title (tester bug).
    private var compact: Bool { verticalSizeClass == .compact }
    private var verticalArrowOffset: CGFloat { compact ? 90 : 140 }
    private var diagramHeight: CGFloat { compact ? 290 : 420 }

    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.bscMediaScrimBase.opacity(0.9)
                .ignoresSafeArea()
                .opacity(showingContent ? 1 : 0)

            VStack(spacing: compact ? BSCSpacing.md : BSCSpacing.xxl) {
                // Title
                Text("Swipe Actions")
                    .bscFont(size: 28, weight: .bold)
                    .foregroundColor(.bscOnMedia)
                    .opacity(showingContent ? 1 : 0)
                    .offset(y: showingContent ? 0 : -20)

                // Center gesture diagram with animated arrows
                ZStack {
                    // UP arrow - Favorite
                    GestureArrow(direction: .up, label: "Favorite", icon: "star.fill", color: .bscPrimary)
                        .offset(y: -verticalArrowOffset)
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
                    RoundedRectangle(cornerRadius: BSCRadius.lg)
                        .fill(Color.bscMediaScrim)
                        .frame(width: 90, height: 130)
                        .overlay(
                            RoundedRectangle(cornerRadius: BSCRadius.lg)
                                .stroke(Color.bscOnMedia.opacity(0.2), lineWidth: 1)
                        )
                        .overlay(
                            VStack(spacing: BSCSpacing.sm) {
                                Image(systemName: "play.fill")
                                    .bscFont(size: 28)
                                    .foregroundColor(.bscPrimary)
                                Text("Rally")
                                    .bscFont(size: 12, weight: .bold)
                                    .foregroundColor(.bscOnMediaSecondary)
                            }
                        )
                        .scaleEffect(showingContent ? 1 : 0.8)
                        .opacity(showingContent ? 1 : 0)
                }
                .frame(height: diagramHeight)

                // Additional tips
                VStack(spacing: BSCSpacing.md) {
                    // Hold to trim hint
                    HStack(spacing: BSCSpacing.sm) {
                        Image(systemName: "hand.tap.fill")
                            .bscFont(size: 14, weight: .semibold)
                        Text("Hold to Trim & Adjust Angle")
                            .bscFont(size: 13, weight: .bold)
                    }
                    .foregroundColor(.bscOnMedia)
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
                            .bscFont(size: 14, weight: .semibold)
                        Text("Tap Counter for Overview")
                            .bscFont(size: 13, weight: .bold)
                    }
                    .foregroundColor(.bscOnMedia)
                    .padding(.horizontal, BSCSpacing.md)
                    .padding(.vertical, BSCSpacing.sm)
                    .background(Color.bscPrimary.opacity(0.25))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.bscPrimary.opacity(0.4), lineWidth: 1)
                    )
                }
                .accessibilityElement(children: .combine)
                .opacity(showingContent ? 1 : 0)
                .offset(y: showingContent ? 0 : 10)

                // Dismiss hint
                Text("Tap anywhere to continue")
                    .bscFont(size: 15)
                    .foregroundColor(.bscOnMediaSecondary)
                    .opacity(showingContent ? 1 : 0)
                    .offset(y: showingContent ? 0 : 20)
            }
            .padding(.horizontal, BSCSpacing.xl)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.bscQuick) {
                showingContent = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + BSCDuration.fast) {
                onDismiss()
            }
        }
        .onAppear {
            withAnimation(.bscSpring.delay(0.1)) {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                .bscFont(size: 28, weight: .bold)
                .foregroundColor(color)
                .offset(animationOffset)

            if direction != .down {
                labelView
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.bscFloat) {
                isAnimating = true
            }
        }
    }

    private var labelView: some View {
        HStack(spacing: BSCSpacing.xs) {
            Image(systemName: icon)
                .bscFont(size: 12, weight: .semibold)
            Text(label)
                .bscFont(size: 13, weight: .bold)
        }
        .foregroundColor(.bscOnMedia)
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
