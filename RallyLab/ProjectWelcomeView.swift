//
//  ProjectWelcomeView.swift
//  RallyLab
//
//  What RallyLab opens to when no project is open, laid out like Xcode's
//  welcome window: the app and its two actions on the left, recent
//  projects on the right. The New Project sheet and the Open panel live
//  here too, shared with the project menu and the File menu.
//

import AppKit
import SwiftUI

struct ProjectWelcomeView: View {
    @Bindable var projects: ProjectsModel
    /// Carry on to the analysis tabs without a project.
    let continueWithoutProject: () -> Void

    @State private var selection: URL?

    var body: some View {
        HStack(spacing: 0) {
            leftPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            recentList
                .frame(width: 340)
                .frame(maxHeight: .infinity)
                .background(.background.secondary)
        }
    }

    // MARK: - Left

    private var leftPanel: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            Text("RallyLab")
                .font(.system(size: 36, weight: .bold))
                .padding(.top, 8)
            Text("Training sets for the BumpSetCut ball detector")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                WelcomeAction(icon: "plus.square", title: "Create New Project…",
                              detail: "A new training set with the \(StandardClipPlan.clips.count)-clip plan") {
                    projects.isCreatingProject = true
                }
                WelcomeAction(icon: "folder", title: "Open Existing Project…",
                              detail: "A project folder from another drive or Mac") {
                    ProjectPanels.openExisting(projects)
                }
            }
            .padding(.top, 36)
            .frame(width: 340)

            Spacer()
            Button("Continue without a project") { continueWithoutProject() }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.bottom, 16)
                .help("The Pipeline, Net, Compare and Phase 1 tabs don't need a project.")
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Recents

    private var recentList: some View {
        Group {
            if projects.recentProjects.isEmpty {
                VStack(spacing: 6) {
                    Text("No Recent Projects").font(.headline).foregroundStyle(.secondary)
                    Text("Projects you create or open show up here.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(projects.recentProjects, id: \.self) { dir in
                        RecentProjectRow(dir: dir, opened: projects.lastOpened(dir))
                            .tag(dir)
                            .contextMenu {
                                Button("Open") { projects.open(dir) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                                Divider()
                                Button("Remove from Recents") { projects.forget(dir) }
                            }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: URL.self) { _ in } primaryAction: { dirs in
                    if let dir = dirs.first { projects.open(dir) }
                }
                .onKeyPress(.return) {
                    guard let selection else { return .ignored }
                    projects.open(selection)
                    return .handled
                }
            }
        }
    }
}

private struct WelcomeAction: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct RecentProjectRow: View {
    let dir: URL
    let opened: Date?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(dir.lastPathComponent).font(.body.weight(.semibold))
                Text((dir.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let opened {
                    Text(opened, format: .relative(presentation: .named))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
        .help(dir.path)
    }
}

// MARK: - New Project sheet

struct NewProjectSheet: View {
    @Bindable var projects: ProjectsModel
    @State private var name = ""
    @State private var location = ProjectsModel.defaultLocation

    var body: some View {
        let folder = ProjectsModel.folder(for: name.isEmpty ? "name" : name, in: location)
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose options for your new project:").font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Project Name:").gridColumnAlignment(.trailing)
                    TextField("e.g. v3", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(create)
                }
                GridRow {
                    Text("Location:")
                    HStack {
                        Text((location.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                        Button("Choose…") { chooseLocation() }
                    }
                }
                GridRow {
                    Text("Clip Plan:")
                    Text("Standard, \(StandardClipPlan.clips.count) clips · \(StandardClipPlan.targetFrames) frames each")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            GroupBox {
                VStack(alignment: .leading, spacing: 3) {
                    Text((folder.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.head)
                    Group {
                        Text("footage/raw/self · online · negatives — clips by environment")
                        Text("footage/meta/sources.csv — where each clip came from")
                        Text("images/train · images/val, labels/train · labels/val")
                        Text("sessions · excluded · runs · models · exports · data.yaml")
                    }
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Will create").font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { projects.isCreatingProject = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        projects.create(name: name, in: location)
        projects.isCreatingProject = false
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = location
        panel.prompt = "Choose"
        panel.message = "Where the project's folder will be created. Use New Folder to make one."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        location = url
    }
}

enum ProjectPanels {
    @MainActor
    static func openExisting(_ projects: ProjectsModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        panel.message = "A project folder (the one with project.json in it)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projects.open(url)
    }
}
