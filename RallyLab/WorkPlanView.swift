//
//  WorkPlanView.swift
//  RallyLab
//
//  The top of the Plan page: what is left to do before the project's
//  recordings can teach the rally classifier (WorkPlan — the same numbers
//  as the phone's Home). The steps with their counts, the camera groups
//  marked and audited per surface, and every recording still to mark in
//  the order to mark them — a new camera group before more of one already
//  covered — each a click from its marking pass.
//

import SwiftUI

struct WorkPlanView: View {
    let plan: WorkPlan.Plan
    /// The project's files have been read (groups, audits, footage types); until then the counts are without them.
    let factsRead: Bool
    /// Opens a recording's marking pass.
    let open: (String) -> Void
    @State private var showHeld = false

    var body: some View {
        let mark = plan.items(.mark), held = plan.items(.mark, held: true)
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Work to do").font(.title2.weight(.bold))
                Text("What each recording still needs before it can teach the rally classifier: its rallies marked, its footage type said, its unmarked time reviewed in the coverage audit. A new camera group widens the dataset; another recording of a group already marked adds minutes, not variety — so new groups lead.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !factsRead {
                    Label("Reading the project's camera groups, audits and footage types…", systemImage: "hourglass").font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                step("Mark the rallies", mark.count, plan.markingSeconds > 0 ? "about \(MarkingProgress.clock(plan.markingSeconds)) · \(plan.newGroups) new camera groups" : "\(plan.newGroups) new camera groups", .accentColor)
                step("Say the footage type", plan.items(.type, held: nil).count, "marked through, type not said", .purple)
                if plan.auditKnown {
                    step("Coverage audit", plan.items(.audit).count, "drawn, intervals to look at", .teal)
                    step("Settle findings", plan.items(.fix).count, "fix the marks, then a new draw", .orange)
                    step("Next audit draw", plan.items(.draw).count, "marked and continuous, in no draw", .secondary)
                }
                step("For scoring only", held.count, "withheld: marked last, never trained on", .secondary)
            }
            groups
            names("Footage type to say", plan.items(.type, held: nil))
            if plan.auditKnown {
                names("In the coverage audit", plan.items(.audit))
                names("Findings to settle (Edit rally times, then a new draw)", plan.items(.fix))
                names("Waiting for the next audit draw", plan.items(.draw))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Mark next").font(.title3.weight(.bold))
                if mark.isEmpty {
                    Text("Every recording that can train is marked through.").font(.callout).foregroundStyle(.secondary)
                } else {
                    rows(mark)
                }
                if !held.isEmpty {
                    DisclosureGroup("Withheld — \(held.count) to mark for scoring", isExpanded: $showHeld) { rows(held) }
                        .font(.callout)
                }
                if plan.backlog > 0 {
                    Text("\(plan.backlog) set aside (the backlog): Coverage puts one back.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func step(_ title: String, _ count: Int, _ detail: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint)
            Text("\(count)").font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(count == 0 ? Color.secondary : .primary)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }

    private var groups: some View {
        let t = plan.total
        return VStack(alignment: .leading, spacing: 8) {
            Text("Camera groups").font(.title3.weight(.bold))
            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Groups"); Text("Marked")
                    if plan.auditKnown { Text("Audited clean") }
                    Text("Recordings"); Text("Marked"); Text("Continuous")
                    if plan.auditKnown { Text("Audited clean") }
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(plan.surfaces + [t], id: \.surface) { s in
                    GridRow {
                        Text(s.surface).fontWeight(s.surface == t.surface ? .semibold : .regular)
                        Text("\(s.groups)")
                        Text("\(s.groupsMarked)").foregroundStyle(s.groupsMarked == 0 ? Color.red : .primary)
                        if plan.auditKnown { Text("\(s.groupsClean)").foregroundStyle(s.groupsClean == 0 ? Color.red : .primary) }
                        Text("\(s.recordings)"); Text("\(s.marked)"); Text("\(s.continuous)")
                        if plan.auditKnown { Text("\(s.clean)") }
                    }
                    .font(.callout.monospacedDigit())
                }
            }
            Text("Of the recordings that can train (not withheld, not set aside). Groups are the split manifest's as last written; a recording added since counts as its own group until the manifest is rebuilt.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func names(_ title: String, _ items: [WorkPlan.Item]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(title) — \(items.count)").font(.subheadline.weight(.semibold))
                Text(items.map(\.name).sorted().joined(separator: "  ·  "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rows(_ items: [WorkPlan.Item]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                HStack(spacing: 10) {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                    Text(item.name).font(.callout.monospaced()).lineLimit(1)
                    if item.newGroup {
                        Text("new group").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                    } else if item.group != item.name {
                        Text("with \(item.group)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if !item.playable { Text("footage not on this Mac").font(.caption2).foregroundStyle(.orange) }
                    Text(item.surface).font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    Text(item.seconds.map(MarkingProgress.clock) ?? "—").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 54, alignment: .trailing)
                    Button("Mark") { open(item.name) }.controlSize(.small).disabled(!item.playable)
                }
                .padding(.vertical, 4)
                if i < items.count - 1 { Divider() }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
}
