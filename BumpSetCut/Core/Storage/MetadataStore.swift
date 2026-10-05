//
//  MetadataStore.swift
//  BumpSetCut
//
//  Created for Metadata Video Processing - Task 002
//

import Foundation
import os

private let logger = Logger(subsystem: "BumpSetCut", category: "MetadataStore")

// MARK: - Metadata Storage Errors

enum MetadataStoreError: Error, LocalizedError {
    case directoryCreationFailed(path: String, underlying: Error)
    case fileWriteFailed(path: String, underlying: Error)
    case fileReadFailed(path: String, underlying: Error)
    case fileDeleteFailed(path: String, underlying: Error)
    case backupCreationFailed(path: String, underlying: Error)
    case metadataNotFound(videoId: UUID)
    case invalidJSON(path: String, underlying: Error)
    case corruptedMetadata(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let path, let underlying):
            return "Failed to create metadata directory at \(path): \(underlying.localizedDescription)"
        case .fileWriteFailed(let path, let underlying):
            return "Failed to write metadata file at \(path): \(underlying.localizedDescription)"
        case .fileReadFailed(let path, let underlying):
            return "Failed to read metadata file at \(path): \(underlying.localizedDescription)"
        case .fileDeleteFailed(let path, let underlying):
            return "Failed to delete metadata file at \(path): \(underlying.localizedDescription)"
        case .backupCreationFailed(let path, let underlying):
            return "Failed to create backup for metadata at \(path): \(underlying.localizedDescription)"
        case .metadataNotFound(let videoId):
            return "Metadata not found for video ID: \(videoId)"
        case .invalidJSON(let path, let underlying):
            return "Invalid JSON in metadata file at \(path): \(underlying.localizedDescription)"
        case .corruptedMetadata(let path, let reason):
            return "Corrupted metadata file at \(path): \(reason)"
        }
    }
}

// MARK: - MetadataStore Service

/// Per-video sidecar files in `ProcessedMetadata/`, all named `{videoId}…`:
/// rally metadata (+ its previous version as `.backup`), trims, review
/// selections, game scoring, flywheel evidence and the processing checkpoint.
///
/// Stateless apart from its location, so one instance is shared: `.shared`
/// for app code, or the one a `MediaStore` owns (same directory). The
/// directory resolves per call, so `StorageManager.storageDirectoryOverride`
/// set by a test is honored by `.shared` too.
@MainActor
final class MetadataStore {

    static let shared = MetadataStore()

    // MARK: - Properties

    private let baseDirectory: URL?
    private let fileManager = FileManager.default
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    var metadataDirectory: URL {
        (baseDirectory ?? StorageManager.getPersistentStorageDirectory())
            .appendingPathComponent("ProcessedMetadata", isDirectory: true)
    }

    // MARK: - Initialization

    /// - Parameter baseDirectory: library root; nil follows
    ///   `StorageManager.getPersistentStorageDirectory()`.
    init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory

        // Configure JSON encoder/decoder with consistent formatting
        self.jsonEncoder = JSONEncoder()
        self.jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.jsonEncoder.dateEncodingStrategy = .iso8601

        self.jsonDecoder = JSONDecoder()
        self.jsonDecoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Directory Management

    private func createMetadataDirectoryIfNeeded() throws {
        var isDirectory: ObjCBool = false
        let directoryExists = fileManager.fileExists(atPath: metadataDirectory.path, isDirectory: &isDirectory)

        if !directoryExists || !isDirectory.boolValue {
            do {
                try fileManager.createDirectory(
                    at: metadataDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                throw MetadataStoreError.directoryCreationFailed(
                    path: metadataDirectory.path,
                    underlying: error
                )
            }
        }
    }

    // MARK: - File Path Generation

    private func metadataURL(for videoId: UUID) -> URL {
        metadataDirectory.appendingPathComponent("\(videoId.uuidString).json")
    }

    /// The previous version of the metadata file, kept so a corrupt or missing
    /// main file can fall back to it.
    private func backupURL(for videoId: UUID) -> URL {
        metadataDirectory.appendingPathComponent("\(videoId.uuidString).json.backup")
    }

    private func stagedURL(for live: URL) -> URL {
        live.deletingLastPathComponent().appendingPathComponent(live.lastPathComponent + ".staged")
    }

    private static let transactionTempSuffix = ".txn"

    private func transactionTempURL(for live: URL) -> URL {
        live.deletingLastPathComponent().appendingPathComponent(live.lastPathComponent + Self.transactionTempSuffix)
    }

    // MARK: - Generic sidecar I/O

    /// Load a sidecar. Missing → nil. Present but unreadable/undecodable →
    /// quarantined (moved to `*.corrupt-<ts>`) and nil, so the caller's next
    /// save starts a fresh file instead of overwriting the only copy.
    private func loadSidecar<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try jsonDecoder.decode(T.self, from: data)
        } catch {
            logger.error("Unreadable sidecar \(url.lastPathComponent): \(String(describing: error))")
            StorageManager.quarantineCorruptFile(at: url)
            return nil
        }
    }

    private func writeSidecar<T: Encodable>(_ value: T, to url: URL, excludeFromBackup: Bool = false) throws {
        try createMetadataDirectoryIfNeeded()
        let data = try jsonEncoder.encode(value)
        try data.write(to: url, options: .atomic)
        if excludeFromBackup {
            StorageManager.excludeFromBackup(url)
        }
    }
}

