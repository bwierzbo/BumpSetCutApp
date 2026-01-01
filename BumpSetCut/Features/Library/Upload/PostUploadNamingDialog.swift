//
//  PostUploadNamingDialog.swift
//  BumpSetCut
//
//  Simple naming dialog shown after video upload completes
//

import SwiftUI
import MijickPopups

struct PostUploadNamingDialog: CenterPopup {
    let suggestedName: String
    let onSave: (String) -> Void
    let onSkip: () -> Void

    @State private var videoName: String
    @FocusState private var isTextFieldFocused: Bool

    init(suggestedName: String, onSave: @escaping (String) -> Void, onSkip: @escaping () -> Void) {
        self.suggestedName = suggestedName
        self.onSave = onSave
        self.onSkip = onSkip
        self._videoName = State(initialValue: suggestedName)
    }

    func configurePopup(config: CenterPopupConfig) -> CenterPopupConfig {
        config
            .backgroundColor(.clear)
            .cornerRadius(16)
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Name Your Video")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Give your video a custom name or keep the default")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Name input
            TextField("Video name", text: $videoName)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .focused($isTextFieldFocused)

            // Actions
            HStack(spacing: 12) {
                Button("Skip") {
                    Task { @MainActor in
                        await dismissLastPopup()
                        onSkip()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.systemGray5))
                .foregroundColor(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Button("Save") {
                    let finalName = videoName.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { @MainActor in
                        await dismissLastPopup()
                        onSave(finalName.isEmpty ? suggestedName : finalName)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 24)
        .onAppear {
            isTextFieldFocused = true
        }
    }
}
