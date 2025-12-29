//
//  ProcessVideoView.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/31/25.
//

import SwiftUI

// MARK: - ProcessVideoView
struct ProcessVideoView: View {
    // MARK: - Properties
    @State private var viewModel: ProcessVideoViewModel
    @State private var hasAppeared = false
    @Environment(\.dismiss) private var dismiss

    init(videoURL: URL, mediaStore: MediaStore, folderPath: String, onComplete: @escaping () -> Void, onShowPlayer: (() -> Void)? = nil) {
        self._viewModel = State(wrappedValue: ProcessVideoViewModel(
            videoURL: videoURL,
            mediaStore: mediaStore,
            folderPath: folderPath,
            onComplete: onComplete,
            onShowPlayer: onShowPlayer
        ))
    }

    // MARK: - Body
    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                backgroundGradient

                VStack(spacing: BSCSpacing.xxl) {
                    // Animated header
                    headerSection
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 20)
                        .animation(.bscSpring.delay(0.1), value: hasAppeared)

                    // Processing state content
                    stateContent
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 20)
                        .animation(.bscSpring.delay(0.2), value: hasAppeared)

                    Spacer()

                    // Action buttons
                    actionButtons
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 20)
                        .animation(.bscSpring.delay(0.3), value: hasAppeared)
                }
                .padding(BSCSpacing.xl)
            }
            .navigationTitle("AI Processing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onDisappear { viewModel.cancelProcessing() }
            .onAppear {
                viewModel.loadCurrentVideoMetadata()
                withAnimation {
                    hasAppeared = true
                }
            }
            .alert("Processing Error", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage)
            }
            .sheet(isPresented: $viewModel.showingFolderPicker) {
                ProcessedFolderSelectionSheet(
                    mediaStore: viewModel.mediaStore,
                    onFolderSelected: { folderPath in
                        viewModel.confirmSaveToFolder(folderPath)
                    },
                    onCancel: {
                        // Clean up temp file if cancelled
                        if let tempURL = viewModel.pendingSaveURL {
                            try? FileManager.default.removeItem(at: tempURL)
                        }
                        viewModel.pendingSaveURL = nil
                        viewModel.showingFolderPicker = false
                        dismiss()
                    }
                )
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Background
private extension ProcessVideoView {
    var backgroundGradient: some View {
        ZStack {
            Color.bscBackground
                .ignoresSafeArea()

            // Animated gradient orbs
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.bscBlue.opacity(0.1), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 250
                    )
                )
                .frame(width: 500, height: 500)
                .offset(x: -100, y: -150)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.bscTeal.opacity(0.08), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 200
                    )
                )
                .frame(width: 400, height: 400)
                .offset(x: 150, y: 250)
        }
    }
}

