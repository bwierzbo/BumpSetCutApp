//
//  FootageRemote.swift
//  RallyLab
//
//  Footage moved off this Mac to save disk. The desktop keeps a mirror of
//  ~/Movies/RallyLab/Projects (the same paths under one folder), reached
//  with scp. A video whose file is gone still plays here from its scrub
//  proxy (960 px, made while it was on the Mac or by hand); anything that
//  reads full-size frames — tracking, sampling — fetches the original back
//  first.
//

import SwiftUI

extension VideoSession {
    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }

    /// The footage file itself is here.
    var isOnMac: Bool { FileManager.default.fileExists(atPath: sourcePath) }

    /// What to play: the footage, else its scrub proxy; nil when neither is here.
    func playbackURL(in datasetRoot: URL) -> URL? {
        if isOnMac { return sourceURL }
        let proxy = ScrubProxy.url(for: sourceURL, in: datasetRoot)
        return FileManager.default.fileExists(atPath: proxy.path) ? proxy : nil
    }
}

enum FootageRemote {
    static let key = "RallyLab.footageRemote"
    static let defaultLocation = "bsc-desktop:D:/RallyLabFootage"

    /// `host:folder` holding the mirror of ~/Movies/RallyLab/Projects.
    static var location: String {
        get { UserDefaults.standard.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 } ?? defaultLocation }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The video's path in the mirror, or nil when it isn't under Projects.
    static func remotePath(for session: VideoSession, projectsRoot: URL) -> String? {
        let root = projectsRoot.standardizedFileURL.path + "/"
        let path = session.sourceURL.standardizedFileURL.path
        guard path.hasPrefix(root) else { return nil }
        return location + "/" + path.dropFirst(root.count)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Copy the video back to where the session expects it.
    static func fetch(_ session: VideoSession, projectsRoot: URL) async throws {
        guard let remote = remotePath(for: session, projectsRoot: projectsRoot) else {
            throw Failure(message: "\(session.sourcePath) isn't under \(projectsRoot.path), so it has no place in the mirror.")
        }
        let local = session.sourceURL
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = local.deletingLastPathComponent().appendingPathComponent("." + local.lastPathComponent + ".partial")
        let task = Task.detached(priority: .userInitiated) {
            let scp = Process()
            scp.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            scp.arguments = ["-q", "-o", "BatchMode=yes", remote, partial.path]
            let errors = Pipe()
            scp.standardError = errors
            scp.standardOutput = FileHandle.nullDevice
            try scp.run()
            scp.waitUntilExit()
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").filter { !$0.contains("post-quantum") && !$0.contains("pq.html") }
                .joined(separator: " ")
            guard scp.terminationStatus == 0 else {
                try? FileManager.default.removeItem(at: partial)
                throw Failure(message: text.isEmpty ? "scp exited with \(scp.terminationStatus)." : text)
            }
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.moveItem(at: partial, to: local)
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

/// The footage isn't on this Mac: say so, and fetch it from the mirror.
struct FootageMissingView: View {
    let session: VideoSession
    let datasetRoot: URL
    /// Why the original is needed here (the review copy wouldn't do).
    var reason = "This step reads full-size frames, so it needs the original."
    let onFetched: () -> Void

    @AppStorage(FootageRemote.key) private var location = FootageRemote.defaultLocation
    @State private var fetching = false
    @State private var error: String?

    private var remote: String? { FootageRemote.remotePath(for: session, projectsRoot: datasetRoot.deletingLastPathComponent()) }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.icloud").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("\(session.sourceURL.lastPathComponent) isn't on this Mac").font(.title3.bold())
            Text(reason + " Fetching copies it back from the desktop's footage folder; the file is a few GB.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Text("Mirror").foregroundStyle(.secondary)
                TextField("host:folder", text: $location).textFieldStyle(.roundedBorder).frame(width: 320)
            }
            .font(.callout)
            if let remote {
                Text(remote).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Button {
                fetch()
            } label: {
                if fetching { ProgressView().controlSize(.small).padding(.horizontal, 24) } else { Label("Fetch the original", systemImage: "arrow.down.circle") }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(fetching || remote == nil)
        }
        .frame(maxWidth: 560)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fetch() {
        fetching = true
        error = nil
        Task {
            do {
                try await FootageRemote.fetch(session, projectsRoot: datasetRoot.deletingLastPathComponent())
                onFetched()
            } catch {
                self.error = error.localizedDescription
            }
            fetching = false
        }
    }
}
