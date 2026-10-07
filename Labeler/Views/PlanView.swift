//
//  PlanView.swift
//  RallyLab (iPhone)
//
//  The training plan as RallyLab on the Mac runs it: the rounds as a
//  timeline — trained ones with each run's F1 per surface, the current one
//  with its frames per surface, what still blocks it and the videos to
//  track next. Training itself starts on the Mac (Project → Plan).
//

import SwiftUI

struct PlanView: View {
    let model: LabelerModel

    var body: some View {
        let progress = model.progress
        let current = model.currentRound
        let state = model.projectState
        List {
            ForEach(TrainingPlan.rounds, id: \.number) { round in
                let record = state?.plan.first { $0.round == round.number }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: record?.finished == true ? "checkmark.circle.fill" : record != nil ? "hourglass.circle.fill"
                                  : round.number == current?.number ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(record?.finished == true ? .green : round.number == current?.number ? Color.accentColor : .secondary)
                            Text("Round \(round.number)").font(.headline)
                            Spacer()
                            Text("\(round.frames.formatted()) frames").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(round.runs.map(\.title).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        if let record {
                            trained(record, scores: state?.scores ?? [:])
                        } else if round.number == current?.number {
                            currentRound(round, progress)
                        } else {
                            Text(round.why).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .refreshable { await model.reload() }
        .navigationTitle("Plan")
    }

    private func trained(_ record: TrainedRound, scores: [String: [String: Double]]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trained \(record.date.formatted(date: .abbreviated, time: .omitted)) on \(record.frames.values.reduce(0, +).formatted()) frames")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    ForEach(["Run", "Tracked", "Indoor", "Grass", "Beach"], id: \.self) { Text($0).font(.caption2.weight(.semibold)) }
                }
                ForEach(Array(record.runs.enumerated()), id: \.offset) { _, run in
                    let s = run.name.flatMap { scores[$0] }
                    GridRow {
                        Text(run.run.title).font(.caption)
                        ForEach(["tracked", "indoor", "grass", "beach"], id: \.self) { k in
                            Text(s?[k].map { String(format: "%.2f", $0) } ?? (run.broughtBack ? "—" : "…")).font(.caption.monospacedDigit())
                        }
                    }
                }
            }
        }
    }

    private func currentRound(_ round: TrainingPlan.Round, _ progress: PlanProgress) -> some View {
        let blockers = progress.blockers(round)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(LabelSurface.allCases) { surface in
                let s = progress.surfaces[surface.rawValue] ?? PlanProgress.Surface()
                HStack {
                    Label(surface.rawValue, systemImage: surface.icon).font(.callout).frame(width: 90, alignment: .leading)
                    ProgressView(value: min(1, Double(s.frames) / Double(PlanProgress.quota(round))))
                    Text("\(s.frames.formatted())").font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
                }
            }
            if blockers.isEmpty {
                Label("Ready — train it from RallyLab on the Mac (Project → Plan).", systemImage: "checkmark.seal.fill")
                    .font(.callout).foregroundStyle(.green)
            } else {
                ForEach(blockers, id: \.self) { Label($0, systemImage: "circle.dashed").font(.caption) }
            }
            if !progress.queue.isEmpty {
                Text("Track next: " + progress.queue.prefix(4).map(\.name).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
