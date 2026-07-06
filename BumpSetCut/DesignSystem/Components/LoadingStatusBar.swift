//
//  LoadingStatusBar.swift
//  BumpSetCut
//
//  Created by Claude on 9/1/25.
//

import SwiftUI

struct LoadingStatusBar: View {
    let isLoading: Bool
    let message: String
    
    init(isLoading: Bool, message: String = "Loading...") {
        self.isLoading = isLoading
        self.message = message
    }
    
    var body: some View {
        if isLoading {
            HStack(spacing: BSCSpacing.md) {
                ProgressView()
                    .scaleEffect(0.8)

                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.bscTextSecondary)

                Spacer()
            }
            .padding(.horizontal, BSCSpacing.lg)
            .padding(.vertical, BSCSpacing.md)
            .background(Color.bscBackground)
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(Color.bscSurfaceBorder),
                alignment: .top
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.bscStandard, value: isLoading)
        }
    }
}

#Preview {
    VStack {
        Spacer()
        LoadingStatusBar(isLoading: true, message: "Loading folders...")
    }
    .background(Color.bscBackgroundMuted)
}