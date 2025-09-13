//
//  BulkVideoMoveDialog.swift
//  BumpSetCut
//
//  Created by Claude on 9/1/25.
//

import SwiftUI

struct BulkVideoMoveDialog: View {
    let mediaStore: MediaStore
    let videoFileNames: [String]
    let currentFolder: String
    let onMove: (String) -> Void
    let onCancel: () -> Void
    
    @State private var selectedFolderPath: String = ""
    @State private var folders: [FolderMetadata] = []
    @State private var isLoading = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Move \(videoFileNames.count) Videos")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Select destination folder for all selected videos")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                
                // Current location
                if !currentFolder.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current Location:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(currentFolder.isEmpty ? "Root" : currentFolder)
                            .font(.body)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }
                
                // Video list preview
                VStack(alignment: .leading, spacing: 4) {
                    Text("Videos to move:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(videoFileNames.prefix(5), id: \.self) { fileName in
                                Text(URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent)
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(.systemGray5))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            
                            if videoFileNames.count > 5 {
                                Text("+\(videoFileNames.count - 5) more")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(.systemGray6))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                
                Divider()
                    .padding(.vertical, 8)
                
                // Folder list
                if isLoading {
                    VStack {
                        ProgressView()
                            .padding()
                        Text("Loading folders...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        // Root folder option
                        HStack {
                            Image(systemName: "house")
                                .foregroundColor(.blue)
                                .frame(width: 24, height: 24)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Root")
                                    .font(.body)
                                Text("Main folder")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if selectedFolderPath.isEmpty {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedFolderPath = ""
                        }
                        
                        // Other folders
                        ForEach(folders, id: \.id) { folder in
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundColor(.blue)
                                    .frame(width: 24, height: 24)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder.name)
                                        .font(.body)
                                    Text("\(folder.videoCount) videos")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                if selectedFolderPath == folder.path {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedFolderPath = folder.path
                            }
                            .opacity(folder.path == currentFolder ? 0.5 : 1.0)
                            .disabled(folder.path == currentFolder)
                        }
                    }
                    .listStyle(PlainListStyle())
                }
                
                // Action buttons
                HStack(spacing: 12) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    
                    Button("Move \(videoFileNames.count) Videos") {
                        onMove(selectedFolderPath)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canMoveToSelectedFolder ? Color.blue : Color(.systemGray4))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .disabled(!canMoveToSelectedFolder)
                }
                .padding()
            }
        }
        .onAppear {
            loadFolders()
            selectedFolderPath = currentFolder
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
    
    private var canMoveToSelectedFolder: Bool {
        selectedFolderPath != currentFolder && !isLoading
    }
    
    private func loadFolders() {
        isLoading = true
        
        Task {
            // Get all folders from MediaStore
            let rootFolders = mediaStore.getFolders(in: "")
            var allFolders = rootFolders
            
            // Recursively get subfolders
            for folder in rootFolders {
                allFolders.append(contentsOf: getAllSubfolders(in: folder.path))
            }
            
            await MainActor.run {
                folders = allFolders.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
                isLoading = false
            }
        }
    }
    
    private func getAllSubfolders(in path: String) -> [FolderMetadata] {
        let directFolders = mediaStore.getFolders(in: path)
        var allFolders = directFolders
        
        for folder in directFolders {
            allFolders.append(contentsOf: getAllSubfolders(in: folder.path))
        }
        
        return allFolders
    }
}

#Preview {
    BulkVideoMoveDialog(
        mediaStore: MediaStore(),
        videoFileNames: ["video1.mp4", "video2.mov", "video3.mp4"],
        currentFolder: "Folder1",
        onMove: { folderPath in
            print("Move to: \(folderPath)")
        },
        onCancel: {
            print("Cancelled")
        }
    )
}