// MARK: - Header Section
private extension ProcessVideoView {
    var headerSection: some View {
        VStack(spacing: BSCSpacing.lg) {
            // Animated brain icon
            ProcessingIconView(isProcessing: viewModel.isProcessing, isComplete: viewModel.isComplete)

            // Title
            VStack(spacing: BSCSpacing.sm) {
                Text("Rally Detection")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.bscTextPrimary)

                Text("AI will analyze your video to remove dead time and keep only active rallies")
                    .font(.system(size: 15))
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - State Content
private extension ProcessVideoView {
    @ViewBuilder
    var stateContent: some View {
        switch viewModel.processingState {
        case .processing:
            processingContent
        case .pendingSave:
            processingContent  // Show processing UI while pending save
        case .complete:
            completeContent
        case .hasMetadata:
            hasMetadataContent
        case .alreadyProcessed:
            alreadyProcessedContent
        case .ready:
            readyContent
        }
    }

    var processingContent: some View {
        VStack(spacing: BSCSpacing.xl) {
            // Circular progress
            BSCProgressView(
                progress: viewModel.progress,
                style: .volleyball,
                showPercentage: true
            )
            .frame(width: 120, height: 120)

            Text("Analyzing video...")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.bscTextSecondary)
        }
        .padding(BSCSpacing.xl)
        .bscGlass(cornerRadius: BSCRadius.xl, padding: BSCSpacing.xl)
    }

    var completeContent: some View {
        VStack(spacing: BSCSpacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.bscSuccess.opacity(0.15))
                    .frame(width: 80, height: 80)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.bscSuccess)
            }

            VStack(spacing: BSCSpacing.xs) {
                Text("Processing Complete!")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.bscTextPrimary)

                Text("Your video has been processed and saved")
                    .font(.system(size: 14))
                    .foregroundColor(.bscTextSecondary)
            }
        }
        .padding(BSCSpacing.xl)
        .bscGlass(cornerRadius: BSCRadius.xl, padding: BSCSpacing.xl)
    }

    var hasMetadataContent: some View {
        VStack(spacing: BSCSpacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.bscBlue.opacity(0.15))
                    .frame(width: 80, height: 80)

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.bscBlue)
            }

            VStack(spacing: BSCSpacing.xs) {
                Text("Rallies Detected!")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.bscTextPrimary)

                Text("Tap below to view the detected rallies")
                    .font(.system(size: 14))
                    .foregroundColor(.bscTextSecondary)
            }
        }
        .padding(BSCSpacing.xl)
        .bscGlass(cornerRadius: BSCRadius.xl, padding: BSCSpacing.xl)
    }

    var readyContent: some View {
        VStack(spacing: BSCSpacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.bscBlue.opacity(0.15))
                    .frame(width: 80, height: 80)

                Image(systemName: "sparkles")
                    .font(.system(size: 36))
                    .foregroundColor(.bscBlue)
            }

            VStack(spacing: BSCSpacing.xs) {
                Text("Ready to Process")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.bscTextPrimary)

                Text("Choose a processing mode below")
                    .font(.system(size: 14))
                    .foregroundColor(.bscTextSecondary)
            }
        }
        .padding(BSCSpacing.xl)
        .bscGlass(cornerRadius: BSCRadius.xl, padding: BSCSpacing.xl)
    }

    var alreadyProcessedContent: some View {
        let info = viewModel.statusInfo

        return VStack(spacing: BSCSpacing.xl) {
            ZStack {
                Circle()
                    .fill(info.color.opacity(0.15))
                    .frame(width: 80, height: 80)

                Image(systemName: info.icon)
                    .font(.system(size: 40))
                    .foregroundColor(info.color)
            }

            VStack(spacing: BSCSpacing.md) {
                Text(info.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.bscTextPrimary)

                Text(info.description)
                    .font(.system(size: 14))
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)

                if let detail = info.detail {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.bscTextTertiary)
                        .padding(.horizontal, BSCSpacing.md)
                        .padding(.vertical, BSCSpacing.xs)
                        .background(Color.bscSurfaceGlass)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(BSCSpacing.xl)
        .bscGlass(cornerRadius: BSCRadius.xl, padding: BSCSpacing.xl)
    }
}

// MARK: - Action Buttons
private extension ProcessVideoView {
    @ViewBuilder
    var actionButtons: some View {
        switch viewModel.processingState {
        case .processing:
            EmptyView()
        case .pendingSave:
            EmptyView()  // No buttons while pending save
        case .complete:
            doneButton
        case .hasMetadata:
            viewRalliesButton
        case .alreadyProcessed:
            EmptyView()
        case .ready:
            processingButtons
        }
    }

    var processingButtons: some View {
        VStack(spacing: BSCSpacing.md) {
            // AI Processing - Primary
            BSCButton(title: "Start AI Processing", icon: "brain.head.profile", style: .primary, size: .large) {
                viewModel.startProcessing(isDebugMode: false)
            }

            // Debug Processing - Secondary
            BSCButton(title: "Debug Processing", icon: "ladybug", style: .secondary, size: .medium) {
                viewModel.startProcessing(isDebugMode: true)
            }

            Text("AI Processing removes dead time\nDebug Processing includes analysis overlay")
                .font(.system(size: 12))
                .foregroundColor(.bscTextTertiary)
                .multilineTextAlignment(.center)
                .padding(.top, BSCSpacing.xs)
        }
    }

