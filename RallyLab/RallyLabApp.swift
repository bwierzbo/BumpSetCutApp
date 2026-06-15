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

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
