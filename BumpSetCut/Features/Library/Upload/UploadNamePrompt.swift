//
//  UploadNamePrompt.swift
//  BumpSetCut
//
//  Shared upfront naming alert for video uploads. Presented right after
//  picking a video; the import then runs in the background behind the
//  global upload pill. Skip commits nil and the coordinator applies a
//  dated default name.
//

import SwiftUI

struct UploadNamePrompt: ViewModifier {
    @Binding var isPresented: Bool
    let onCommit: (String?) -> Void

    @State private var nameInput = ""

    func body(content: Content) -> some View {
        content
            .alert("Name Your Video", isPresented: $isPresented) {
                TextField("Video name", text: $nameInput)
                    .onChange(of: nameInput) { _, newValue in
                        let stripped = String(newValue.drop(while: { $0.isWhitespace }))
                        let limited = String(stripped.prefix(100))
                        if limited != newValue {
                            nameInput = limited
                        }
                    }
                Button("Upload") {
                    onCommit(nameInput)
                    nameInput = ""
                }
                .disabled(nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Skip", role: .cancel) {
                    onCommit(nil)
                    nameInput = ""
                }
            } message: {
                Text("Give your video a custom name")
            }
    }
}

extension View {
    func uploadNamePrompt(isPresented: Binding<Bool>, onCommit: @escaping (String?) -> Void) -> some View {
        modifier(UploadNamePrompt(isPresented: isPresented, onCommit: onCommit))
    }
}
