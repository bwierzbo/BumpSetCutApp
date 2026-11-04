//
//  FootageTypeSheet.swift
//  RallyLab
//
//  The footage-type confirmation step (FootageTypeConfirmation): after
//  "That's every rally", and whenever the type is to be changed. What the
//  exclusions are, whether the pass is complete and the timeline verified,
//  what the record says, and what each model may use once the choice is
//  confirmed — the policy's verdict, shown, never overridden. The person
//  confirms the type; nothing here infers it.
//

import SwiftUI

struct FootageTypeSheet: View {
    let recording: FootageTypeConfirmation.Recording
    /// The opening the recording was marked under: the record goes into that project, only while it holds.
    let opening: ProjectsModel.Opening
    let projects: ProjectsModel
    /// The video's length as the player knows it, for the cut seconds when there is no Stage 1 record.
    let duration: Double?
    /// Right after the pass (the completion is already recorded), or opened to change the type.
    let afterPass: Bool
    let onDone: () -> Void

    @State private var facts: FootageTypeConfirmation.Facts?
    @State private var admission: Result<SourceRegistry.Admission?, Error>?
    @State private var choice: FootageProperties.RecordingType = .unknown
    @State private var problem: String?

    private static let types: [FootageProperties.RecordingType] = [.continuous, .edited, .unknown]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Footage type · \(recording.name)").font(.title3.weight(.semibold))
            if afterPass {
                Text("Every visible rally is marked, and that is recorded. What the recording is, is a separate fact: say it here, or later from \"Footage type…\" on the marking screen.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let facts {
                factsView(facts)
                Divider()
                Picker("Footage type", selection: $choice) {
                    ForEach(Self.types, id: \.self) { type in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(type))
                            Text(Self.detail(type)).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(type)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(facts.recordProblem != nil)
                Divider()
                eligibility(facts)
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the recording's records…").foregroundStyle(.secondary) }
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(afterPass ? "Not now" : "Cancel") { onDone() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(afterPass ? "Confirm and continue" : "Confirm") { confirm() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(facts == nil || facts?.recordProblem != nil)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task { await load() }
    }

    // MARK: - The facts

    private func factsView(_ f: FootageTypeConfirmation.Facts) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                Text("Excluded intervals").foregroundStyle(.secondary)
                if f.cuts.isEmpty {
                    Text("none")
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(f.cuts.count) · \(Self.seconds(f.cutSeconds)) not footage")
                        Text(f.cuts.map { "\(clockText($0.start)) – \(clockText($0.end))" }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            GridRow {
                Text("Rally pass").foregroundStyle(.secondary)
                Text(f.ralliesMarked ? "every visible rally marked" : "not finished")
            }
            GridRow {
                Text("Timeline coverage").foregroundStyle(.secondary)
                Text(Self.coverage(f)).fixedSize(horizontal: false, vertical: true)
            }
            GridRow {
                Text("On file").foregroundStyle(.secondary)
                Text(Self.onFile(f)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }

    private static func coverage(_ f: FootageTypeConfirmation.Facts) -> String {
        if let problem = f.stage1Problem { return "Stage 1 record not usable: \(problem)" }
        guard let c = f.verifiedCoverage else { return "not verified (no Stage 1 record) — unmarked time is not verified dead time" }
        let pct = "\(Int((c * 100).rounded(.down))) %"
        return f.stage1Complete ? "verified by the Stage 1 review (\(pct) of the footage)" : "\(pct) of the footage reviewed in Stage 1, not finished"
    }

    private static func onFile(_ f: FootageTypeConfirmation.Facts) -> String {
        if let problem = f.recordProblem { return "⚠︎ the footage-properties record can't be read — nothing is confirmed over it: \(problem)" }
        if let other = f.recordOfAnotherFile { return "a record for another file (\(other)) — confirming starts a record of this one" }
        guard let r = f.record else { return "no record — unknown, not yet verified" }
        var line = title(r.recordingType)
        if let by = r.recordingTypeBy, let at = r.recordingTypeAt { line += " · confirmed by \(by), \(at)" }
        let spans = r.activeSpans.count
        if spans > 0 { line += " · \(spans) span\(spans == 1 ? "" : "s") on file" }
        return line
    }

    // MARK: - Eligibility

    @ViewBuilder
    private func eligibility(_ f: FootageTypeConfirmation.Facts) -> some View {
        switch admission {
        case nil:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Assessing eligibility…").foregroundStyle(.secondary) }
        case .success(nil):
            Text("Training eligibility: the recording is not in the project's source index.").font(.callout).foregroundStyle(.secondary)
        case .failure(let error):
            Text("Training eligibility not assessed: \(error.localizedDescription)").font(.callout).foregroundStyle(.secondary)
        case .success(let a?):
            let p = FootageTypeConfirmation.preview(choice, facts: f, admission: a, at: EventReview.stamp(Date()))
            VStack(alignment: .leading, spacing: 6) {
                Text("Training eligibility once confirmed as \(Self.title(choice).lowercased())").font(.callout.weight(.semibold))
                ForEach(TrainingEligibility.Model.allCases, id: \.self) { model in
                    verdict(Self.name(model), p[model])
                }
                verdict("Unmarked time as non-rally negatives", p.fullVideoNegatives)
            }
        }
    }

    private func verdict(_ name: String, _ v: TrainingEligibility.Verdict) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(name).font(.callout).foregroundStyle(.secondary).frame(width: 230, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.level(v.level)).font(.callout.weight(.medium))
                if !v.reasons.isEmpty {
                    Text(v.reasons.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Doing

    private func load() async {
        let fingerprint = FootageTypeConfirmation.sourceFingerprint(of: recording.name, in: projects.project)
        let root = opening.root, recording = recording, duration = duration
        let (f, a) = await Task.detached(priority: .userInitiated) { () -> (FootageTypeConfirmation.Facts, Result<SourceRegistry.Admission?, Error>) in
            let f = FootageTypeConfirmation.facts(recording, sourceFingerprint: fingerprint, duration: duration, in: root)
            let a = Result { try SourceRegistry.load(root: root).sources.first { $0.video == recording.name }?.admission }
            return (f, a)
        }.value
        facts = f
        admission = a
        choice = f.recordingType
    }

    private func confirm() {
        do {
            try FootageTypeConfirmation.confirm(choice, video: recording.name, under: opening, projects: projects)
            onDone()
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: - Words

    static func title(_ type: FootageProperties.RecordingType) -> String {
        switch type {
        case .continuous: return "Continuous recording"
        case .edited: return "Edited recording"
        case .unknown: return "Unknown"
        }
    }

    private static func detail(_ type: FootageProperties.RecordingType) -> String {
        switch type {
        case .continuous: return "No known timeline editing: the footage runs as it was recorded (cuts you marked for a partial rally don't change that)."
        case .edited: return "Contains removed time, replays, artificial speed changes or other edits."
        case .unknown: return "Not yet verified: no model treats it as footage until someone says what it is."
        }
    }

    private static func name(_ model: TrainingEligibility.Model) -> String {
        switch model {
        case .rallyClassifier: return "Rally classifier"
        case .ballDetector: return "L2 ball detector"
        case .netDetector: return "Net detector"
        }
    }

    private static func level(_ level: TrainingEligibility.Level) -> String {
        level == .notAssessed ? "not assessed" : level.rawValue
    }

    private static func seconds(_ s: Double) -> String { String(format: "%.1f s", s) }
}
