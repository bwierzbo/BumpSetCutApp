//
//  MarkingProgressView.swift
//  RallyLab
//
//  On the Next page: how far marking the rallies has got (MarkingProgress)
//  — videos marked through, started and left, the footage still to watch,
//  a meter per surface, and underneath, per surface, the videos of each
//  kind (camera, light, orientation) with how many of them are left.
//

import SwiftUI

struct MarkingProgressView: View {
    let progress: MarkingProgress
    @AppStorage("RallyLab.markingBreakdown") private var showBreakdown = false
    @State private var facet = VideoType.Facet.camera

    var body: some View {
        let t = progress.total
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 11)
                    Circle().trim(from: 0, to: t.fraction)
                        .stroke(ReviewStyle.yours, style: StrokeStyle(lineWidth: 11, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(Int((t.fraction * 100).rounded()))%").font(.title3.bold().monospacedDigit())
                }
                .frame(width: 86, height: 86)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Marking the rallies").font(.title2.bold())
                    Text("\(t.marked) of \(t.videos) videos marked · \(t.left) left")
                        .font(.body.monospacedDigit())
                    Text(detail(t)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("\(t.rallies.formatted()) rallies marked so far · \(t.valMarked) of \(t.valVideos) val videos")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 22) {
                ForEach(progress.surfaces, id: \.surface) { surface, b in
                    let env = ClipBoardView.environments.first { $0.name == surface }
                    VStack(alignment: .leading, spacing: 3) {
                        Label(surface, systemImage: env?.icon ?? "film").foregroundStyle(env?.tint ?? .secondary).font(.headline)
                        Meter(value: b.marked, target: b.videos, tint: env?.tint ?? .accentColor)
                        Text(surfaceDetail(b)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            DisclosureGroup(isExpanded: $showBreakdown) {
                breakdown.padding(.top, 8)
            } label: {
                Text("Breakdown by kind of video").font(.subheadline.weight(.semibold))
            }
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private func detail(_ t: MarkingProgress.Bucket) -> String {
        var parts: [String] = []
        if t.left == 0 { return "Every video is marked through." }
        if t.footageLeft > 0 { parts.append("about \(MarkingProgress.clock(t.footageLeft)) of footage still to watch") }
        if t.started > 0 { parts.append("\(t.started) started and not finished") }
        if t.unreachable > 0 { parts.append("\(t.unreachable) can't be played here — footage not on this Mac or the desktop") }
        return parts.joined(separator: " · ")
    }

    private func surfaceDetail(_ b: MarkingProgress.Bucket) -> String {
        var parts = ["\(b.left) left"]
        if b.footageLeft > 0 { parts.append(MarkingProgress.clock(b.footageLeft)) }
        if b.started > 0 { parts.append("\(b.started) started") }
        return parts.joined(separator: " · ")
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Group by", selection: $facet) {
                ForEach(VideoType.Facet.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    ForEach(["", "Videos", "Marked", "Started", "Left", "Footage left", "Rallies"], id: \.self) {
                        Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .gridColumnAlignment($0.isEmpty ? .leading : .trailing)
                    }
                }
                ForEach(progress.breakdown(by: facet), id: \.surface) { group in
                    let env = ClipBoardView.environments.first { $0.name == group.surface }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Label(group.surface, systemImage: env?.icon ?? "film").foregroundStyle(env?.tint ?? .primary).font(.headline)
                        cells(group.total, bold: true)
                    }
                    ForEach(group.rows, id: \.kind) { row in
                        GridRow {
                            Text(row.kind).font(.callout).padding(.leading, 26)
                            cells(row.bucket, bold: false)
                        }
                    }
                }
            }
            Text("Footage left is roughly the length of the videos not marked through (from where their sampled frames reach). Every surface and kind should keep a share of marked videos so the decision model isn't trained on one setting.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func cells(_ b: MarkingProgress.Bucket, bold: Bool) -> some View {
        let font: Font = bold ? .callout.weight(.semibold).monospacedDigit() : .callout.monospacedDigit()
        Text("\(b.videos)").font(font)
        Text("\(b.marked)").font(font).foregroundStyle(b.marked == 0 ? Color.red : ReviewStyle.yours)
        Text("\(b.started)").font(font).foregroundStyle(b.started == 0 ? Color.secondary : .orange)
        Text("\(b.left)").font(font).foregroundStyle(b.left == 0 ? Color.secondary : .primary)
        Text(b.footageLeft > 0 ? MarkingProgress.clock(b.footageLeft) : "—").font(font).foregroundStyle(.secondary)
        Text("\(b.rallies)").font(font).foregroundStyle(.secondary)
    }
}