// MARK: - Core CRUD Operations

extension MetadataStore {

    /// Save metadata atomically. The version being replaced is kept as
    /// `{id}.json.backup` — the fallback `loadMetadata` uses if the main file
    /// ever goes missing or fails to decode.
    func saveMetadata(_ metadata: ProcessingMetadata) throws {
        let metadataURL = metadataURL(for: metadata.videoId)

        do {
            try createMetadataDirectoryIfNeeded()
            let jsonData = try jsonEncoder.encode(metadata)
            try backUpCurrentMetadata(for: metadata.videoId)
            try jsonData.write(to: metadataURL, options: .atomic)
        } catch let error as MetadataStoreError {
            throw error
        } catch {
            throw MetadataStoreError.fileWriteFailed(path: metadataURL.path, underlying: error)
        }
    }

    /// Copy the current main file over the backup — but only when it decodes,
    /// so a corrupt main can never clobber a good backup.
    private func backUpCurrentMetadata(for videoId: UUID) throws {
        let source = metadataURL(for: videoId)
        guard fileManager.fileExists(atPath: source.path),
              (try? decodeValidated(at: source, videoId: videoId)) != nil else { return }
        let backup = backupURL(for: videoId)
        do {
            try? fileManager.removeItem(at: backup)
            try fileManager.copyItem(at: source, to: backup)
        } catch {
            throw MetadataStoreError.backupCreationFailed(path: backup.path, underlying: error)
        }
    }

    /// Load metadata. A missing or corrupt main file falls back to the backup
    /// (restoring it as the main file); a corrupt main file is quarantined
    /// either way so nothing overwrites it.
    func loadMetadata(for videoId: UUID) throws -> ProcessingMetadata {
        let metadataURL = metadataURL(for: videoId)
        let backupURL = backupURL(for: videoId)

        guard fileManager.fileExists(atPath: metadataURL.path) else {
            if let restored = restoreFromBackup(videoId: videoId) {
                return restored
            }
            throw MetadataStoreError.metadataNotFound(videoId: videoId)
        }

        do {
            return try decodeValidated(at: metadataURL, videoId: videoId)
        } catch let error as MetadataStoreError {
            switch error {
            case .invalidJSON, .corruptedMetadata:
                logger.error("Corrupt metadata for \(videoId): \(error.localizedDescription)")
                StorageManager.quarantineCorruptFile(at: metadataURL)
                if fileManager.fileExists(atPath: backupURL.path),
                   let restored = restoreFromBackup(videoId: videoId) {
                    return restored
                }
            default:
                break
            }
            throw error
        }
    }

    private func restoreFromBackup(videoId: UUID) -> ProcessingMetadata? {
        let backupURL = backupURL(for: videoId)
        guard fileManager.fileExists(atPath: backupURL.path),
              let restored = try? decodeValidated(at: backupURL, videoId: videoId) else { return nil }
        do {
            try fileManager.copyItem(at: backupURL, to: metadataURL(for: videoId))
            logger.warning("Restored metadata for \(videoId) from its backup")
        } catch {
            logger.error("Couldn't reinstate metadata backup for \(videoId): \(error.localizedDescription)")
        }
        return restored
    }

