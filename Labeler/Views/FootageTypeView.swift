//
//  FootageTypeView.swift
//  RallyLab (iPhone)
//
//  The footage-type step on the phone (D-032 / D-033): after "That's every
//  rally", and from a recording's page at any time. The person says what
//  the recording is — continuous, edited, or unknown — and the choice goes
//  to the Mac as a claim: saved on this phone first, sent when online,
//  confirmed or declined by RallyLab, which alone writes the recording's
//  footage record. The screen shows the facts (the excluded intervals, the
//  pass), what the Mac has published as the type, and exactly where this
//  phone's choice stands — never "accepted" for a choice the Mac has not
//  confirmed. Nothing here infers a type: a cut is an exclusion, not a
//  classification, and no cuts is not "continuous".
//

import SwiftUI

struct FootageTypeView: View {
    let model: LabelerModel
    let video: LabelVideo
    let duration: Double
    /// Right after the pass (the completion is recorded already), or opened to choose or change.
    let afterPass: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var choice: RecordingTypeClaims.Kind?
    @State private var problem: String?

    private var current: LabelVideo { model.video(video.id) ?? video }
    private var times: LabelRallyTimes { model.rallyTimes(for: current) }
    private var display: RecordingTypeClaims.Display { model.footageType(for: current) }
    private var published: RecordingTypeClaims.Kind? { current.recordingType.flatMap(RecordingTypeClaims.Kind.init(rawValue:)) }
    private var selected: RecordingTypeClaims.Kind { choice ?? display.kind ?? published ?? .unknown }

    var body: some View {
        List {
            Section {
                ForEach(RecordingTypeClaims.Kind.allCases, id: \.self) { kind in
                    Button { choice = kind } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: selected == kind ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected == kind ? Color.accentColor : Color.secondary)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(kind.title).foregroundStyle(.primary)
                                Text(kind.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("What is this recording?")
            } footer: {
                if afterPass {
                    Text("Every visible rally is marked, and that is recorded. What the footage is, is a separate fact: say it here, or later from the recording's page.")
                }
            }
            Section("This recording") {
                let cuts = times.cutRanges
                LabeledContent("Excluded intervals", value: cuts.isEmpty ? "none"
                               : "\(cuts.count) · \(String(format: "%.1f s", duration > 0 ? cuts.seconds(within: duration) : cuts.reduce(0) { $0 + $1.seconds })) not footage")
                if !cuts.isEmpty {
                    Text(cuts.map { "\(clockText($0.start)) – \(clockText($0.end))" }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Rally pass", value: times.complete ? "every visible rally marked" : "not finished")
                LabeledContent("On the Mac", value: published.map { $0.title.lowercased() + (current.recordingTypeAt.map { " (since \(Self.day($0)))" } ?? "") } ?? "not confirmed yet")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your choice").font(.callout)
                    Text(display.statusText(problem: model.claimProblem(for: current))).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                Button {
                    if let why = model.claimRecordingType(selected, for: current) { problem = why } else { dismiss() }
                } label: {
                    Text(afterPass ? "Confirm and continue" : "Confirm").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!sendable)
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                Button(afterPass ? "Not now" : "Cancel") { dismiss() }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let problem { Text(problem).foregroundStyle(.red) }
                    if !sendable, problem == nil { Text(unsendable ?? "") }
                    Text("Your choice is a request: RallyLab on the Mac checks it against the project and confirms it, and this page shows whether it was sent, accepted or not accepted. Skipping leaves the recording's type as it is.")
                }
            }
        }
        .navigationTitle("Footage type")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Whether a choice can be made for this recording at all (the Mac has published its identity and it is open to labeling).
    private var sendable: Bool { unsendable == nil }
    private var unsendable: String? {
        guard let fingerprint = current.sourceFingerprint, !fingerprint.isEmpty else { return "The Mac hasn't published this recording's identity yet — sync from the Mac first." }
        guard model.isReviewable(current) else { return "This recording isn't open to labeling on this phone." }
        return nil
    }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return f.string(from: date)
    }
}
