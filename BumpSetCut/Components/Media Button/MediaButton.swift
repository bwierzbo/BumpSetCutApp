//
//  MediaButton.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/12/25.
//


import SwiftUI
import MijickCamera

struct MediaButton: View {
    let action: () -> ()


    var body: some View {
        Button(action: action, label: createButtonLabel)
    }
}
private extension MediaButton {
    func createButtonLabel() -> some View {
        Button(action: {
        }) {
            HStack {
                Image(systemName: "video.circle.fill")
                    .font(.title2)
                Text("Saved Games")
                    .font(.title2)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.green)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
    }
}