    private func decodeValidated(at url: URL, videoId: UUID) throws -> ProcessingMetadata {
        let jsonData: Data
        do {
            jsonData = try Data(contentsOf: url)
        } catch {
            throw MetadataStoreError.fileReadFailed(path: url.path, underlying: error)
        }

        guard !jsonData.isEmpty else {
            throw MetadataStoreError.corruptedMetadata(path: url.path, reason: "File is empty")
        }

        let metadata: ProcessingMetadata
        do {
            metadata = try jsonDecoder.decode(ProcessingMetadata.self, from: jsonData)
        } catch {
            throw MetadataStoreError.invalidJSON(path: url.path, underlying: error)
        }

        guard metadata.videoId == videoId else {
            throw MetadataStoreError.corruptedMetadata(
                path: url.path,
                reason: "Video ID mismatch: expected \(videoId), found \(metadata.videoId)"
            )
        }
        return metadata
    }

    /// Delete metadata file and its backup
    func deleteMetadata(for videoId: UUID) throws {
        let metadataURL = metadataURL(for: videoId)
        let backupURL = backupURL(for: videoId)

        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw MetadataStoreError.metadataNotFound(videoId: videoId)
        }

        do {
            try fileManager.removeItem(at: metadataURL)
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
        } catch {
            throw MetadataStoreError.fileDeleteFailed(path: metadataURL.path, underlying: error)
        }
    }

    /// Check if metadata exists for a video
    func metadataExists(for videoId: UUID) -> Bool {
        fileManager.fileExists(atPath: metadataURL(for: videoId).path)
    }
}

// MARK: - Staged replacement (Free Up Space)

extension MetadataStore {

    /// Write remapped metadata/evidence next to the live files without touching
    /// them. `commitStagedSidecars` swaps them in once the trimmed video is
    /// installed; until then the live files still describe the live video.
    func stageMetadata(_ metadata: ProcessingMetadata, evidence: [StoredFrameEvidence]?) throws {
        try writeSidecar(metadata, to: stagedURL(for: metadataURL(for: metadata.videoId)))
        if let evidence {
            try writeSidecar(evidence, to: stagedURL(for: evidenceURL(for: metadata.videoId)), excludeFromBackup: true)
        }
    }

    /// Install staged files over the live ones (the metadata's current version
    /// becomes the backup first).
    func commitStagedSidecars(for videoId: UUID) throws {
        let stagedMetadata = stagedURL(for: metadataURL(for: videoId))
        if fileManager.fileExists(atPath: stagedMetadata.path) {
            try backUpCurrentMetadata(for: videoId)
            try install(stagedMetadata, at: metadataURL(for: videoId))
        }
        let evidence = evidenceURL(for: videoId)
        let stagedEvidence = stagedURL(for: evidence)
        if fileManager.fileExists(atPath: stagedEvidence.path) {
            try install(stagedEvidence, at: evidence)
            StorageManager.excludeFromBackup(evidence)
        }
    }

    func discardStagedSidecars(for videoId: UUID) {
        try? fileManager.removeItem(at: stagedURL(for: metadataURL(for: videoId)))
        try? fileManager.removeItem(at: stagedURL(for: evidenceURL(for: videoId)))
    }

    /// The staged metadata of an interrupted replacement, if any.
    func stagedMetadata(for videoId: UUID) -> ProcessingMetadata? {
        let url = stagedURL(for: metadataURL(for: videoId))
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? decodeValidated(at: url, videoId: videoId)
    }

    /// Videos with staged files left behind by an interrupted replacement.
    func videoIdsWithStagedSidecars() -> Set<UUID> {
        Set(sidecarFileNames()
            .filter { $0.hasSuffix(".json.staged") }
            .compactMap(Self.videoId(fromSidecarName:)))
    }

    private func install(_ staged: URL, at live: URL) throws {
        if fileManager.fileExists(atPath: live.path) {
            _ = try fileManager.replaceItemAt(live, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: live)
        }
    }
}

// MARK: - Multi-file save (timeline edits)

extension MetadataStore {

