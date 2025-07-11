//
//  PreviewView.swift
//  BasicAVCamera
//
//  Created by Itsuki on 2024/05/19.
//

// Simplified CameraView for Video Only with Cancel Button
import SwiftUI


struct PreviewView: View {
    @EnvironmentObject var model: CameraModel
    @State private var isRecording: Bool = false
    @Environment(\.dismiss) private var dismiss

    private let footerHeight: CGFloat = 110.0

    var body: some View {
        ImageView(image: model.previewImage)
            .padding(.bottom, footerHeight)
            .overlay(alignment: .bottom) {
                controlBar()
                    .frame(height: footerHeight)
                    .background(.gray.opacity(0.4))
            }
            .ignoresSafeArea(.all, edges: .top)
            .background(Color.black)
    }

    private func controlBar() -> some View {
        GeometryReader { geometry in
            HStack {
                if !isRecording {
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.white)
                            .font(.system(size: 32))
                    }
                }

                Spacer()

                Button {
                    if isRecording {
                        isRecording = false
                        model.camera.stopRecordingVideo()
                    } else {
                        isRecording = true
                        model.camera.startRecordingVideo()
                    }
                } label: {
                    Image(systemName: "record.circle")
                        .symbolEffect(.pulse, isActive: isRecording)
                        .foregroundStyle(isRecording ? Color.red : Color.white)
                        .font(.system(size: 50))
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.vertical, 24)
        .padding(.bottom, 8)
        .padding(.horizontal, 32)
    }
}

#Preview {
    @Previewable @StateObject var model = CameraModel()
    return PreviewView()
        .environmentObject(model)
}
