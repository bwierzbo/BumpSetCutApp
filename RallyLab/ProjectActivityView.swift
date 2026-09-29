//
//  ProjectActivityView.swift
//  RallyLab
//
//  Everything the project is working on, per video: Photos imports, cuts
//  and downloads, the sampling line, failures and what's finished, each
//  with its stage, a progress bar, how long it's been going and roughly how
//  long it has left.
//

import SwiftUI

struct ProjectActivityView: View {
    let projects: ProjectsModel
    /// Show a card on the board.
    let showCard: (String) -> Void
    /// Open a finished video's frames in the Sampler tab.
    let review: (VideoSession) -> Void

    var body: some View {
        let items = projects.activity()
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ActivitySummary(items: items)
                if items.isEmpty {
                    ContentUnavailableView("Nothing running", systemImage: "checkmark.circle",
                                           description: Text("Videos you drop on a card, add from a link, or move show up here while they're imported, cut and sampled."))
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity)
                }
                section("In progress", items.filter { $0.phase == .running })
                section("Waiting to sample", items.filter { $0.phase == .waiting })
                section("Failed", items.filter { $0.phase == .failed })
                section("Finished", items.filter { $0.phase == .finished }) {
                    Button("Clear") { projects.sampler.clearFinishedJobs() }
                        .buttonStyle(.link)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background.secondary)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [ProjectsModel.Activity],
                         @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(title) · \(items.count)")
                        .font(.caption.weight(.semibold)).textCase(.uppercase).tracking(0.6)
                        .foregroundStyle(.secondary)
                    Spacer()
                    trailing()
                }
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 56) }
                        ActivityRow(item: item, clip: item.clipId.flatMap { id in projects.project?.clips.first { $0.id == id } },
                                    session: item.sessionName.flatMap { projects.session(named: $0) },
                                    showCard: showCard, review: review,
                                    dismiss: item.videoJobId.map { id in { projects.dismissFailure(id) } })
                    }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
            }
        }
    }
}

private struct ActivitySummary: View {
    let items: [ProjectsModel.Activity]

    var body: some View {
        let counts: [(ProjectsModel.Activity.Kind, String, String, Color)] = [
            (.importing, "importing", "photo.on.rectangle", .purple),
            (.downloading, "downloading", "arrow.down.circle", .blue),
            (.cutting, "cutting", "scissors", .teal),
            (.sampling, "sampling", "sparkle.magnifyingglass", .orange),
            (.waiting, "waiting", "hourglass", .secondary),
            (.failed, "failed", "exclamationmark.triangle", .red),
        ]
        HStack(spacing: 8) {
            ForEach(counts, id: \.1) { kind, label, icon, tint in
                let n = items.filter { $0.kind == kind }.count
                HStack(spacing: 6) {
                    Image(systemName: icon)
                    Text("\(n)").font(.callout.weight(.bold)).monospacedDigit()
                    Text(label).font(.callout)
                }
                .foregroundStyle(n > 0 ? tint : Color.secondary.opacity(0.6))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background((n > 0 ? tint : Color.primary).opacity(n > 0 ? 0.12 : 0.04), in: Capsule())
            }
        }
    }
}

private struct ActivityRow: View {
    let item: ProjectsModel.Activity
    let clip: PlannedClip?
    let session: VideoSession?
    let showCard: (String) -> Void
    let review: (VideoSession) -> Void
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    if let clip {
                        Text("\(clip.environment) · \(clip.cameraTitle)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(timing(now: context.date))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                switch item.phase {
                case .running:
                    WorkProgressBar(stage: item.stage, overall: item.overall).font(.caption)
                case .waiting:
                    Text("Waiting to sample — \(ordinal(item.position ?? 1)) in line")
                        .font(.caption).foregroundStyle(.secondary)
                case .failed:
                    Text(item.detail ?? item.stage)
                        .font(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
                case .finished:
                    Text(item.detail ?? "Done").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                if let session, item.phase == .finished {
                    Button("Review") { review(session) }.controlSize(.small)
                }
                if let dismiss {
                    Button("Dismiss", action: dismiss).controlSize(.small)
                }
                if let clipId = item.clipId {
                    Button { showCard(clipId) } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.borderless)
                        .help("Show its card")
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var icon: String {
        switch item.kind {
        case .importing: return "photo.on.rectangle"
        case .downloading: return "arrow.down"
        case .cutting: return "scissors"
        case .sampling: return "sparkle.magnifyingglass"
        case .waiting: return "hourglass"
        case .failed: return "exclamationmark.triangle.fill"
        case .finished: return "checkmark"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .importing: return .purple
        case .downloading: return .blue
        case .cutting: return .teal
        case .sampling: return .orange
        case .waiting: return .secondary
        case .failed: return .red
        case .finished: return ReviewStyle.yours
        }
    }

    /// Running: elapsed and, once there's enough to go on, time left.
    /// Finished or failed: how long it took.
    private func timing(now: Date) -> String {
        guard let start = item.startedAt else { return "" }
        let end = item.finishedAt ?? now
        let elapsed = end.timeIntervalSince(start)
        guard item.phase == .running else { return "took \(clock(elapsed))" }
        if let overall = item.overall, overall > 0.05, overall < 1 {
            return "\(clock(elapsed)) · ~\(clock(elapsed / overall * (1 - overall))) left"
        }
        return clock(elapsed)
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : ["th", "st", "nd", "rd", "th", "th", "th", "th", "th", "th"][n % 10]
        return "\(n)\(suffix)"
    }
}
