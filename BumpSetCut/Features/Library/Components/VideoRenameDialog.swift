//
//  VideoRenameDialog.swift
//  BumpSetCut
//
//  Created by Claude on 9/1/25.
//

import SwiftUI

struct VideoRenameDialog: View {
    let currentName: String
    let onRename: (String) -> Void
    let onCancel: () -> Void
    
    @State private var newName: String
    @FocusState private var isTextFieldFocused: Bool
    
    init(currentName: String, onRename: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.currentName = currentName
        self.onRename = onRename
        self.onCancel = onCancel
        self._newName = State(initialValue: currentName)
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rename Video")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Enter a new name for your video")
                        .font(.caption)
                        .foregroundColor(.bscTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Video Name")
                        .font(.headline)
                    
                    TextField("Enter video name", text: $newName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .focused($isTextFieldFocused)
                        .onSubmit {
                            handleRename()
                        }
                }
                
                Spacer()
                
                HStack(spacing: 12) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.bscSurfaceGlass)
                    .foregroundColor(.bscTextPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
                    
                    Button("Rename") {
                        handleRename()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.bscSurfaceGlass : Color.bscPrimary)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.bottom)
            }
            .padding()
            .onAppear {
                isTextFieldFocused = true
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
    
    private func handleRename() {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty && trimmedName != currentName else { return }
        
        onRename(trimmedName)
    }
}

#Preview {
    VideoRenameDialog(
        currentName: "My Video",
        onRename: { newName in
            print("Renamed to: \(newName)")
        },
        onCancel: {
            print("Cancelled")
        }
    )
}