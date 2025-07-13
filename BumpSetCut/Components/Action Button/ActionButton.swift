//
//  ActionButton.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/12/25.
//

import SwiftUI
import MijickCamera

struct ActionButton: View {
    let action: () -> ()


    var body: some View {
        Button(action: action, label: createButtonLabel)
    }
}
private extension ActionButton {
    func createButtonLabel() -> some View {
        Button(action: {
        }) {
            HStack {
                Image(systemName: "video.circle.fill")
                    .font(.title2)
                Text("Start New Game")
                    .font(.title2)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
    }
}
