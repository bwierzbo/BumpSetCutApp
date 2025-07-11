//
//  PreviewView.swift
//  BumpSetCut
//
//  Updated with iPhone-style fixed control position
//

import SwiftUI


struct PreviewView: View {
    @EnvironmentObject var model: CameraModel
    @State private var isRecording: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var currentOrientation = UIDevice.current.orientation

    private let footerHeight: CGFloat = 110.0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Camera preview - fills entire screen
                ImageView(image: model.previewImage)
                    .ignoresSafeArea()
                
                // Control overlay - stays at physical bottom of device
                controlBarContainer(geometry: geometry)
            }
        }
        .background(Color.black)
        .statusBarHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                currentOrientation = UIDevice.current.orientation
            }
        }
    }
    
    @ViewBuilder
    private func controlBarContainer(geometry: GeometryProxy) -> some View {
        let isLandscape = currentOrientation.isLandscape
        let isLandscapeLeft = currentOrientation == .landscapeLeft
        let isLandscapeRight = currentOrientation == .landscapeRight
        let isUpsideDown = currentOrientation == .portraitUpsideDown
        
        controlBar()
            .frame(width: isLandscape ? footerHeight : geometry.size.width,
                   height: footerHeight)
            .background(.black.opacity(0.5))
            .rotationEffect(.degrees(rotationAngle(for: currentOrientation)))
            .position(
                x: controlBarX(for: currentOrientation, geometry: geometry),
                y: controlBarY(for: currentOrientation, geometry: geometry)
            )
    }
    
    private func rotationAngle(for orientation: UIDeviceOrientation) -> Double {
        switch orientation {
        case .landscapeLeft:
            return 90
        case .landscapeRight:
            return -90
        case .portraitUpsideDown:
            return 180
        default:
            return 0
        }
    }
    
    private func controlBarX(for orientation: UIDeviceOrientation, geometry: GeometryProxy) -> CGFloat {
        switch orientation {
        case .landscapeLeft:
            return geometry.size.width - footerHeight / 2
        case .landscapeRight:
            return footerHeight / 2
        case .portraitUpsideDown:
            return geometry.size.width / 2
        default: // portrait
            return geometry.size.width / 2
        }
    }
    
    private func controlBarY(for orientation: UIDeviceOrientation, geometry: GeometryProxy) -> CGFloat {
        switch orientation {
        case .landscapeLeft, .landscapeRight:
            return geometry.size.height / 2
        case .portraitUpsideDown:
            return footerHeight / 2
        default: // portrait
            return geometry.size.height - footerHeight / 2
        }
    }

    private func controlBar() -> some View {
        HStack(spacing: 50) {
            // Cancel button (only show when not recording)
            Group {
                if !isRecording {
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.white)
                            .font(.system(size: 30))
                    }
                } else {
                    // Placeholder to maintain spacing
                    Color.clear
                        .frame(width: 30, height: 30)
                }
            }
            .frame(width: 60)

            // Record button
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isRecording {
                        isRecording = false
                        model.camera.stopRecordingVideo()
                    } else {
                        isRecording = true
                        model.camera.startRecordingVideo()
                    }
                }
            } label: {
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

            // Recording indicator or spacer
            Group {
                if !isRecording {
                    // Empty space to balance the layout
                    Color.clear
                        .frame(width: 30, height: 30)
                } else {
                    // Recording indicator
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle()
                                    .fill(Color.red)
                                    .opacity(0.3)
                                    .scaleEffect(isRecording ? 2.5 : 1)
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
                }
            }
            .frame(width: 60)
        }
        .padding(.vertical, 20)
    }
}

#Preview {
    @Previewable @StateObject var model = CameraModel()
    return PreviewView()
        .environmentObject(model)
}