    var doneButton: some View {
        BSCButton(title: "Done", icon: "checkmark", style: .primary, size: .large) {
            dismiss()
        }
    }

    var viewRalliesButton: some View {
        BSCButton(title: "View Rallies", icon: "play.fill", style: .primary, size: .large) {
            dismiss()
            viewModel.onComplete()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                viewModel.onShowPlayer?()
            }
        }
    }
}

// MARK: - Toolbar
private extension ProcessVideoView {
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if !viewModel.isProcessing {
                Button("Cancel") {
                    viewModel.cancelProcessing()
                    dismiss()
                }
                .foregroundColor(.bscTextSecondary)
            }
        }
    }
}

// MARK: - Processing Icon View
private struct ProcessingIconView: View {
    let isProcessing: Bool
    let isComplete: Bool

    @State private var isAnimating = false
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Outer glow ring
            if isProcessing {
                Circle()
                    .stroke(
                        LinearGradient.bscPrimaryGradient,
                        lineWidth: 3
                    )
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(isAnimating ? 360 : 0))
                    .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: isAnimating)
            }

            // Pulse circle
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.bscBlue.opacity(0.3), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 60
                    )
                )
                .frame(width: 120, height: 120)
                .scaleEffect(pulseScale)

            // Icon background
            Circle()
                .fill(Color.bscSurfaceGlass)
                .frame(width: 80, height: 80)
                .overlay(
                    Circle()
                        .stroke(
                            isComplete ? AnyShapeStyle(Color.bscSuccess) : AnyShapeStyle(LinearGradient.bscPrimaryGradient),
                            lineWidth: 2
                        )
                )

            // Brain icon
            Image(systemName: isComplete ? "checkmark" : "brain.head.profile")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(isComplete ? AnyShapeStyle(Color.bscSuccess) : AnyShapeStyle(LinearGradient.bscPrimaryGradient))
                .offset(y: isProcessing && !isComplete ? (isAnimating ? -4 : 0) : 0)
        }
        .onAppear {
            if isProcessing {
                isAnimating = true
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulseScale = 1.1
                }
            }
        }
        .onChange(of: isProcessing) { _, newValue in
            if newValue {
                isAnimating = true
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulseScale = 1.1
                }
            } else {
                isAnimating = false
                withAnimation(.bscBounce) {
                    pulseScale = 1.0
                }
            }
        }
    }
}

// MARK: - Processed Folder Selection Sheet
struct ProcessedFolderSelectionSheet: View {
    let mediaStore: MediaStore
    let onFolderSelected: (String) -> Void
    let onCancel: () -> Void

    @State private var selectedFolderPath: String
    @State private var folders: [FolderMetadata] = []
    @State private var showingCreateFolder = false
    @State private var newFolderName = ""

    init(mediaStore: MediaStore, onFolderSelected: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.mediaStore = mediaStore
        self.onFolderSelected = onFolderSelected
        self.onCancel = onCancel
        self._selectedFolderPath = State(initialValue: LibraryType.processed.rootPath)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header message
                    VStack(spacing: BSCSpacing.sm) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.bscSuccess)

