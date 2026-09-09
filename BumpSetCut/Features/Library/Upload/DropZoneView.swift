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
                RoundedRectangle(cornerRadius: BSCRadius.md)
                    .fill(Color.bscPrimary.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: BSCRadius.md)
                            .strokeBorder(Color.bscPrimary, style: StrokeStyle(lineWidth: 2, dash: [10]))
                    )
                    .overlay(
                        VStack(spacing: BSCSpacing.lg) {
                            Image(systemName: "video.badge.plus")
                                .bscFont(size: 48)
                                .foregroundColor(.bscPrimary)

                            Text("Drop videos here to upload")
                                .bscFont(size: 20, weight: .semibold)
                                .foregroundColor(.bscPrimaryText)

                            if !destinationFolder.isEmpty {
                                Text("To folder: \(destinationFolder)")
                                    .bscFont(size: 12)
                                    .foregroundColor(.bscTextSecondary)
                            }
                        }
                        .bscCardPadding()
                        .background(Color.bscBackground.opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
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

// MARK: - Enhanced Upload Button

struct EnhancedUploadButton: View {
    /// Called with the picked video; the caller runs the naming prompt + upload.
    let onVideoPicked: (PhotosPickerItem) -> Void

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
            
        } label: {
            HStack {
                Image(systemName: "plus")
                    .bscFont(size: 14, weight: .medium)
                Text("Upload Videos")
                    .bscFont(size: 14, weight: .medium)
            }
            .padding(.horizontal, BSCSpacing.lg)
            .padding(.vertical, BSCSpacing.sm)
            .frame(minHeight: BSCTouchTarget.standard)
            .background(Color.bscPrimaryFill)
            .foregroundColor(.bscOnPrimary)
            .clipShape(Capsule())
        }
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $selectedItems,
            maxSelectionCount: 1, // Limited to single video for now
            matching: .videos,
            preferredItemEncoding: .current // deliver original bytes; avoid slow re-encode on import
        )
        .onChange(of: selectedItems) { _, items in
            if !items.isEmpty, let item = items.first {
                onVideoPicked(item)
                selectedItems.removeAll()
            }
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

        EnhancedUploadButton { _ in }
    }
}