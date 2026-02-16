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
    var uploadCoordinator: UploadCoordinator
    @State private var uploadedVideoURL: URL?

    var body: some View {
        let _ = print("🔄 UploadStatusBar.body called - isUploadInProgress=\(uploadCoordinator.isUploadInProgress)")

        return Group {
            if uploadCoordinator.isUploadInProgress {
                let _ = print("✅ Progress bar should be visible!")
                
                VStack(spacing: 24) {
                    createHeaderView()
                    
                    if uploadCoordinator.showCompleted {
                        createCompletedView()
                    } else {
                        createUploadingView(progress: 0.0) // Progress not used anymore
                    }
                    
                    if uploadCoordinator.showCompleted {
                        createActionButtons()
                    } else {
                        createCancelButton()
                    }
                }
                .padding(24)
                .background(Color(.systemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            } else {
                let _ = print("❌ Progress bar should NOT be visible")
                EmptyView()
            }
        }
    }
    
    // MARK: - Upload Status Bar Components
    
    private func createCancelButton() -> some View {
        Button("Cancel") {
            uploadCoordinator.cancelUploadFlow()
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.red)
        .foregroundColor(.white)
        .cornerRadius(12)
    }
    
    private func createHeaderView() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 48))
                .foregroundColor(.blue)
            
            Text("Processing Video")
                .font(.title2)
                .fontWeight(.bold)
        }
    }
    
    private func createUploadingView(progress: Double) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .progressViewStyle(CircularProgressViewStyle())

            // Show progress text from coordinator
            if !uploadCoordinator.uploadProgressText.isEmpty {
                Text(uploadCoordinator.uploadProgressText)
                    .font(.headline)
                    .foregroundColor(.primary)
            } else {
                Text("Processing video...")
                    .font(.headline)
                    .foregroundColor(.primary)
            }

            // Show file size if available
            if !uploadCoordinator.currentFileSize.isEmpty {
                Text(uploadCoordinator.currentFileSize)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Show elapsed time
            if uploadCoordinator.elapsedTime > 2 {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption)
                    Text(formatTime(uploadCoordinator.elapsedTime))
                        .font(.caption)
                        .monospacedDigit()
                }
                .foregroundColor(.secondary)
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return String(format: "%d:%02d", mins, secs)
        } else {
            return "\(secs)s"
        }
    }
    
    private func createCompletedView() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(.green)
            
            Text("Upload Complete!")
                .font(.headline)
                .foregroundColor(.primary)
            
            Text("Video uploaded and automatically named with today's date")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    private func createActionButtons() -> some View {
        Button("Done") {
            print("✅ Done button pressed")
            uploadCoordinator.completeUploadFlow()
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.green)
        .foregroundColor(.white)
        .cornerRadius(12)
    }
    
    
}

// MARK: - Enhanced Upload Button

struct EnhancedUploadButton: View {
    let uploadCoordinator: UploadCoordinator
    let destinationFolder: String

    @State private var showingPhotoPicker = false
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var showingNamingDialog = false
    @State private var pendingVideoURL: URL?  // URL-based: keeps video on disk
    @State private var videoFileName = ""
    @State private var customVideoName = ""
    
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
            maxSelectionCount: 1, // Limited to single video for now
            matching: .videos
        )
        .onChange(of: selectedItems) { _, items in
            if !items.isEmpty, let item = items.first {
                uploadCoordinator.handlePhotosPickerItem(item, destinationFolder: destinationFolder)
                selectedItems.removeAll()
            }
        }
        .sheet(isPresented: $showingNamingDialog) {
            VideoNamingSheet(
                customName: $customVideoName,
                onSave: {
                    if let url = pendingVideoURL {
                        let finalName = customVideoName.isEmpty ? videoFileName : customVideoName
                        saveVideoWithName(url: url, name: finalName)
                    }
                    showingNamingDialog = false
                },
                onCancel: {
                    showingNamingDialog = false
                    // Clean up temp file
                    if let url = pendingVideoURL {
                        try? FileManager.default.removeItem(at: url)
                    }
                    pendingVideoURL = nil
                }
            )
        }
    }

    private func handleVideoSelection(_ item: PhotosPickerItem) {
        Task {
            // Use file-based transfer - never load entire video into memory
            guard let movie = try? await item.loadTransferable(type: VideoTransferable.self) else {
                print("Failed to load video as file")
                return
            }

            await MainActor.run {
                self.pendingVideoURL = movie.url
                self.videoFileName = "Video_\(DateFormatter.yyyyMMdd_HHmmss.string(from: Date()))"
                self.customVideoName = ""
                self.showingNamingDialog = true
            }
        }
    }

    private func saveVideoWithName(url: URL, name: String) {
        Task {
            let fileName = name.hasSuffix(".mp4") ? name : "\(name).mp4"
            await uploadCoordinator.uploadManager.addUpload(
                url: url,
                fileName: fileName,
                destinationFolderPath: destinationFolder
            )

            // Start the upload immediately
            if let uploadItem = uploadCoordinator.uploadManager.uploadItems.last {
                uploadItem.displayName = name
                uploadItem.finalName = name
                uploadCoordinator.uploadManager.startUpload(item: uploadItem, customName: name)
            }
        }
    }
}

// MARK: - Simple Video Naming Sheet

struct VideoNamingSheet: View {
    @Binding var customName: String
    let onSave: () -> Void
    let onCancel: () -> Void
    
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Name Your Video")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Enter a name for your video")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Video Name")
                        .font(.headline)
                    
                    TextField("Enter video name", text: $customName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .focused($isTextFieldFocused)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Spacer()
            }
            .padding()
            .navigationTitle("Name Video")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("Cancel") {
                    onCancel()
                },
                trailing: Button("Save") {
                    onSave()
                }
                .fontWeight(.semibold)
            )
        }
        .onAppear {
            isTextFieldFocused = true
        }
    }
}

// MARK: - Date Formatter Extension

extension DateFormatter {
    static let yyyyMMdd_HHmmss: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()
    
    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter
    }()
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