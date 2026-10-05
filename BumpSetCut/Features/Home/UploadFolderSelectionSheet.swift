import SwiftUI

// MARK: - Upload Folder Selection Sheet
struct UploadFolderSelectionSheet: View {
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
        // Start with library root selected
        self._selectedFolderPath = State(initialValue: LibraryType.saved.rootPath)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Folder list
                    ScrollView {
                        LazyVStack(spacing: BSCSpacing.xs) {
                            // Library root option
                            folderRow(name: "Library", path: LibraryType.saved.rootPath, icon: "house.fill", color: .bscBlue)

                            if !folders.isEmpty {
                                Divider()
                                    .background(Color.bscSurfaceBorder)
                                    .padding(.vertical, BSCSpacing.sm)

                                ForEach(folders, id: \.id) { folder in
                                    folderRow(name: folder.name, path: folder.path, icon: "folder.fill", color: .bscPrimary)
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
                            Text("Upload to \(selectedFolderPath == LibraryType.saved.rootPath ? "Library" : selectedFolderPath.components(separatedBy: "/").last ?? "Folder")")
                                .bscFont(size: 16, weight: .bold)
                                .foregroundColor(.bscOnPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, BSCSpacing.md)
                                .background(LinearGradient.bscPrimaryGradient)
                                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                        }

                        Button {
                            showingCreateFolder = true
                        } label: {
                            Text("Create New Folder")
                                .bscFont(size: 14, weight: .medium)
                                .foregroundColor(.bscTextSecondary)
                                .frame(minHeight: BSCTouchTarget.standard)
                                .contentShape(Rectangle())
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
                        .bscFont(size: 18, weight: .medium)
                        .foregroundColor(color)
                }

                VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                    Text(name)
                        .bscFont(size: 16, weight: .medium)
                        .foregroundColor(.bscTextPrimary)

                    if !path.isEmpty {
                        Text(path)
                            .bscFont(size: 12)
                            .foregroundColor(.bscTextSecondary)
                    }
                }

                Spacer()

                if selectedFolderPath == path {
                    Image(systemName: "checkmark.circle.fill")
                        .bscFont(size: 22)
                        .foregroundColor(.bscPrimary)
                }
            }
            .padding(BSCSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .fill(selectedFolderPath == path ? Color.bscPrimary.opacity(0.1) : Color.bscSurfaceGlass)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .stroke(selectedFolderPath == path ? Color.bscPrimary.opacity(0.3) : Color.bscSurfaceBorder, lineWidth: 1)
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
                            .bscFont(size: 14, weight: .semibold)
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
                    .foregroundColor(.bscPrimary)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func loadFolders() {
        folders = getAllFoldersRecursively()
    }

    private func getAllFoldersRecursively() -> [FolderMetadata] {
        // Get all folders in the Saved Games library
        var allFolders: [FolderMetadata] = []
        var foldersToProcess: [String] = [LibraryType.saved.rootPath]

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

        // Create folder in Saved Games library root
        let success = mediaStore.createFolder(name: sanitizedName, parentPath: LibraryType.saved.rootPath)

        if success {
            selectedFolderPath = "\(LibraryType.saved.rootPath)/\(sanitizedName)"
            loadFolders()
        }

        showingCreateFolder = false
        newFolderName = ""
    }
}
