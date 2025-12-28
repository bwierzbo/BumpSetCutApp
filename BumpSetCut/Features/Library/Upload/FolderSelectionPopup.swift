//
//  FolderSelectionPopup.swift
//  BumpSetCut
//
//  Created by Claude on 9/1/25.
//

import SwiftUI
import MijickPopups

struct FolderSelectionPopup: BottomPopup {
    let mediaStore: MediaStore
    let currentFolderPath: String
    let onFolderSelected: (String) -> Void
    let onCancel: () -> Void

    @State private var selectedFolderPath: String
    @State private var availableFolders: [FolderMetadata] = []
    @State private var recentFolders: [FolderMetadata] = []
    @State private var searchText: String = ""
    @State private var showingCreateFolder = false
    @State private var newFolderName = ""

    init(mediaStore: MediaStore, currentFolderPath: String, onFolderSelected: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.mediaStore = mediaStore
        self.currentFolderPath = currentFolderPath
        self.onFolderSelected = onFolderSelected
        self.onCancel = onCancel
        self._selectedFolderPath = State(initialValue: currentFolderPath)
    }

    func configurePopup(config: BottomPopupConfig) -> BottomPopupConfig {
        config
            .backgroundColor(Color.bscBackground)
            .cornerRadius(BSCRadius.xl)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                    Text("Choose Upload Destination")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.bscTextPrimary)

