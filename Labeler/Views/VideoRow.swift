//
//  VideoRow.swift
//  RallyLab (iPhone)
//
//  A video as a list shows it: its name and state, and what its footage is
//  (continuous, edited, unknown) as far as anyone has said.
//

import SwiftUI

/// A video's name and state: rally times, tracked rallies, on the phone.
struct VideoRow: View {
    let model: LabelerModel
    let video: LabelVideo

    var body: some View {
        let times = model.rallyTimes(for: video)
        let tracks = model.tracks(for: video)
        HStack(spacing: 10) {
            Image(systemName: times.complete ? "checkmark.circle.fill" : times.rallies.isEmpty ? "circle" : "circle.lefthalf.filled")
                .foregroundStyle(times.complete ? .green : times.rallies.isEmpty ? .secondary : .orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(video.name).font(.callout.monospaced()).lineLimit(1)
                    FootageTypeBadge(video: video, claim: model.footageType(for: video))
                    if video.isBacklogged {
                        Text(video.backlogReason.map { "backlog · \($0)" } ?? "backlog").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15), in: Capsule()).foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 6) {
                    Text("\(times.rallies.count) marked")
                    let plan = model.planVideo(video)
                    Text("· \(plan.rallies) rallies (\(plan.labeledFrames.formatted()) frames)")
                    let open = tracks.filter(\.isOpen).count + model.untrackedRallies(in: video).filter { LocalStore.trim(of: $0, in: video) != nil }.count
                    if open > 0 { Text("· \(open) in progress").foregroundStyle(.orange) }
                    let found = model.found(in: video).count
                    if found > 0 { Text("· \(found) found") }
                    if video.status == .uploaded { Text("· waiting for the Mac") }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if LocalStore.hasClip(video) { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green).font(.caption) }
            if video.split == "val" {
                Text("val").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.purple.opacity(0.15), in: Capsule()).foregroundStyle(.purple)
            }
        }
    }
}

/// What the recording is — continuous, edited, unknown — as confirmed on the Mac (the published type), else as the
/// phone's choice stands (sent and waiting, saved here, or refused); nothing yet is said too, so the list shows
/// which recordings still need the footage-type step (D-032).
struct FootageTypeBadge: View {
    let video: LabelVideo
    let claim: RecordingTypeClaims.Display

    var body: some View {
        let (word, icon, tint) = state
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(word)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
    }

    private var state: (String, String, Color) {
        // The published type counts only with a person behind it (`recordingTypeAt`; RecordingTypeClaims.reviewed):
        // the Mac publishes the record's default of unknown too, and that is not a confirmation.
        if let published = video.recordingType, video.recordingTypeAt != nil {
            return (published == "unknown" ? "reviewed · unknown" : published, Self.icon(for: published),
                    published == "continuous" ? .green : published == "edited" ? .orange : .gray)
        }
        switch claim {
        case .none: return ("not yet reviewed", "questionmark.circle", .secondary)
        case .pending(let p):
            // The server refused the claim itself: it is never sent again, a new choice is needed (Display.statusText).
            if p.refusal != nil { return ("\(p.kind.rawValue) · refused", "exclamationmark.triangle", .red) }
            return ("\(p.kind.rawValue) · saved here", "tray", .secondary)
        case .submitted(let c), .accepted(let c), .superseded(let c): return ("\(c.recordingType) · waiting for the Mac", "clock", .secondary)
        case .rejected(let c, _): return ("\(c.recordingType) · refused", "exclamationmark.triangle", .red)
        }
    }

    private static func icon(for type: String) -> String {
        switch type {
        case "continuous": return "film"
        case "edited": return "scissors"
        default: return "questionmark.video"
        }
    }
}