    /// Write a timeline edit's files as one best-effort transaction: encode
    /// everything, write every temp file, and only then rename them into
    /// place. Any failure before the renames leaves all live files untouched;
    /// the renames themselves are individually atomic and back-to-back.
    /// `scoring` nil = leave the scoring file alone.
    func saveTimelineEdit(metadata: ProcessingMetadata,
                          trims: [Int: RallyTrimAdjustment],
                          selections: RallyReviewSelections,
                          scoring: GameScoring?) throws {
        let videoId = metadata.videoId
        try createMetadataDirectoryIfNeeded()

        var writes: [(live: URL, data: Data)] = [
            (metadataURL(for: videoId), try jsonEncoder.encode(metadata)),
            (trimURL(for: videoId), try jsonEncoder.encode(
                Dictionary(uniqueKeysWithValues: trims.map { (String($0.key), $0.value) }))),
            (reviewSelectionsURL(for: videoId), try jsonEncoder.encode(selections)),
        ]
        if let scoring {
            writes.append((gameScoringURL(for: videoId), try jsonEncoder.encode(scoring)))
        }

        // Not ".staged": those belong to Free Up Space's crash recovery.
        let temps = writes.map { transactionTempURL(for: $0.live) }
        do {
            for (write, temp) in zip(writes, temps) {
                try write.data.write(to: temp, options: .atomic)
            }
            try backUpCurrentMetadata(for: videoId)
        } catch {
            temps.forEach { try? fileManager.removeItem(at: $0) }
            throw error
        }

        for (write, temp) in zip(writes, temps) {
            try install(temp, at: write.live)
        }
    }

    /// Temp files of a multi-file save interrupted before its renames — the
    /// live files are still the previous, consistent set, so just drop them.
    func removeIncompleteTransactionFiles() {
        for name in sidecarFileNames() where name.hasSuffix(Self.transactionTempSuffix) {
            try? fileManager.removeItem(at: metadataDirectory.appendingPathComponent(name))
        }
    }
}

// MARK: - Query Operations

extension MetadataStore {

    /// Get all video IDs that have metadata
    func getAllMetadataVideoIds() -> [UUID] {
        sidecarFileNames().compactMap { filename in
            // Only main metadata files: "{uuid}.json"
            guard filename.hasSuffix(".json"), filename.count == 41 else { return nil }
            return UUID(uuidString: String(filename.dropLast(5)))
        }
    }

    /// Get metadata file size for a video
    func getMetadataFileSize(for videoId: UUID) -> Int64? {
        let metadataURL = metadataURL(for: videoId)
        guard let attributes = try? fileManager.attributesOfItem(atPath: metadataURL.path) else {
            return nil
        }
        return attributes[.size] as? Int64
    }

    /// File names (not directories) directly inside the metadata directory.
    private func sidecarFileNames() -> [String] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: metadataDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            .map(\.lastPathComponent)
    }

    /// Every sidecar name starts with the owning video's UUID.
    private static func videoId(fromSidecarName name: String) -> UUID? {
        UUID(uuidString: String(name.prefix(36)))
    }
}

// MARK: - Maintenance Operations

extension MetadataStore {

    /// Delete every sidecar (all kinds, including backups, staged and
    /// quarantined copies) whose video isn't in `validVideoIds`. Returns the
    /// number of files removed. Only call with a trustworthy id set — an
    /// empty or partial manifest would wipe live metadata.
    @discardableResult
    func sweepOrphanedSidecars(keeping validVideoIds: Set<UUID>) -> Int {
        var removed = 0
        for name in sidecarFileNames() {
            guard let videoId = Self.videoId(fromSidecarName: name),
                  !validVideoIds.contains(videoId) else { continue }
            do {
                try fileManager.removeItem(at: metadataDirectory.appendingPathComponent(name))
                removed += 1
            } catch {
                logger.error("Couldn't remove orphaned sidecar \(name): \(error.localizedDescription)")
            }
        }
        if removed > 0 {
            logger.info("Removed \(removed) orphaned sidecar file(s)")
        }
        return removed
    }
}

// MARK: - Trim Adjustment Persistence

extension MetadataStore {

    private func trimURL(for videoId: UUID) -> URL {
        metadataDirectory.appendingPathComponent("\(videoId.uuidString)_trims.json")
    }

    /// Save per-rally trim adjustments for a video.
    /// Keys are rally index strings ("0", "1", ...) mapping to RallyTrimAdjustment.
    func saveTrimAdjustments(_ adjustments: [Int: RallyTrimAdjustment], for videoId: UUID) throws {
        let stringKeyed = Dictionary(uniqueKeysWithValues: adjustments.map { (String($0.key), $0.value) })
        try writeSidecar(stringKeyed, to: trimURL(for: videoId))
    }

    /// Load previously saved trim adjustments for a video. Returns empty dict if none saved.
    func loadTrimAdjustments(for videoId: UUID) -> [Int: RallyTrimAdjustment] {
        guard let stringKeyed = loadSidecar([String: RallyTrimAdjustment].self, at: trimURL(for: videoId)) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: stringKeyed.compactMap { key, value in
            guard let intKey = Int(key) else { return nil }
            return (intKey, value)
        })
    }
}

