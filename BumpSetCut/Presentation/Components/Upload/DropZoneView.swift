//
//  DropZoneView.swift
//  BumpSetCut
//
//  Created by Claude on 9/1/25.
//

import SwiftUI
import PhotosUI

struct DropZoneView<Content: View>: View {
    let uploadCoordinator: UploadCoordinator
    let destinationFolder: String
    let content: Content
    
    @State private var isDropping = false
    
    init(uploadCoordinator: UploadCoordinator, destinationFolder: String = "", @ViewBuilder content: () -> Content) {
        self.uploadCoordinator = uploadCoordinator
        self.destinationFolder = destinationFolder
        self.content = content()
    }
    
    var body: some View {
        ZStack {
            content
            
            if isDropping {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.blue, style: StrokeStyle(lineWidth: 2, dash: [10]))
                    )
                    .overlay(
                        VStack(spacing: 16) {
                            Image(systemName: "video.badge.plus")
                                .font(.system(size: 48))
                                .foregroundColor(.blue)
                            
                            Text("Drop videos here to upload")
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundColor(.blue)
                            
                            if !destinationFolder.isEmpty {
                                Text("To folder: \(destinationFolder)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground).opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    )
            }
        }
        .onDrop(of: ["public.movie"], delegate: DropViewDelegate(
            uploadCoordinator: uploadCoordinator,
            destinationFolder: destinationFolder,
            isDropping: $isDropping
        ))
    }
}

// MARK: - Upload Status Bar

struct UploadStatusBar: View {
    let uploadCoordinator: UploadCoordinator
    
    var body: some View {
        if uploadCoordinator.isUploadInProgress {
            let summary = uploadCoordinator.getUploadSummary()
            
            HStack(spacing: 12) {
                ProgressView(value: summary.overallProgress)
                    .frame(width: 60)
                    .tint(.blue)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.statusText)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text("\(Int(summary.overallProgress * 100))% complete")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Show") {
                    Task {
                        await UploadProgressPopup(uploadManager: uploadCoordinator.uploadProgress).present()
                    }
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue)
                .foregroundColor(.white)
                .clipShape(Capsule())
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
        }
    }
}

// MARK: - Enhanced Upload Button

struct EnhancedUploadButton: View {
    let uploadCoordinator: UploadCoordinator
    let destinationFolder: String
    
    @State private var showingPhotoPicker = false
    @State private var selectedItems: [PhotosPickerItem] = []
    
    var body: some View {
        Menu {
            Button {
                showingPhotoPicker = true
            } label: {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
            }
            
            Button {
                // This would trigger file picker for videos
                showingPhotoPicker = true
            } label: {
                Label("Browse Files", systemImage: "folder")
            }
            
            Divider()
            
            Text("Or drag and drop videos anywhere")
                .font(.caption)
                .foregroundColor(.secondary)
            
        } label: {
            HStack {
                Image(systemName: "plus")
                    .fontWeight(.medium)
                Text("Upload Videos")
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.blue)
            .foregroundColor(.white)
            .clipShape(Capsule())
        }
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $selectedItems,
            maxSelectionCount: 10,
            matching: .videos
        )
        .onChange(of: selectedItems) { _, items in
            if !items.isEmpty {
                uploadCoordinator.handleMultiplePhotosPickerItems(items, destinationFolder: destinationFolder)
                selectedItems.removeAll()
            }
        }
    }
}

#Preview {
    VStack {
        DropZoneView(uploadCoordinator: UploadCoordinator(mediaStore: MediaStore())) {
            VStack {
                Text("Content goes here")
                    .padding(40)
            }
        }
        
        EnhancedUploadButton(
            uploadCoordinator: UploadCoordinator(mediaStore: MediaStore()),
            destinationFolder: ""
        )
    }
}