import Foundation
import Supabase

// MARK: - Streaming Storage Upload

extension SupabaseAPIClient {

    /// Stream a file to a Supabase Storage bucket via chunked multipart (never
    /// loads the video into memory). Returns the bucket-relative object path
    /// (`{userId}/{uuid}.mp4`).
    nonisolated func streamUpload(fileURL: URL, bucket: String, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let userId = try await currentUserId()
        let fileName = "\(userId)/\(UUID().uuidString).mp4"

        // Get auth token for the storage API request
        let session = try await supabase.auth.session
        let accessToken = session.accessToken

        // Build the storage upload URL: {projectURL}/storage/v1/object/{bucket}/{fileName}
        let storageURL = SupabaseConfig.projectURL
            .appendingPathComponent("storage/v1/object/\(bucket)")
            .appendingPathComponent(fileName)

        // Write multipart form data to a temp file (streams video, never loads into memory)
        let boundary = "Boundary-\(UUID().uuidString)"
        let tempMultipartURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload_\(UUID().uuidString).tmp")

        try Self.writeMultipartFile(
            boundary: boundary,
            fileURL: fileURL,
            fileName: fileName,
            to: tempMultipartURL
        )

        defer { try? FileManager.default.removeItem(at: tempMultipartURL) }

        // Build the request
        var request = URLRequest(url: storageURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("false", forHTTPHeaderField: "x-upsert")

        // Upload from file (streams from disk, no memory pressure)
        let delegate = UploadProgressDelegate(onProgress: progress)
        let session2 = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session2.finishTasksAndInvalidate() }

        let (data, response) = try await session2.upload(for: request, fromFile: tempMultipartURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.serverError(statusCode: statusCode, message: "Storage upload failed: \(body)")
        }

        progress(1.0)
        return fileName
    }

    // MARK: - Multipart File Writer

    /// Writes multipart form data to a temp file, streaming the video to avoid memory pressure.
    nonisolated static func writeMultipartFile(
        boundary: String,
        fileURL: URL,
        fileName: String,
        to outputURL: URL
    ) throws {
        guard let outputStream = OutputStream(url: outputURL, append: false) else {
            throw APIError.invalidRequest("Cannot write to \(outputURL)")
        }
        outputStream.open()
        defer { outputStream.close() }

        // Write the full buffer or throw — OutputStream.write can return short
        // counts or -1 (e.g. temp volume full); ignoring that uploaded a
        // truncated multipart body that the server accepted as a valid video
        func writeAll(_ pointer: UnsafePointer<UInt8>, count: Int) throws {
            var written = 0
            while written < count {
                let result = outputStream.write(pointer + written, maxLength: count - written)
                guard result > 0 else {
                    throw outputStream.streamError
                        ?? APIError.invalidRequest("Failed writing multipart file to \(outputURL)")
                }
                written += result
            }
        }

        func writeString(_ string: String) throws {
            let data = Data(string.utf8)
            try data.withUnsafeBytes { buffer in
                try writeAll(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: data.count)
            }
        }

        // Multipart header for the file field
        try writeString("--\(boundary)\r\n")
        try writeString("Content-Disposition: form-data; name=\"\"; filename=\"\(fileName)\"\r\n")
        try writeString("Content-Type: video/mp4\r\n\r\n")

        // Stream video file in chunks (64KB at a time)
        guard let inputStream = InputStream(url: fileURL) else {
            throw APIError.invalidRequest("Cannot read file at \(fileURL)")
        }
        inputStream.open()
        defer { inputStream.close() }

        let bufferSize = 65_536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while inputStream.hasBytesAvailable {
            let bytesRead = inputStream.read(buffer, maxLength: bufferSize)
            if bytesRead > 0 {
                try writeAll(buffer, count: bytesRead)
            } else if bytesRead < 0 {
                // A mid-stream read failure must fail the upload, not truncate it
                throw inputStream.streamError
                    ?? APIError.invalidRequest("Failed reading video file at \(fileURL)")
            } else {
                break
            }
        }

        // Multipart footer
        try writeString("\r\n--\(boundary)--\r\n")
    }
}

// MARK: - Upload Progress Delegate

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @Sendable @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        onProgress(min(fraction, 0.95))  // Cap at 95% until server confirms
    }
}
