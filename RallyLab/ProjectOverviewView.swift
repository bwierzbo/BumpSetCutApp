//
//  ProjectOverviewView.swift
//  RallyLab
//
//  The project at a glance: how many frames there are per environment, and
//  within each per ball type and per camera setup — pulled, labeled (what
//  a training package takes), with a ball — and from how many different
//  videos, so a thin spot in the training set shows before it shows in the
//  model.
//

import SwiftUI

struct ProjectOverviewView: View {
    let projects: ProjectsModel

    var body: some View {
        let overview = projects.overview()
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    SummaryCard(title: "Frames pulled", value: overview.all.frames,
                                detail: "from \(overview.all.videos) cut\(overview.all.videos == 1 ? "" : "s")",
                                icon: "photo.stack", tint: .blue)
                    SummaryCard(title: "Labeled", value: overview.all.labeled,
                                detail: percent(overview.all.labeled, of: overview.all.frames) + " of pulled",
                                icon: "checkmark.seal", tint: ReviewStyle.yours)
                    SummaryCard(title: "With a ball", value: overview.all.withBall,
                                detail: "\(overview.all.labeled - overview.all.withBall) labeled with none",
                                icon: "volleyball", tint: ReviewStyle.guess)
                    SummaryCard(title: "Source videos", value: overview.all.sources.count,
                                detail: "different originals", icon: "film.stack", tint: .purple)
                }

                ForEach(ClipBoardView.environments, id: \.name) { env in
                    EnvironmentCard(
                        name: env.name, icon: env.icon, tint: env.tint,
                        overview: overview.environments.first { $0.name == env.name }
                    )
                }
                ForEach(overview.environments.filter { e in !ClipBoardView.environments.contains { $0.name == e.name } }) { e in
                    EnvironmentCard(name: e.name, icon: "questionmark.folder", tint: .gray, overview: e)
                }
            }
            .padding(20)
        }
        .background(.background.secondary)
    }
}

private func percent(_ part: Int, of whole: Int) -> String {
    whole == 0 ? "0%" : "\(Int((Double(part) / Double(whole) * 100).rounded()))%"
}

private struct SummaryCard: View {
    let title: String
    let value: Int
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(value, format: .number)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct EnvironmentCard: View {
    let name: String
    let icon: String
    let tint: Color
    let overview: ProjectsModel.EnvironmentOverview?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.title2.weight(.bold))
                    if let total = overview?.total {
                        Text("\(total.labeled) labeled of \(total.frames) frames · \(total.withBall) with a ball · \(total.sources.count) source video\(total.sources.count == 1 ? "" : "s")")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text("No footage yet").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            if let overview {
                let scale = max(overview.total.frames, 1)
                HStack(alignment: .top, spacing: 24) {
                    Breakdown(title: "By ball", rows: overview.byBall, scale: scale, tint: tint)
                    Breakdown(title: "By camera", rows: overview.byCamera, scale: scale, tint: tint)
                }
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct Breakdown: View {
    let title: String
    let rows: [(name: String, count: ProjectsModel.FrameCount)]
    /// The environment's frame total: bars are shares of it.
    let scale: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold)).textCase(.uppercase).tracking(0.6)
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.name) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.name).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(row.count.labeled)")
                            .font(.callout.weight(.semibold)).monospacedDigit()
                        + Text(" / \(row.count.frames)").font(.callout).foregroundStyle(.secondary)
                    }
                    ShareBar(pulled: Double(row.count.frames) / Double(scale),
                             labeled: Double(row.count.labeled) / Double(scale), tint: tint)
                    HStack(spacing: 10) {
                        Label("\(row.count.sources.count) source\(row.count.sources.count == 1 ? "" : "s")",
                              systemImage: "film")
                        Label("\(row.count.withBall) with a ball", systemImage: "volleyball")
                    }
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Light: frames pulled. Solid: of those, labeled.
private struct ShareBar: View {
    let pulled: Double
    let labeled: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(tint.opacity(0.3)).frame(width: geo.size.width * min(pulled, 1))
                Capsule().fill(tint).frame(width: geo.size.width * min(labeled, 1))
            }
        }
        .frame(height: 7)
        .help("Light: frames pulled. Solid: labeled.")
    }
}
