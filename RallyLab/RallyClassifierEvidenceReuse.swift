//
//  RallyClassifierEvidenceReuse.swift
//  RallyLab
//
//  A new rally-classifier dataset made from the detector evidence a sealed one already
//  holds (owner, 2026-11-14: "Reuse verified detector evidence only through a supported
//  and tested operation"; "Never modify a sealed dataset"). Running the detector over
//  every recording takes hours; a change to the marks or to the audit changes no frame of
//  it. So `Options.reuseEvidenceFrom` names a dataset whose steps' times and feature
//  columns and whose decider clips are taken as they are — for each recording where that
//  is proven to be the same evidence a run now would be asked for — while every segment
//  index, label, weight and count is made now from the project's truth. Nothing of the
//  source's label columns is read into the new dataset, and the source is only read.
//
//  What a dataset stores decides what can be proven:
//
//   - It stores the steps (`t`, the rcf_v1 columns) and, per baseline variant, the
//     decider's clips. It does not store the frame evidence the decider replays, so a
//     variant the source lacks cannot be made from it: every variant asked for must be
//     in the source with the same config hash and settings, or the whole reuse is
//     refused. (rc-v1-20261112 has r0 and r0_prime; r0_no_net_rule needs a detector run.)
//   - Refused whole, before any video is read: a source that is not readable or not this
//     schema, whose detector, pipeline config hash, time base or feature schema is not
//     this build's, or that is the folder being written.
//   - Per recording — proven, or the detector runs on it as without the option, and the
//     report says what was not proven:
//       · the recording is in the source, and the steps and baseline bytes read hash to
//         what the source's manifest records;
//       · the file is the one the source's detector ran on, at the same camera config.
//         A dataset written since the manifest carries `evidence` states both. An
//         earlier one (rc-v1-20261108, rc-v1-20261112) does not, but its export's journal
//         (manifests/rally-classifier/<name>-journal.json) holds per recording a SHA-256
//         over the file's content fingerprint, its path, the card's fingerprint, the
//         marks hash, the cuts, the footage properties, the eligibility, the footage type
//         and the camera config (`inputKey`). Recomputed now with the marks hash the
//         source's manifest recorded, an equal key proves all of them are unchanged —
//         the marks alone may have moved. Anything else that changed since (a re-typed
//         recording, a new cut, footage at another path) leaves it unproven;
//       · its duration now is the source's, to the tick;
//       · every stored step reads back as the exporter writes one, as many as recorded.
//
//  The code that ran the detector is recorded, not required to be this build's: the new
//  manifest carries, per recording, `evidence.codeSha` (the commit that made it) and
//  `evidenceReusedFrom` with the source's name, manifest hash, digest and the proof.
//

import Foundation

extension RallyClassifierExporter {
    struct EvidenceReuse {
        /// Why a recording's evidence was not taken from the source.
        struct NotProven: Error, Equatable {
            var reason: String
        }

        let dataset: URL
        let name: String
        let manifestSha256: String
        let digest: String
        private let manifest: SourceManifest
        private let records: [String: SourceManifest.Record]
        /// The source export's journal entries, when the project still holds that journal and it is the source's.
        private let journal: [String: SourceJournal.Entry]?

        /// What of a sealed dataset's manifest a reuse reads; nothing of a recording's labels but the marks hash.
        private struct SourceManifest: Decodable {
            struct Record: Decodable {
                var recordingId: String
                var durationSec: Double
                var frameRateNominal: Double
                var aspect: Double
                var upright: Bool
                var net: NetDTO?
                var labelProvenance: ProvenanceDTO
                var evidence: EvidenceDTO?
                var stepsFile: String
                var stepsSha256: String
                var stepCount: Int
                var baselineFile: String
                var baselineSha256: String
            }
            var schemaVersion: String
            var generator: Generator
            var detector: Detector
            var pipelineConfigSha256: String
            var timescale: Int
            var featureSchema: FeatureSchema
            var baseline: BaselineBlock
            var recordings: [Record]
        }

        private struct SourceJournal: Decodable {
            struct Identity: Decodable {
                var dataset: String
                var pipelineConfigSha256: String
                var detector: Detector
            }
            struct Files: Decodable {
                var stepsSha256: String
                var baselineSha256: String
            }
            struct Entry: Decodable {
                var inputKey: String
                var record: Files
            }
            var identity: Identity
            var recordings: [String: Entry]
        }

