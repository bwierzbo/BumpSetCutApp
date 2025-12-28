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
            HStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(0.8)
                
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(Color(.separator)),
                alignment: .top
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.3), value: isLoading)
        }
    }
}

#Preview {
    VStack {
        Spacer()
        LoadingStatusBar(isLoading: true, message: "Loading folders...")
    }
    .background(Color(.systemGroupedBackground))
}