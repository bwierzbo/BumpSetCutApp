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

    init() {
        // `RallyLab --export-training-data [path]` batch-exports classifier
        // training data and exits (no UI interaction needed).
        HeadlessTrainingExport.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