// MARK: - Review Selections Persistence

extension MetadataStore {

    private func reviewSelectionsURL(for videoId: UUID) -> URL {
        metadataDirectory.appendingPathComponent("\(videoId.uuidString)_selections.json")
    }

    /// Save rally review selections (saved/removed sets) for a video.
    func saveReviewSelections(_ selections: RallyReviewSelections, for videoId: UUID) throws {
        try writeSidecar(selections, to: reviewSelectionsURL(for: videoId))
    }

    /// Load previously saved review selections for a video. Returns empty selections if none saved.
    func loadReviewSelections(for videoId: UUID) -> RallyReviewSelections {
        loadSidecar(RallyReviewSelections.self, at: reviewSelectionsURL(for: videoId)) ?? RallyReviewSelections()
    }
}

// MARK: - Processing Checkpoint Persistence

extension MetadataStore {

    /// Stable file location for a video's in-flight processing checkpoint.
    /// The (non-main) processing loop reads/writes it directly so multi-MB
    /// encodes never hop onto the main actor — see ProcessingCheckpoint.
    func processingCheckpointFileURL(for videoId: UUID) -> URL {
        metadataDirectory.appendingPathComponent("\(videoId.uuidString)_checkpoint.json")
    }
}

// MARK: - Game Scoring Persistence

extension MetadataStore {

    private func gameScoringURL(for videoId: UUID) -> URL {
        metadataDirectory.appendingPathComponent("\(videoId.uuidString)_scoring.json")
    }

    /// Save manual game scoring (teams, per-rally point winners, set breaks).
    func saveGameScoring(_ scoring: GameScoring, for videoId: UUID) throws {
        try writeSidecar(scoring, to: gameScoringURL(for: videoId))
    }

    /// Load game scoring for a video. Nil = never set up (drives team setup).
    func loadGameScoring(for videoId: UUID) -> GameScoring? {
        loadSidecar(GameScoring.self, at: gameScoringURL(for: videoId))
    }
}

// MARK: - Frame Evidence Persistence (Data Flywheel)

extension MetadataStore {

    private func evidenceURL(for videoId: UUID) -> URL {
        metadataDirectory.appendingPathComponent("\(videoId.uuidString)_evidence.json")
    }

    /// Persist the detector's per-frame evidence for a processed video so the
    /// data flywheel can build training contributions later (including at review
    /// time, in a different session). Only written for opted-in users; scope it
    /// to interesting frames before calling to keep the file small.
    func saveFrameEvidence(_ evidence: [StoredFrameEvidence], for videoId: UUID) throws {
        try writeSidecar(evidence, to: evidenceURL(for: videoId), excludeFromBackup: true)
    }

    /// Load persisted frame evidence for a video. Returns empty if none saved
    /// (e.g. the video was processed before opt-in).
    func loadFrameEvidence(for videoId: UUID) -> [StoredFrameEvidence] {
        loadSidecar([StoredFrameEvidence].self, at: evidenceURL(for: videoId)) ?? []
    }
}

// MARK: - Bulk Sidecar Cleanup

extension MetadataStore {
    /// Remove every sidecar owned by a video — all kinds, including backups,
    /// staged and quarantined copies. Missing files are fine; call when the
    /// video itself is deleted so nothing leaks.
    func deleteAllSidecars(for videoId: UUID) {
        let prefix = videoId.uuidString
        for name in sidecarFileNames() where name.hasPrefix(prefix) {
            try? fileManager.removeItem(at: metadataDirectory.appendingPathComponent(name))
        }
    }

    /// Before reprocessing: drop the rally-index-keyed and run-specific
    /// sidecars (trims, selections, scoring, evidence, checkpoint, staged
    /// files) but KEEP `{id}.json` — the new run reads it to carry manual
    /// rallies through, then overwrites it when it finishes.
    func deleteSidecarsForReprocess(videoId: UUID) {
        let urls = [
            trimURL(for: videoId),
            reviewSelectionsURL(for: videoId),
            gameScoringURL(for: videoId),
            evidenceURL(for: videoId),
            processingCheckpointFileURL(for: videoId),
        ]
        for url in urls {
            try? fileManager.removeItem(at: url)
        }
        discardStagedSidecars(for: videoId)
    }
}
