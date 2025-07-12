//
//  PreviewView.swift
//  BumpSetCut
//
//  Updated with fixed control position and no camera switching
//

import SwiftUI


struct PreviewView: View {
    @EnvironmentObject var model: CameraModel
    @State private var isRecording: Bool = false
    @Environment(\.dismiss) private var dismiss

    private let footerHeight: CGFloat = 110.0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Camera preview - fills entire screen
                ImageView(image: model.previewImage)
                    .ignoresSafeArea()
                
                // Control overlay - always at bottom in portrait orientation
                VStack {
                    Spacer()
                    
                    // This view maintains its own orientation
                    controlBar()
                        .frame(height: footerHeight)
                        .frame(maxWidth: geometry.size.width)
                        .background(.black.opacity(0.5))
                        .fixedSize()
                        .position(
                            x: geometry.size.width / 2,
                            y: geometry.size.height - footerHeight / 2
                        )
                }
            }
        }
        .background(Color.black)
        .statusBarHidden(true)
    }

    private func controlBar() -> some View {
        HStack(spacing: 60) {
            // Cancel button (only show when not recording)
            if !isRecording {
                Button(action: {
                    dismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.white)
                        .font(.system(size: 36))
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                // Placeholder to maintain spacing
                Color.clear
                    .frame(width: 36, height: 36)
            }

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
            if !isRecording {
                // Empty space to balance the layout
                Color.clear
                    .frame(width: 36, height: 36)
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
                .frame(width: 60, alignment: .leading)
            }
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 20)
    }
}

// Helper view modifier to prevent rotation of specific views
struct DeviceRotationViewModifier: ViewModifier {
    let action: (UIDeviceOrientation) -> Void
    
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                action(UIDevice.current.orientation)
            }
            .onAppear {
                action(UIDevice.current.orientation)
            }
    }
}

extension View {
    func onRotate(perform action: @escaping (UIDeviceOrientation) -> Void) -> some View {
        self.modifier(DeviceRotationViewModifier(action: action))
    }
}

#Preview {
    @Previewable @StateObject var model = CameraModel()
    return PreviewView()
        .environmentObject(model)
}
