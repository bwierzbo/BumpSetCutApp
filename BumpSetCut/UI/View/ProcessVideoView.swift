//
//  ProcessVideoView.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/31/25.
//

import SwiftUI

struct ProcessVideoView: View {
    let videoURL: URL
    let onComplete: () -> ()
    @Environment(\.dismiss) private var dismiss
    @State private var processor = VideoProcessor()
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                createHeaderView()
                createProcessingContent()
                createActionButtons()
            }
            .padding(24)
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle("AI Processing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: createToolbar)
        }
    }
}

// MARK: - Header
private extension ProcessVideoView {
    func createHeaderView() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 48))
                .foregroundColor(.blue)
            
            Text("Rally Detection")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("AI will analyze your video to remove dead time and keep only active rallies")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Processing Content
private extension ProcessVideoView {
    func createProcessingContent() -> some View {
        VStack(spacing: 16) {
            if processor.isProcessing {
                createProcessingView()
            } else if processor.processedURL != nil {
                createCompletedView()
            } else {
                createReadyView()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
    
    func createProcessingView() -> some View {
        VStack(spacing: 12) {
            ProgressView(value: min(1.0, max(0.0, processor.progress)))
                .progressViewStyle(LinearProgressViewStyle())
            
            Text("Processing video... \(Int(min(100.0, max(0.0, processor.progress * 100))))%")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    func createCompletedView() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(.green)
            
            Text("Processing Complete!")
                .font(.headline)
                .foregroundColor(.primary)
            
            Text("Your video has been processed and saved to your library")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    func createReadyView() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "play.circle")
                .font(.system(size: 32))
                .foregroundColor(.blue)
            
            Text("Ready to Process")
                .font(.headline)
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Action Buttons
private extension ProcessVideoView {
    func createActionButtons() -> some View {
        VStack(spacing: 12) {
            if processor.isProcessing {
                // No buttons during processing
                EmptyView()
            } else if processor.processedURL != nil {
                createDoneButton()
            } else {
                VStack(spacing: 8) {
                    createStartButton()
                    createDebugButton()
                }
            }
        }
    }
    
    func createStartButton() -> some View {
        Button(action: startProcessing) {
            HStack {
                Image(systemName: "brain.head.profile")
                Text("Start AI Processing")
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
    }
    
    func createDebugButton() -> some View {
        Button(action: startDebugProcessing) {
            HStack {
                Image(systemName: "ladybug")
                Text("Debug AI Processing")
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.orange)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
    }
    
    func createDoneButton() -> some View {
        Button(action: { dismiss() }) {
            HStack {
                Image(systemName: "checkmark")
                Text("Done")
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.green)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
    }
}

// MARK: - Toolbar
private extension ProcessVideoView {
    func createToolbar() -> some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if !processor.isProcessing {
                Button("Cancel") {
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Actions
private extension ProcessVideoView {
    func startProcessing() {
        Task {
            do {
                _ = try await processor.processVideo(videoURL)
                onComplete() // Refresh the library
            } catch {
                print("Processing failed: \(error)")
            }
        }
    }
    
    func startDebugProcessing() {
        Task {
            do {
                _ = try await processor.processVideoDebug(videoURL)
                onComplete() // Refresh the library
            } catch {
                print("Debug processing failed: \(error)")
            }
        }
    }
}
