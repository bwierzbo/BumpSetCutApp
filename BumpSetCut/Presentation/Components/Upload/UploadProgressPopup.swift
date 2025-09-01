//
//  UploadProgressPopup.swift
//  BumpSetCut
//
//  Created by Claude on 9/1/25.
//

import SwiftUI
import MijickPopups

struct UploadProgressPopup: BottomPopup {
    let uploadManager: UploadManager
    @State private var shouldDismissOnComplete = true
    
    func configurePopup(config: BottomPopupConfig) -> BottomPopupConfig {
        config
            .backgroundColor(Color(.systemBackground))
            .enableDragGesture(false)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text("Uploading Videos")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                
                if uploadManager.canCancel {
                    Button("Cancel All") {
                        uploadManager.cancelAllUploads()
                    }
                    .foregroundColor(.red)
                }
            }
            
            // Overall Progress
            if uploadManager.totalItems > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Overall Progress")
                            .font(.headline)
                        Spacer()
                        Text("\(uploadManager.completedItems)/\(uploadManager.totalItems)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    ProgressView(value: uploadManager.overallProgress)
                        .tint(.blue)
                }
            }
            
            // Individual Upload Items
            LazyVStack(spacing: 12) {
                ForEach(uploadManager.uploadItems) { item in
                    UploadItemProgressView(item: item, onCancel: {
                        uploadManager.cancelUpload(item.id)
                    })
                }
            }
            
            // Actions
            HStack(spacing: 12) {
                if uploadManager.isComplete {
                    Button("Done") {
                        Task {
                            await dismissLastPopup()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Button("Background") {
                        Task {
                            await dismissLastPopup()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding()
        .onChange(of: uploadManager.isComplete) { _, isComplete in
            if isComplete && shouldDismissOnComplete {
                Task {
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                    await dismissLastPopup()
                }
            }
        }
    }
}

struct UploadItemProgressView: View {
    let item: UploadItem
    let onCancel: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if let thumbnail = item.thumbnail {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Image(systemName: "video")
                                .frame(width: 40, height: 40)
                                .background(Color(.systemGray5))
                                .foregroundColor(.secondary)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            
                            Text(item.statusDescription)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if case .uploading(let progress, let transferRate, let eta) = item.status {
                        HStack {
                            ProgressView(value: progress)
                                .tint(.blue)
                            
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(Int(progress * 100))%")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                
                                if let rate = transferRate, let timeLeft = eta {
                                    Text("\(rate) • \(timeLeft)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(width: 60)
                        }
                    }
                }
                
                Spacer()
                
                // Status indicator and cancel button
                HStack(spacing: 8) {
                    switch item.status {
                    case .pending:
                        Image(systemName: "clock")
                            .foregroundColor(.secondary)
                    case .naming:
                        Image(systemName: "pencil")
                            .foregroundColor(.orange)
                    case .selectingFolder:
                        Image(systemName: "folder")
                            .foregroundColor(.orange)
                    case .uploading:
                        if item.canCancel {
                            Button(action: onCancel) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                            }
                        }
                    case .complete:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .cancelled:
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.secondary)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}