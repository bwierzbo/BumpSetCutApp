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
            VStack(spacing: BSCSpacing.xl) {
                VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                    Text("Rename Video")
                        .bscFont(size: 20, weight: .semibold)

                    Text("Enter a new name for your video")
                        .bscFont(size: 12)
                        .foregroundColor(.bscTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                    Text("Video Name")
                        .bscFont(size: 14, weight: .semibold)

                    TextField("Enter video name", text: $newName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .focused($isTextFieldFocused)
                        .onSubmit {
                            handleRename()
                        }
                }

                Spacer()

                HStack(spacing: BSCSpacing.md) {
                    Button {
                        onCancel()
                    } label: {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                            .padding(BSCSpacing.lg)
                            .background(Color.bscSurfaceGlass)
                            .foregroundColor(.bscTextPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
                    }

                    Button {
                        handleRename()
                    } label: {
                        Text("Rename")
                            .frame(maxWidth: .infinity)
                            .padding(BSCSpacing.lg)
                            .background(isNameEmpty ? Color.bscSurfaceGlass : Color.bscPrimaryFill)
                            .foregroundColor(isNameEmpty ? .bscTextTertiary : .bscOnPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
                    }
                    .disabled(isNameEmpty)
                }
                .padding(.bottom)
            }
            .padding()
            .background(Color.bscBackground)
            .onAppear {
                isTextFieldFocused = true
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
    
    private var isNameEmpty: Bool {
        newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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