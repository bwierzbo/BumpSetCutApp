//
//  FolderCardView.swift
//  BumpSetCut
//
//  Created by Claude on 9/1/25.
//

import SwiftUI

struct FolderCardView: View {
    let folder: FolderMetadata
    let onTap: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    
    @State private var showingRenameDialog = false
    @State private var showingDeleteConfirmation = false
    @State private var newName = ""
    
    var body: some View {
        VStack(spacing: 12) {
            // Folder icon
            Image(systemName: "folder.fill")
                .font(.system(size: 48))
                .foregroundColor(.blue)
            
            // Folder info
            VStack(spacing: 4) {
                Text(folder.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                
                HStack(spacing: 8) {
                    Label("\(folder.videoCount)", systemImage: "video.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    if folder.subfolderCount > 0 {
                        Label("\(folder.subfolderCount)", systemImage: "folder.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
        }
        .frame(height: 140)
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .contextMenu {
            Button {
                newName = folder.name
                showingRenameDialog = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .alert("Rename Folder", isPresented: $showingRenameDialog) {
            TextField("Folder name", text: $newName)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                onRename(newName)
            }
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter a new name for the folder.")
        }
        .alert("Delete Folder", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                onDelete()
            }
        } message: {
            Text(folder.videoCount > 0 ? 
                 "This folder contains \(folder.videoCount) videos. They will be moved to the parent folder." :
                 "Are you sure you want to delete this folder?")
        }
    }
}