        /// Opens `dataset` for reuse by an export of `variants` at this build's `detector` and config, or throws
        /// `Failure.reuseRefused` (see the file header). `writing`: the folders the export writes — never the source.
        static func open(_ dataset: URL, projectDir: URL, detector: Detector, pipelineConfigSha256: String, variants: [VariantDTO], writing: [URL]) throws -> EvidenceReuse {
            let dataset = dataset.standardizedFileURL
            let name = dataset.lastPathComponent
            func refuse(_ why: String) -> Failure { .reuseRefused("\(name): \(why)") }
            guard !writing.contains(where: { $0.standardizedFileURL.path == dataset.path }) else { throw refuse("it is the dataset being written") }
            let manifestURL = dataset.appendingPathComponent("dataset-manifest.json")
            guard let data = try? Data(contentsOf: manifestURL) else { throw refuse("no readable dataset-manifest.json in \(dataset.path)") }
            let manifest: SourceManifest
            do { manifest = try JSONDecoder().decode(SourceManifest.self, from: data) } catch { throw refuse("its manifest is not one this build reads (\(error))") }
            guard manifest.schemaVersion == schemaVersion else { throw refuse("schemaVersion \(manifest.schemaVersion), not \(schemaVersion)") }
            guard manifest.timescale == timescale else { throw refuse("timescale \(manifest.timescale), not \(timescale)") }
            guard manifest.featureSchema == FeatureSchema() else { throw refuse("its feature schema (\(manifest.featureSchema.version)) is not this build's \(featureVersion), column for column") }
            guard manifest.detector == detector else {
                throw refuse("its evidence is of detector \(manifest.detector.name)@\(manifest.detector.canonicalDigest), not \(detector.name)@\(detector.canonicalDigest)")
            }
            guard manifest.pipelineConfigSha256 == pipelineConfigSha256 else { throw refuse("its evidence was made at another pipeline config (\(manifest.pipelineConfigSha256.prefix(16))…, now \(pipelineConfigSha256.prefix(16))…)") }
            for v in variants where !manifest.baseline.variants.contains(v) {
                let held = manifest.baseline.variants.map(\.name).joined(separator: ", ")
                throw refuse("it holds no baseline variant \(v.name) at this config and these settings (it holds \(held)). A dataset stores the decider's clips, not the frame evidence they are replayed from, so a variant it lacks needs the detector: export without --reuse-evidence-from, or give --variants \(held.replacingOccurrences(of: ", ", with: ","))")
            }
            guard Set(manifest.recordings.map(\.recordingId)).count == manifest.recordings.count else { throw refuse("its manifest lists a recording twice") }
            guard let files = DatasetSplitManifest.canonicalFileHashes(ofDirectory: dataset) else { throw refuse("its files can't be read") }
            let digest = DatasetSplitManifest.canonicalDigest(lines: files.filter { $0.path != "dataset-manifest.json" }.map { ($0.path, $0.sha256) })

            // The source export's journal, for a source whose manifest states no content fingerprint: used only when
            // it is that dataset's (name, detector and config as the manifest has them).
            let journalURL = projectDir.appendingPathComponent("manifests/rally-classifier/\(name)-journal.json")
            let journal = (try? Data(contentsOf: journalURL)).flatMap { try? JSONDecoder().decode(SourceJournal.self, from: $0) }
                .flatMap { $0.identity.dataset == name && $0.identity.detector == manifest.detector && $0.identity.pipelineConfigSha256 == manifest.pipelineConfigSha256 ? $0.recordings : nil }
            return EvidenceReuse(dataset: dataset, name: name, manifestSha256: sha256Hex(data), digest: digest, manifest: manifest,
                                 records: Dictionary(manifest.recordings.map { ($0.recordingId, $0) }, uniquingKeysWith: { a, _ in a }), journal: journal)
        }

