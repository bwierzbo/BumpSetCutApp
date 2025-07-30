

//
//  CustomCameraScreen.swift
//  BumpSetCut
//
//  Apple-style camera interface for video recording only
//

import SwiftUI
import MijickCamera


struct CustomCameraScreen: MCameraScreen {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var cameraManager: CameraManager
    let namespace: Namespace.ID
    let closeMCameraAction: () -> ()
    
    @State private var isRecordingVideo = false
    @State private var recordingStartTime: Date?
    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?
    
    init(cameraManager: CameraManager, namespace: Namespace.ID, closeMCameraAction: @escaping () -> ()) {
        self.cameraManager = cameraManager
        self.namespace = namespace
        self.closeMCameraAction = closeMCameraAction
        
    }
    
    var body: some View {
        ZStack {
            // Camera preview
            createCameraOutputView()
                .ignoresSafeArea()
            
            // Overlay controls
            VStack {
                // Top bar with recording time
                if isRecordingVideo {
                    createRecordingHeader()
                }
                
                Spacer()
                
                // Bottom controls
                createBottomControls()
            }
        }
        .background(Color.black)
        .statusBarHidden(true)
    }
    
    // MARK: - Recording Header
    private func createRecordingHeader() -> some View {
        VStack {
            HStack {
                // Recording indicator
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .fill(Color.red)
                                .opacity(0.3)
                                .scaleEffect(2.5)
                                .animation(
                                    .easeInOut(duration: 1)
                                    .repeatForever(autoreverses: true),
                                    value: isRecordingVideo
                                )
                        )
                    
                    Text(timeString(from: elapsedTime))
                        .font(.system(size: 17, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.6))
                .cornerRadius(20)
                
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 50)
            
            Spacer()
        }
    }
    
    // MARK: - Bottom Controls
    private func createBottomControls() -> some View {
        VStack(spacing: 0) {
            // Gradient fade
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black.opacity(0),
                    Color.black.opacity(0.3),
                    Color.black.opacity(0.6)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 100)
            
            // Control buttons
            HStack(spacing: 0) {
                // Cancel/Close button (left side)
                Button(action: {
                    if !isRecordingVideo {
                        dismiss()
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 60, height: 60)
                        .contentShape(Circle())
                }
                .frame(maxWidth: .infinity)
                .opacity(isRecordingVideo ? 0 : 1)       // hide when recording
                .disabled(isRecordingVideo)              // prevent taps when hidden
                .animation(.easeInOut(duration: 0.2), value: isRecordingVideo)

                
                // Record button (center)
                Button(action: {
                    if isRecordingVideo {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                }) {
                    ZStack {
                        // Outer ring
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 6)
                            .frame(width: 70, height: 70)
                        
                        // Inner circle/square
                        if isRecordingVideo {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.red)
                                .frame(width: 35, height: 35)
                                .animation(.easeInOut(duration: 0.2), value: isRecordingVideo)
                        } else {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 62, height: 62)
                                .animation(.easeInOut(duration: 0.2), value: isRecordingVideo)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                
                // Empty space (right side) for balance
                Color.clear
                    .frame(width: 60, height: 60)
                    .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 30)
            .background(Color.black.opacity(0.6))
        }
    }
    
    // MARK: - Recording Functions
    private func startRecording() {
        captureOutput()
        isRecordingVideo = true
        recordingStartTime = Date()
        
        // Start timer to update elapsed time
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if let startTime = recordingStartTime {
                elapsedTime = Date().timeIntervalSince(startTime)
            }
        }
    }
    
    private func stopRecording() {
        captureOutput()
        isRecordingVideo = false
        recordingStartTime = nil
        elapsedTime = 0
        timer?.invalidate()
        timer = nil
    }
    
    // MARK: - Helper Functions
    private func timeString(from timeInterval: TimeInterval) -> String {
        let minutes = Int(timeInterval) / 60
        let seconds = Int(timeInterval) % 60
        let milliseconds = Int((timeInterval.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%01d", minutes, seconds, milliseconds)
    }
}

// MARK: - Camera Configuration Extension
extension CustomCameraScreen {
    func configureCameraForVideo() {
        Task {
            do {
                // Set to back camera
                try await setCameraPosition(.back)
                
                // Set output type to video
                setOutputType(.video)
                                
                // Set high quality video
                setResolution(.high)
                
                // Disable flash for video
                setFlashMode(.off)
                
                // Hide grid
                setGridVisibility(false)
                
                // Set appropriate frame rate for video
                try? setFrameRate(60)
                
            } catch {
                print("Error configuring camera: \(error)")
            }
        }
    }
}
