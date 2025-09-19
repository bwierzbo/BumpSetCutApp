//
//  BufferingView.swift
//  BumpSetCut
//
//  Created for Rally Swiping Fixes Epic - Video Loading Issue Fix
//  Provides visual feedback during video buffering to prevent black screen with audio
//

import SwiftUI

struct BufferingView: View {
    let isBuffering: Bool
    let progress: Double
    let message: String
    let hasTimeout: Bool

    init(
        isBuffering: Bool,
        progress: Double = 0.0,
        message: String = "Loading video...",
        hasTimeout: Bool = false
    ) {
        self.isBuffering = isBuffering
        self.progress = progress
        self.message = message
        self.hasTimeout = hasTimeout
    }

    var body: some View {
        if isBuffering {
            ZStack {
                // Semi-transparent background
                Color.black.opacity(0.8)
                    .ignoresSafeArea()

                VStack(spacing: 24) {
                    // Animated loading indicator
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 3)
                            .frame(width: 60, height: 60)

                        if hasTimeout {
                            // Error icon for timeout
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.title2)
                                .foregroundColor(.orange)
                        } else if progress > 0 {
                            // Progress circle
                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(Color.white, lineWidth: 3)
                                .frame(width: 60, height: 60)
                                .rotationEffect(.degrees(-90))
                                .animation(.easeInOut(duration: 0.3), value: progress)
                        } else {
                            // Spinning indicator
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.2)
                        }
                    }

                    VStack(spacing: 8) {
                        Text(hasTimeout ? "Loading timeout" : message)
                            .font(.headline)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)

                        if hasTimeout {
                            Text("Video loading is taking longer than expected")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                        } else if progress > 0 {
                            Text("\(Int(progress * 100))%")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                }
                .padding(40)
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: isBuffering)
        }
    }
}

// MARK: - Convenience Initializers
extension BufferingView {
    static func forVideoLoading(isBuffering: Bool, progress: Double = 0.0) -> BufferingView {
        BufferingView(
            isBuffering: isBuffering,
            progress: progress,
            message: "Preparing video..."
        )
    }

    static func forVideoTimeout(isBuffering: Bool) -> BufferingView {
        BufferingView(
            isBuffering: isBuffering,
            message: "Loading timeout",
            hasTimeout: true
        )
    }
}

#Preview {
    ZStack {
        Color.blue
            .ignoresSafeArea()

        BufferingView(
            isBuffering: true,
            progress: 0.6,
            message: "Loading rally video..."
        )
    }
}

#Preview("Timeout State") {
    ZStack {
        Color.blue
            .ignoresSafeArea()

        BufferingView.forVideoTimeout(isBuffering: true)
    }
}

#Preview("Initial Loading") {
    ZStack {
        Color.blue
            .ignoresSafeArea()

        BufferingView.forVideoLoading(isBuffering: true)
    }
}