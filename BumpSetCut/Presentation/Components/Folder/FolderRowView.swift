//
//  FolderRowView.swift
//  BumpSetCut
//
//  Created by Claude on 9/1/25.
//

import SwiftUI

struct FolderRowView: View {
    let folder: FolderMetadata
    let onTap: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    
    @State private var showingRenameDialog = false
    @State private var showingDeleteConfirmation = false
    @State private var newName = ""
    
    var body: some View {
        HStack(spacing: 16) {
            // Folder icon
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 40)
            
            // Folder info
            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name)
                    .font(.headline)
                    .lineLimit(1)
                
                HStack(spacing: 12) {
                    Label("\(folder.videoCount)", systemImage: "video.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if folder.subfolderCount > 0 {
                        Label("\(folder.subfolderCount)", systemImage: "folder.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Text(folder.modifiedDate, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Context menu button
            Menu {
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
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
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