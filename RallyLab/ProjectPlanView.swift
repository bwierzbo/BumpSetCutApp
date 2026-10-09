//
//  ProjectPlanView.swift
//  RallyLab
//
//  The training plan as a timeline (see TrainingPlan): rounds already
//  trained with what each run scored per surface, the round you're on with
//  its frames per surface against an even share, what still blocks it and
//  the videos to track next — one rally each, spread over many videos —
//  and the button that exports and trains it on the desktop.
//

import SwiftUI

struct ProjectPlanView: View {
    let projects: ProjectsModel
    /// Opens a video in the Track tab.
    let track: (VideoSession) -> Void
    @State private var plan: TrainingPlanModel
    let phone: LabelingSync
    @State private var email = ""
    @State private var password = ""

    init(projects: ProjectsModel, library: ModelLibrary, phone: LabelingSync, track: @escaping (VideoSession) -> Void) {
        self.projects = projects
        self.phone = phone
        self.track = track
        _plan = State(initialValue: TrainingPlanModel(library: library))
    }

    var body: some View {
        let current = plan.currentRound
        let progress = PlanProgress(videos: projects.sampler.sessions.map(PlanVideo.init(session:)), round: current)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                intro(progress)
                    .padding(.bottom, 12)
                phoneBox
                    .padding(.bottom, 18)
                ForEach(TrainingPlan.rounds, id: \.number) { round in
                    let record = plan.history.first { $0.round == round.number }
                    let isLast = round.number == TrainingPlan.rounds.last?.number
                    HStack(alignment: .top, spacing: 14) {
                        marker(record: record, isCurrent: round.number == current?.number, isLast: isLast)
                        VStack(alignment: .leading, spacing: 10) {
                            header(round, record: record)
                            if let record {
                                trained(record)
                            } else if round.number == current?.number {
                                currentRound(round, progress: progress)
                            } else {
                                Text(round.why).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.bottom, isLast ? 0 : 26)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(.background.secondary)
        .onAppear {
            // Videos imported in the background (RallyLab --get) since the project opened.
            projects.sampler.reloadSessions()
            plan.reload()
        }
        .onChange(of: projects.projectDir) { plan.reload() }
    }

    // MARK: - Intro

    private func intro(_ progress: PlanProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Training plan").font(.title2.weight(.bold))
            Text("Track a few thousand frames spread evenly over indoor, grass and beach and over many videos, then train. Each round trains fine-tuned and from-scratch models on the same frames, so you can see when from scratch takes over.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                stat("\(progress.frames.formatted())", "labeled frames")
                stat("\(progress.rallies)", "tracked rallies")
                stat("\(progress.framesPerRally)", "frames per rally")
                stat("\(progress.rallyTimeVideos)", "rally-time videos")
            }
            .padding(.top, 4)
            if !plan.status.isEmpty {
                Label(plan.status, systemImage: plan.isRunning ? "hourglass" : "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if plan.isRunning, !plan.library.heatmaps.desktopLine.isEmpty {
                Text(plan.library.heatmaps.desktopLine).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            } else if plan.isRunning, !plan.library.status.isEmpty {
                Text(plan.library.status).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    /// The Labeler iPhone app: rally times marked there, videos recorded there.
    private var phoneBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Phone (RallyLab on iPhone)", systemImage: "iphone").font(.headline)
            if phone.signedIn {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.green)
                    TimelineView(.periodic(from: .now, by: 10)) { _ in
                        Text(phone.isSyncing ? "Syncing…"
                             : phone.lastSynced.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Syncing automatically")
                            .font(.callout)
                    }
                    if phone.isSyncing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Sync Now") { Task { await phone.sync() } }
                        .disabled(phone.isSyncing)
                    Button("Sign Out") { Task { await phone.signOut() } }.buttonStyle(.link)
                }
                Text("Kept in sync automatically while RallyLab is open: tracked rallies, reviews and rally times every \(LabelingSync.interval) seconds and whenever RallyLab comes to the front (the newer side wins); videos — new ones sent as small copies, ones recorded on the phone pulled in — every few minutes.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    TextField("Email", text: $email).frame(width: 220)
                    SecureField("Password", text: $password).frame(width: 160)
                    Button("Sign In") { Task { await phone.signIn(email: email, password: password); password = "" } }
                        .disabled(email.isEmpty || password.isEmpty)
                }
                .textFieldStyle(.roundedBorder)
                Text("Your BumpSetCut account (it must be on the labelers list).").font(.caption).foregroundStyle(.secondary)
            }
            if !phone.status.isEmpty {
                Text(phone.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Timeline

    private func marker(record: TrainedRound?, isCurrent: Bool, isLast: Bool) -> some View {
        let tint: Color = record?.finished == true ? ReviewStyle.yours : isCurrent || record != nil ? .accentColor : .secondary
        let icon = record?.finished == true ? "checkmark.circle.fill" : record != nil ? "hourglass.circle.fill"
            : isCurrent ? "largecircle.fill.circle" : "circle"
        return VStack(spacing: 0) {
            Image(systemName: icon).font(.title2).foregroundStyle(tint)
            if !isLast {
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 2).frame(maxHeight: .infinity)
            }
        }
        .frame(width: 26)
    }

    private func header(_ round: TrainingPlan.Round, record: TrainedRound?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Round \(round.number)").font(.headline)
                Text("\(round.frames.formatted()) frames · \(round.rallyTimeVideos) rally-time videos")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                if let record {
                    Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                ForEach(round.runs, id: \.self) { run in
                    Text(run.title).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((run.fromScratch ? Color.purple : Color.teal).opacity(0.15), in: Capsule())
                        .foregroundStyle(run.fromScratch ? Color.purple : Color.teal)
                }
            }
        }
    }

    // MARK: - A trained round

    private func trained(_ record: TrainedRound) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trained on \(record.frames.values.reduce(0, +).formatted()) frames — "
                 + TrainingPlan.surfaces.map { "\($0.lowercased()) \((record.frames[$0] ?? 0).formatted())" }.joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(["Run", "Tracked F1", "Indoor", "Grass", "Beach", ""], id: \.self) {
                        Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(record.runs.enumerated()), id: \.offset) { _, state in
                    let scores = state.name.flatMap(plan.scores)
                    GridRow {
                        Text(state.run.title).font(.callout)
                        score(scores?.f1("tracked"))
                        score(scores?.f1("indoor"))
                        score(scores?.f1("grass"))
                        score(scores?.f1("beach"))
                        Text(state.broughtBack ? (state.name ?? "") : state.name == nil ? "not started" : "training…")
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
            if !record.finished, !plan.isRunning {
                Button("Carry On Training") { plan.resume(record) }
                    .disabled(plan.library.heatmaps.desktopBusy)
                    .help("Starts the runs that haven't started and brings back the ones still training on the desktop")
            }
            Text("F1 on the package's val windows, ball in play within 4 px. Score rally cutting with the newest model in the Pipeline tab, and check it on the iPhone.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func score(_ f1: Double?) -> some View {
        Text(f1.map { String(format: "%.2f", $0) } ?? "—").font(.callout.monospacedDigit())
    }

    // MARK: - The current round

    private func currentRound(_ round: TrainingPlan.Round, progress: PlanProgress) -> some View {
        let blockers = progress.blockers(round)
        return VStack(alignment: .leading, spacing: 14) {
            Text(round.why).font(.callout).foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    Text("")
                    Text("Frames · target \(PlanProgress.quota(round).formatted()) each").font(.caption.weight(.semibold))
                    Text("Validation share").font(.caption.weight(.semibold))
                    Text("Rally-time videos").font(.caption.weight(.semibold))
                }
                ForEach(ClipBoardView.environments.filter { TrainingPlan.surfaces.contains($0.name) }, id: \.name) { env in
                    let s = progress.surfaces[env.name] ?? PlanProgress.Surface()
                    GridRow {
                        Label(env.name, systemImage: env.icon).foregroundStyle(env.tint).font(.headline)
                        Meter(value: s.frames, target: PlanProgress.quota(round), tint: env.tint)
                        Text(s.frames > 0 ? "\(Int((Double(s.valFrames) / Double(s.frames) * 100).rounded()))%" : "—")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(s.valFrames == 0 ? Color.red : .primary)
                        Meter(value: s.rallyTimeVideos,
                              target: (round.rallyTimeVideos + TrainingPlan.surfaces.count - 1) / TrainingPlan.surfaces.count,
                              tint: env.tint)
                    }
                }
            }
            .padding(14)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))

            if !progress.queue.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Track next — one rally from each").font(.subheadline.weight(.semibold))
                    ForEach(progress.queue) { next in nextRow(next) }
                    Text("About \(TrainingPlan.enoughFramesPerVideo) frames (~20 s of rally) per video, then move on; track a little before the serve and after the ball dies, and mark hidden frames.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
            } else if !blockers.isEmpty {
                Label("No video on this Mac has room for another rally on the surfaces that need one — add footage in the Board.",
                      systemImage: "film.stack").font(.callout).foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 6) {
                if blockers.isEmpty {
                    Label("Ready to train round \(round.number).", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(ReviewStyle.yours).font(.callout.weight(.semibold))
                } else {
                    ForEach(blockers, id: \.self) { Label($0, systemImage: "circle.dashed").font(.callout) }
                }
                let blocked = plan.isRunning || plan.library.isBusy || plan.library.heatmaps.desktopBusy
                    || progress.frames == 0 || plan.unfinished != nil
                HStack(spacing: 10) {
                    if blockers.isEmpty {
                        Button("Export & Train Round \(round.number)") { plan.exportAndTrain(round, progress: progress) }
                            .buttonStyle(.borderedProminent)
                            .disabled(blocked)
                    } else {
                        Button("Train Round \(round.number) Anyway") { plan.exportAndTrain(round, progress: progress) }
                            .disabled(blocked)
                            .help("Train before the round's frames are in — the timeline records what it had")
                    }
                    if plan.isRunning { ProgressView().controlSize(.small) }
                }
                Text("Exports a multi-frame package, then trains \(round.runs.map(\.title).joined(separator: ", ")) on the desktop one after another and brings each back. "
                     + "About an hour per 512 run per 10k frames; 768 takes about twice as long. RallyLab can be closed — Carry On Training picks it up.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func nextRow(_ next: PlanVideo) -> some View {
        let env = ClipBoardView.environments.first { $0.name == next.surface }
        return HStack(spacing: 10) {
            Image(systemName: env?.icon ?? "film").foregroundStyle(env?.tint ?? .secondary).frame(width: 18)
            Text(next.name).font(.callout.monospaced()).lineLimit(1)
            if next.split == "val" {
                Text("val").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.purple.opacity(0.15), in: Capsule()).foregroundStyle(.purple)
            }
            Spacer()
            Text("\(next.doneTracks)/\(TrainingPlan.maxRalliesPerVideo) tracked").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(next.openRallies > 0 ? "\(next.openRallies) found" : "search by hand").font(.caption).foregroundStyle(.secondary)
                .help(next.openRallies > 0 ? "Rallies the Sampler found that aren't tracked yet — pick one in the Track tab"
                                     : "The Sampler found no rallies here — add one with New Rally in the Track tab")
            Button("Track") {
                if let session = projects.session(named: next.name) { track(session) }
            }
        }
    }
}
