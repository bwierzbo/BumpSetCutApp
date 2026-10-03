//
//  RallyLabApp.swift
//  RallyLab
//
//  macOS sandbox for labeling volleyball rallies and evaluating the
//  BumpSetCut rally-segmentation pipeline against ground truth.
//

import SwiftUI

@main
struct RallyLabApp: App {
    @State private var model = RallyLabModel()
    @State private var sampler: SamplerModel
    /// Reopens the last project on launch, the way Xcode restores its window.
    @State private var projects: ProjectsModel
    @State private var library: ModelLibrary
    @State private var tracker: TrackLabelModel
    @State private var marker: RallyMarkModel

    init() {
        // `RallyLab --export-training-data [path]` batch-exports classifier
        // training data and exits (no UI interaction needed).
        HeadlessTrainingExport.runIfRequested()
        // `RallyLab --sample <videos or frame folders…>` runs the Sampler
        // tab's ingest queue into the dataset and exits.
        HeadlessSampler.runIfRequested()
        // `RallyLab --project <name> [--get <id> <link|file>] [--status]`
        // runs the Projects tab: pull a clip into a project and exit.
        HeadlessProjects.runIfRequested()

        let sampler = SamplerModel()
        _sampler = State(initialValue: sampler)
        _projects = State(initialValue: ProjectsModel(sampler: sampler))
        _library = State(initialValue: ModelLibrary(sampler: sampler))
        _tracker = State(initialValue: TrackLabelModel(sampler: sampler))
        _marker = State(initialValue: RallyMarkModel(sampler: sampler))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, sampler: sampler, projects: projects, library: library, tracker: tracker, marker: marker)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { projects.isCreatingProject = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open Project…") { ProjectPanels.openExisting(projects) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Menu("Open Recent Project") {
                    ForEach(projects.recentProjects, id: \.self) { dir in
                        Button(dir.lastPathComponent) { projects.open(dir) }
                    }
                }
                .disabled(projects.recentProjects.isEmpty)
                Divider()
                Button("Close Project") { projects.close() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(projects.project == nil)
            }
        }
    }
}