        /// The source's stored evidence for the planned recording `p`, when every proof holds; else what did not.
        /// Called for a planned recording only — one the plan found withheld by no identity.
        func measured(_ p: Planned, variants: [Variant], cameraConfigSha256: String, duration: DurationProbe) async -> Swift.Result<Measured, NotProven> {
            func no(_ why: String) -> Swift.Result<Measured, NotProven> { .failure(NotProven(reason: why)) }
            guard let record = records[p.video] else { return no("it is not in \(name)") }

            // The file and the camera config the source's detector ran on.
            let proof: String
            if let made = record.evidence {
                guard made.sourceFingerprint == p.fileFingerprint else { return no("its file is not the one \(name)'s detector ran on (content fingerprint)") }
                guard made.configSha256 == cameraConfigSha256 else { return no("\(name) ran it at another camera config") }
                proof = "manifest"
            } else {
                guard let entry = journal?[p.video] else {
                    return no("\(name) records no content fingerprint for it, and that export's journal (manifests/rally-classifier/\(name)-journal.json) is not here to prove the file")
                }
                guard entry.record.stepsSha256 == record.stepsSha256, entry.record.baselineSha256 == record.baselineSha256 else { return no("\(name)'s journal is not of the files its manifest records") }
                guard entry.inputKey == inputKey(p, marksSha256: record.labelProvenance.marksSha256) else {
                    return no("\(name) records no content fingerprint for it, and its journal's key does not match: the file, its path, the card's fingerprint, a cut, the footage properties, the eligibility or the camera config changed since")
                }
                proof = "journal"
            }
            let now: Double
            do { now = try await duration(p.session) } catch { return no("its duration can't be read now (\(error.localizedDescription))") }
            guard tick(now) == tick(record.durationSec) else { return no("its duration is \(now) s now, \(record.durationSec) s in \(name)") }

            // The bytes: read once, hashed as read.
            guard let stepsData = try? Data(contentsOf: dataset.appendingPathComponent(record.stepsFile)), sha256Hex(stepsData) == record.stepsSha256,
                  let baselineData = try? Data(contentsOf: dataset.appendingPathComponent(record.baselineFile)), sha256Hex(baselineData) == record.baselineSha256 else {
                return no("its steps or baseline file in \(name) does not hash to what that manifest records")
            }
            guard let steps = Self.steps(stepsData), steps.count == record.stepCount else { return no("its steps in \(name) do not read back as the exporter writes them") }
            guard let baseline = try? JSONDecoder().decode(BaselineFile.self, from: baselineData), baseline.recordingId == p.video else { return no("its baseline in \(name) can't be read") }
            var clips: [String: [BaselineClip]] = [:]
            for v in variants {
                guard let stored = baseline.variants[v.name] else { return no("its baseline in \(name) holds no \(v.name)") }
                clips[v.name] = stored
            }
            return .success(Measured(
                steps: steps, duration: record.durationSec, frameRate: record.frameRateNominal, aspect: record.aspect, upright: record.upright, net: record.net,
                baseline: clips,
                evidence: EvidenceDTO(sourceFingerprint: p.fileFingerprint, configSha256: cameraConfigSha256, codeSha: record.evidence?.codeSha ?? manifest.generator.codeSha),
                reusedFrom: ReusedFromDTO(dataset: name, manifestSha256: manifestSha256, digest: digest, stepsSha256: record.stepsSha256, baselineSha256: record.baselineSha256,
                                          detector: manifest.detector, pipelineConfigSha256: manifest.pipelineConfigSha256, featureVersion: manifest.featureSchema.version,
                                          sourceFingerprint: p.fileFingerprint, durationSec: record.durationSec, identityProof: proof)))
        }

        /// A steps file's times and feature columns, each as the text the exporter wrote
        /// (`{"t":…,"tick":…,"seg":…,"f":[…],"y":…,"w":…}`), or nil when a line is not that: the time must be a
        /// number that gives the line's own tick, later than the line before. `seg`, `y` and `w` are not read.
        private static func steps(_ data: Data) -> [(t: Double, time: String, features: String)]? {
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            var out: [(t: Double, time: String, features: String)] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.hasSuffix("\n") ? 1 : 0) {
                guard line.hasPrefix("{\"t\":"), let tickAt = line.range(of: ",\"tick\":"), let segAt = line.range(of: ",\"seg\":", range: tickAt.upperBound..<line.endIndex),
                      let open = line.range(of: ",\"f\":[", range: segAt.upperBound..<line.endIndex), let close = line.range(of: "],\"y\":", range: open.upperBound..<line.endIndex) else { return nil }
                let time = String(line[line.index(line.startIndex, offsetBy: 5)..<tickAt.lowerBound])
                guard let t = Double(time), t.isFinite, Int(line[tickAt.upperBound..<segAt.lowerBound]) == tick(t), out.last.map({ t > $0.t }) ?? true else { return nil }
                out.append((t, time, String(line[open.upperBound..<close.lowerBound])))
            }
            return out
        }
    }
}