                    Text("Select where to save your video")
                        .font(.system(size: 13))
                        .foregroundColor(.bscTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(BSCSpacing.lg)

                // Search
                FolderSearchBar(text: $searchText, placeholder: "Search folders")
                    .padding(.horizontal, BSCSpacing.lg)

                // Content
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Current folder option (Library root)
                        BSCFolderOptionView(
                            folder: nil,
                            isSelected: selectedFolderPath.isEmpty,
                            isCurrentFolder: currentFolderPath.isEmpty
                        ) {
                            selectedFolderPath = ""
                        }

                        Divider()
                            .background(Color.bscSurfaceBorder)
                            .padding(.horizontal, BSCSpacing.lg)

                        // Recent Folders Section
                        if !recentFolders.isEmpty {
                            Section {
                                ForEach(filteredRecentFolders, id: \.id) { folder in
                                    BSCFolderOptionView(
                                        folder: folder,
                                        isSelected: selectedFolderPath == folder.path,
                                        isCurrentFolder: currentFolderPath == folder.path
                                    ) {
                                        selectedFolderPath = folder.path
                                    }
                                }
                            } header: {
                                BSCSectionHeaderView(title: "Recent Folders")
                            }

                            Divider()
                                .background(Color.bscSurfaceBorder)
                                .padding(.horizontal, BSCSpacing.lg)
                        }

                        // All Folders Section
                        Section {
                            ForEach(filteredFolders, id: \.id) { folder in
                                BSCFolderOptionView(
                                    folder: folder,
                                    isSelected: selectedFolderPath == folder.path,
                                    isCurrentFolder: currentFolderPath == folder.path
                                ) {
                                    selectedFolderPath = folder.path
                                }
                            }
                        } header: {
                            BSCSectionHeaderView(title: "All Folders")
                        }
                    }
                }

                // Actions
                VStack(spacing: BSCSpacing.md) {
                    HStack(spacing: BSCSpacing.md) {
                        Button {
                            showingCreateFolder = true
                        } label: {
                            Text("New Folder")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.bscTextPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(BSCSpacing.md)
                                .background(Color.bscSurfaceGlass)
                                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg))
                                .overlay(
                                    RoundedRectangle(cornerRadius: BSCRadius.lg)
                                        .stroke(Color.bscSurfaceBorder, lineWidth: 1)
                                )
                        }

                        Button {
                            onCancel()
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.bscTextSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(BSCSpacing.md)
                                .background(Color.bscSurfaceGlass)
                                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg))
                                .overlay(
                                    RoundedRectangle(cornerRadius: BSCRadius.lg)
                                        .stroke(Color.bscSurfaceBorder, lineWidth: 1)
                                )
                        }

                        Button {
                            onFolderSelected(selectedFolderPath)
                        } label: {
                            Text("Select")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(BSCSpacing.md)
                                .background(Color.bscBlue)
                                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg))
                        }
                    }
                }
                .padding(BSCSpacing.lg)
                .background(Color.bscBackgroundElevated)
            }
            .background(Color.bscBackground)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingCreateFolder) {
            createNewFolderSheet()
        }
        .onAppear {
            loadFolders()
        }
    }

    private var filteredFolders: [FolderMetadata] {
        let allFolders = availableFolders

        if searchText.isEmpty {
            return allFolders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        return allFolders
            .filter { $0.name.localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filteredRecentFolders: [FolderMetadata] {
        if searchText.isEmpty {
            return recentFolders
        }

        return recentFolders.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func loadFolders() {
        // Get all folders from all levels
        availableFolders = getAllFoldersRecursively()

        // Get recent folders (folders with recent activity)
        recentFolders = availableFolders
            .sorted { $0.modifiedDate > $1.modifiedDate }
            .prefix(3)
            .map { $0 }
    }

    private func getAllFoldersRecursively() -> [FolderMetadata] {
        var allFolders: [FolderMetadata] = []
        var foldersToProcess: [String] = [""] // Start with root

        while !foldersToProcess.isEmpty {
            let currentPath = foldersToProcess.removeFirst()
            let folders = mediaStore.getFolders(in: currentPath)

            allFolders.append(contentsOf: folders)
            foldersToProcess.append(contentsOf: folders.map { $0.path })
        }

        return allFolders
    }

    private func createNewFolderSheet() -> some View {
        NavigationView {
            VStack(spacing: BSCSpacing.xl) {
                VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                    Text("Folder Name")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.bscTextSecondary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    TextField("Enter folder name", text: $newFolderName)
                        .textFieldStyle(.roundedBorder)
                }

                Spacer()
            }
            .padding(BSCSpacing.xl)
            .background(Color.bscBackground)
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
                        createNewFolder()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(.bscOrange)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func createNewFolder() {
        let sanitizedName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedName.isEmpty else { return }

        let success = mediaStore.createFolder(name: sanitizedName, parentPath: selectedFolderPath)

        if success {
            let newFolderPath = selectedFolderPath.isEmpty ? sanitizedName : "\(selectedFolderPath)/\(sanitizedName)"
            selectedFolderPath = newFolderPath
            loadFolders()
        }

        showingCreateFolder = false
        newFolderName = ""
    }
}

// MARK: - Supporting Views

private struct BSCFolderOptionView: View {
    let folder: FolderMetadata?
    let isSelected: Bool
    let isCurrentFolder: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: BSCSpacing.md) {
                // Folder icon with gradient
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [iconColor.opacity(0.2), Color.clear],
                                center: .center,
                                startRadius: 8,
                                endRadius: 20
                            )
                        )
                        .frame(width: 40, height: 40)

                    Image(systemName: folder == nil ? "house.fill" : "folder.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [iconColor, iconColor.opacity(0.7)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                    Text(folder?.name ?? "Library")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.bscTextPrimary)

                    HStack(spacing: BSCSpacing.sm) {
                        Text(folder?.path.isEmpty == false ? folder!.path : "Root folder")
                            .font(.system(size: 12))
                            .foregroundColor(.bscTextSecondary)

                        if isCurrentFolder {
                            Text("• Current")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.bscBlue)
                        }
                    }

                    if let folder = folder {
                        HStack(spacing: BSCSpacing.xxs) {
                            Image(systemName: "video.fill")
                                .font(.system(size: 10))
                            Text("\(folder.videoCount)")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(folder.videoCount > 0 ? .bscBlue : .bscTextTertiary)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.bscBlue)
                }
            }
            .padding(BSCSpacing.md)
            .background(isSelected ? Color.bscBlue.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, BSCSpacing.sm)
    }

    private var iconColor: Color {
        folder == nil ? .bscBlue : .bscOrange
    }
}

private struct BSCSectionHeaderView: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.bscTextSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
        }
        .padding(.horizontal, BSCSpacing.lg)
        .padding(.vertical, BSCSpacing.sm)
    }
}

private struct FolderSearchBar: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: BSCSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(.bscTextTertiary)

            TextField(placeholder, text: $text)
                .font(.system(size: 14))
                .foregroundColor(.bscTextPrimary)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.bscTextTertiary)
                }
            }
        }
        .padding(BSCSpacing.sm)
        .background(Color.bscSurfaceGlass)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: BSCRadius.md)
                .stroke(Color.bscSurfaceBorder, lineWidth: 1)
        )
    }
}

#Preview {
    FolderSelectionPopup(
        mediaStore: MediaStore(),
        currentFolderPath: "",
        onFolderSelected: { path in print("Selected: \(path)") },
        onCancel: { print("Cancelled") }
    )
}
