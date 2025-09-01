//
//  CameraService.swift
//  BumpSetCut
//
//  Created by Infrastructure Layer on 9/1/25.
//

import Foundation
import MijickCamera

/// Infrastructure layer wrapper for camera functionality
/// Isolates MijickCamera framework usage from the domain layer
final class CameraService {
    
    /// Configuration for camera capture
    struct CaptureConfig {
        let outputType: MCameraOutputType
        let orientation: AppDelegate.Type?
        
        static let defaultVideo = CaptureConfig(
            outputType: .video,
            orientation: AppDelegate.self
        )
    }
    
    /// Camera session state
    @Published var isSessionActive: Bool = false
    
    /// Configures MCamera with the provided configuration
    static func configureMCamera(
        config: CaptureConfig = .defaultVideo,
        onClose: @escaping () -> Void,
        onVideoCaptured: @escaping (URL, MCamera.Controller) -> Void
    ) -> some View {
        return MCamera()
            .lockCameraInPortraitOrientation(config.orientation)
            .setCameraOutputType(config.outputType)
            .setCloseMCameraAction(onClose)
            .onVideoCaptured(onVideoCaptured)
            .startSession()
    }
    
    /// Handles video capture and file system operations
    static func handleVideoCaptured(
        _ videoURL: URL,
        _ controller: MCamera.Controller,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        Task {
            do {
                let fileName = UUID().uuidString + ".mp4"
                let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let destinationURL = documentsURL.appendingPathComponent(fileName)
                
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: videoURL, to: destinationURL)
                
                controller.closeMCamera()
                completion(.success(destinationURL))
            } catch {
                print("Failed to move video: \(error)")
                completion(.failure(error))
            }
        }
    }
}

/// Camera-related errors
enum CameraServiceError: Error {
    case fileOperationFailed
    case sessionNotActive
}