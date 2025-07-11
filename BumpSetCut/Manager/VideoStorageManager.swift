//
//  VideoStorageManager.swift
//  BumpSetCut
//
//  Manages internal video storage for the app
//

import Foundation
import AVFoundation
import UIKit

class VideoStorageManager: ObservableObject {
    static let shared = VideoStorageManager()
    
    @Published var savedVideos: [SavedVideo] = []
    
    private let documentsDirectory: URL
    private let videosDirectory: URL
    private let thumbnailsDirectory: URL
    
    init() {
        // Get documents directory
        documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        // Create videos directory
        videosDirectory = documentsDirectory.appendingPathComponent("Videos")
        thumbnailsDirectory = documentsDirectory.appendingPathComponent("Thumbnails")
        
        // Create directories if they don't exist
        try? FileManager.default.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        
        // Load existing videos
        loadSavedVideos()
    }
    
    // Save video from temporary location to app storage
    func saveVideo(from tempURL: URL, completion: @escaping (Result<SavedVideo, Error>) -> Void) {
        let videoId = UUID().uuidString
        let fileName = "\(videoId).mp4"
        let destinationURL = videosDirectory.appendingPathComponent(fileName)
        
        do {
            // Copy video to app storage
            try FileManager.default.copyItem(at: tempURL, to: destinationURL)
            
            // Generate thumbnail
            generateThumbnail(for: destinationURL, videoId: videoId) { thumbnailURL in
                let savedVideo = SavedVideo(
                    id: videoId,
                    fileName: fileName,
                    dateCreated: Date(),
                    thumbnailURL: thumbnailURL,
                    videoURL: destinationURL
                )
                
                DispatchQueue.main.async {
                    self.savedVideos.append(savedVideo)
                    self.savedVideos.sort { $0.dateCreated > $1.dateCreated }
                    completion(.success(savedVideo))
                }
            }
        } catch {
            completion(.failure(error))
        }
    }
    
    // Delete video from app storage
    func deleteVideo(_ video: SavedVideo) {
        // Remove video file
        try? FileManager.default.removeItem(at: video.videoURL)
        
        // Remove thumbnail if exists
        if let thumbnailURL = video.thumbnailURL {
            try? FileManager.default.removeItem(at: thumbnailURL)
        }
        
        // Remove from array
        savedVideos.removeAll { $0.id == video.id }
    }
    
    // Load all saved videos
    private func loadSavedVideos() {
        do {
            let videoFiles = try FileManager.default.contentsOfDirectory(
                at: videosDirectory,
                includingPropertiesForKeys: [.creationDateKey]
            )
            
            savedVideos = videoFiles.compactMap { url in
                guard url.pathExtension == "mp4" else { return nil }
                
                let videoId = url.deletingPathExtension().lastPathComponent
                let thumbnailURL = thumbnailsDirectory.appendingPathComponent("\(videoId).jpg")
                
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let creationDate = attributes?[.creationDate] as? Date ?? Date()
                
                return SavedVideo(
                    id: videoId,
                    fileName: url.lastPathComponent,
                    dateCreated: creationDate,
                    thumbnailURL: FileManager.default.fileExists(atPath: thumbnailURL.path) ? thumbnailURL : nil,
                    videoURL: url
                )
            }
            
            savedVideos.sort { $0.dateCreated > $1.dateCreated }
        } catch {
            print("Error loading saved videos: \(error)")
        }
    }
    
    // Generate thumbnail for video
    private func generateThumbnail(for videoURL: URL, videoId: String, completion: @escaping (URL?) -> Void) {
        let asset = AVAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        
        let time = CMTime(seconds: 1, preferredTimescale: 60)
        
        DispatchQueue.global().async {
            do {
                let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
                let uiImage = UIImage(cgImage: cgImage)
                
                if let jpegData = uiImage.jpegData(compressionQuality: 0.7) {
                    let thumbnailURL = self.thumbnailsDirectory.appendingPathComponent("\(videoId).jpg")
                    try jpegData.write(to: thumbnailURL)
                    completion(thumbnailURL)
                } else {
                    completion(nil)
                }
            } catch {
                print("Error generating thumbnail: \(error)")
                completion(nil)
            }
        }
    }
    
    // Export video to photo library (for later implementation)
    func exportToPhotoLibrary(_ video: SavedVideo) async {
        // This will use PhotoLibraryManager when you want to implement export functionality
        let photoManager = await PhotoLibraryManager()
        await photoManager.saveVideo(fileUrl: video.videoURL)
    }
}

// Model for saved video
struct SavedVideo: Identifiable {
    let id: String
    let fileName: String
    let dateCreated: Date
    let thumbnailURL: URL?
    let videoURL: URL
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: dateCreated)
    }
}
