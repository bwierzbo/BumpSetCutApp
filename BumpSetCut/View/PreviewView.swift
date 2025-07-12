//
//  FixedCameraPreviewView.swift
//  BumpSetCut
//
//  iPhone-style camera UI with fixed controls
//

import SwiftUI
import AVFoundation

struct PreviewView: View {
    @EnvironmentObject var model: CameraModel
    @State private var isRecording: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var orientation = UIDeviceOrientation.portrait

    var body: some View {
        ZStack {
            // Camera preview
            CameraPreviewLayer(session: model.camera.captureSession)
                .ignoresSafeArea()
            
            // Fixed UI overlay
            CameraControlsOverlay(
                isRecording: $isRecording,
                orientation: $orientation,
                onCancel: { dismiss() },
                onRecord: {
                    if isRecording {
                        model.camera.stopRecordingVideo()
                    } else {
                        model.camera.startRecordingVideo()
                    }
                    isRecording.toggle()
                }
            )
        }
        .background(Color.black)
        .statusBarHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                orientation = UIDevice.current.orientation
            }
        }
    }
}

// Camera preview using UIViewRepresentable
struct CameraPreviewLayer: UIViewRepresentable {
    let session: AVCaptureSession
    
    class VideoPreviewView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }
        
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            return layer as! AVCaptureVideoPreviewLayer
        }
    }
    
    func makeUIView(context: Context) -> VideoPreviewView {
        let view = VideoPreviewView()
        view.backgroundColor = .black
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }
    
    func updateUIView(_ uiView: VideoPreviewView, context: Context) {
        // Preview layer handles rotation automatically
    }
}

// Fixed controls overlay
struct CameraControlsOverlay: View {
    @Binding var isRecording: Bool
    @Binding var orientation: UIDeviceOrientation
    let onCancel: () -> Void
    let onRecord: () -> Void
    
    var body: some View {
        VStack {
            Spacer()
            
            // Control bar - always at bottom of screen
            HStack(spacing: 60) {
                // Cancel button
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.white)
                        .rotationEffect(rotationAngle)
                }
                .opacity(isRecording ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: isRecording)
                
                // Record button
                Button(action: onRecord) {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 70, height: 70)
                        
                        if isRecording {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.red)
                                .frame(width: 35, height: 35)
                        } else {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 60, height: 60)
                        }
                    }
                }
                
                // Recording indicator
                Group {
                    if isRecording {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 12, height: 12)
                                .overlay(
                                    Circle()
                                        .fill(Color.red)
                                        .opacity(0.3)
                                        .scaleEffect(2.5)
                                        .opacity(isRecording ? 0 : 1)
                                        .animation(
                                            .easeInOut(duration: 1)
                                            .repeatForever(autoreverses: true),
                                            value: isRecording
                                        )
                                )
                            
                            Text("REC")
                                .foregroundColor(.white)
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .rotationEffect(rotationAngle)
                    } else {
                        Color.clear
                            .frame(width: 60, height: 30)
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.black.opacity(0.7),
                        Color.black.opacity(0.5),
                        Color.clear
                    ]),
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(height: 150)
                .ignoresSafeArea()
            )
        }
    }
    
    private var rotationAngle: Angle {
        switch orientation {
        case .landscapeLeft:
            return .degrees(90)
        case .landscapeRight:
            return .degrees(-90)
        case .portraitUpsideDown:
            return .degrees(180)
        default:
            return .degrees(0)
        }
    }
}

#Preview {
    @Previewable @StateObject var model = CameraModel()
    return PreviewView()
        .environmentObject(model)
}