                        Text("Processing Complete!")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.bscTextPrimary)

                        Text("Choose where to save your processed video")
                            .font(.system(size: 14))
                            .foregroundColor(.bscTextSecondary)
                    }
                    .padding(BSCSpacing.xl)

                    Divider()
                        .background(Color.bscSurfaceBorder)

                    // Folder list
                    ScrollView {
                        LazyVStack(spacing: BSCSpacing.xs) {
                            // Processed Games root option
                            folderRow(name: "Processed Games", path: LibraryType.processed.rootPath, icon: "house.fill", color: .bscTeal)

                            if !folders.isEmpty {
                                Divider()
                                    .background(Color.bscSurfaceBorder)
                                    .padding(.vertical, BSCSpacing.sm)

                                ForEach(folders, id: \.id) { folder in
                                    folderRow(name: folder.name, path: folder.path, icon: "folder.fill", color: .bscOrange)
                                }
                            }
                        }
                        .padding(BSCSpacing.lg)
                    }

                    // Action buttons
                    VStack(spacing: BSCSpacing.sm) {
                        Button {
                            onFolderSelected(selectedFolderPath)
                        } label: {
                            Text("Save to \(selectedFolderPath == LibraryType.processed.rootPath ? "Processed Games" : selectedFolderPath.components(separatedBy: "/").last ?? "Folder")")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.bscTextInverse)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, BSCSpacing.md)
                                .background(LinearGradient.bscPrimaryGradient)
                                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                        }

                        Button {
                            showingCreateFolder = true
                        } label: {
                            Text("Create New Folder")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.bscTextSecondary)
                        }
                    }
                    .padding(BSCSpacing.lg)
                    .background(Color.bscBackgroundElevated)
                }
            }
            .navigationTitle("Choose Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .foregroundColor(.bscTextSecondary)
                }
            }
            .sheet(isPresented: $showingCreateFolder) {
                createFolderSheet
            }
            .onAppear {
                loadFolders()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func folderRow(name: String, path: String, icon: String, color: Color) -> some View {
        Button {
            selectedFolderPath = path
        } label: {
            HStack(spacing: BSCSpacing.md) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 40, height: 40)

                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.bscTextPrimary)

                    if path != LibraryType.processed.rootPath {
                        // Show relative path
                        let relativePath = mediaStore.relativePath(from: path, in: .processed)
                        if !relativePath.isEmpty {
                            Text(relativePath)
                                .font(.system(size: 12))
                                .foregroundColor(.bscTextTertiary)
                        }
                    }
                }

                Spacer()

                if selectedFolderPath == path {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.bscTeal)
                }
            }
            .padding(BSCSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .fill(selectedFolderPath == path ? Color.bscTeal.opacity(0.1) : Color.bscSurfaceGlass)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .stroke(selectedFolderPath == path ? Color.bscTeal.opacity(0.3) : Color.bscSurfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var createFolderSheet: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                VStack(spacing: BSCSpacing.xl) {
                    VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                        Text("Folder Name")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.bscTextSecondary)
                            .textCase(.uppercase)

                        TextField("Enter folder name", text: $newFolderName)
                            .textFieldStyle(.roundedBorder)
                    }

                    Spacer()
                }
                .padding(BSCSpacing.xl)
            }
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        showingCreateFolder = false
                        newFolderName = ""
                    }
                    .foregroundColor(.bscTextSecondary)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        createFolder()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(.bscTeal)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func loadFolders() {
        folders = getAllFoldersRecursively()
    }

    private func getAllFoldersRecursively() -> [FolderMetadata] {
        // Get all folders in the Processed Games library
        var allFolders: [FolderMetadata] = []
        var foldersToProcess: [String] = [LibraryType.processed.rootPath]

        while !foldersToProcess.isEmpty {
            let currentPath = foldersToProcess.removeFirst()
            let foundFolders = mediaStore.getFolders(in: currentPath)

            allFolders.append(contentsOf: foundFolders)
            foldersToProcess.append(contentsOf: foundFolders.map { $0.path })
        }

        return allFolders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func createFolder() {
        let sanitizedName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedName.isEmpty else { return }

        // Create folder in Processed Games library root
        let success = mediaStore.createFolder(name: sanitizedName, parentPath: LibraryType.processed.rootPath)

        if success {
            selectedFolderPath = "\(LibraryType.processed.rootPath)/\(sanitizedName)"
            loadFolders()
        }

        showingCreateFolder = false
        newFolderName = ""
    }
}

// MARK: - Preview
#Preview("ProcessVideoView - Ready") {
    ProcessVideoView(
        videoURL: URL(fileURLWithPath: "/test.mp4"),
        mediaStore: MediaStore(),
        folderPath: "",
        onComplete: {},
        onShowPlayer: nil
    )
}
