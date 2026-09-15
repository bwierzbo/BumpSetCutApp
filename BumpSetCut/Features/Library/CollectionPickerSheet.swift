//
//  CollectionPickerSheet.swift
//  BumpSetCut
//
//  Reusable folder/collection picker: lists the depth-1 folders of a library
//  with the library root as the first option, supports creating a folder
//  in place, and reports the chosen folder NAME (nil = library root).
//  Generalized from the upload destination sheet in HomeView.
//

import SwiftUI

struct CollectionPickerSheet: View {
    let mediaStore: MediaStore
    let libraryType: LibraryType
    let title: String
    let rootLabel: String
    let confirmLabel: String
    let onSelect: (String?) -> Void
    let onCancel: () -> Void

    /// Selected collection name; nil = library root.
    @State private var selectedName: String?
    @State private var folders: [FolderMetadata] = []
    @State private var showingCreateFolder = false
    @State private var newFolderName = ""

    init(
        mediaStore: MediaStore,
        libraryType: LibraryType,
        title: String,
        rootLabel: String,
        confirmLabel: String,
        initialSelection: String? = nil,
        onSelect: @escaping (String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mediaStore = mediaStore
        self.libraryType = libraryType
        self.title = title
        self.rootLabel = rootLabel
        self.confirmLabel = confirmLabel
        self.onSelect = onSelect
        self.onCancel = onCancel
        self._selectedName = State(initialValue: initialSelection)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: BSCSpacing.xs) {
                            folderRow(name: nil, label: rootLabel, icon: "star.fill", color: .bscBlue)

                            if !folders.isEmpty {
                                Divider()
                                    .background(Color.bscSurfaceBorder)
                                    .padding(.vertical, BSCSpacing.sm)

                                ForEach(folders, id: \.id) { folder in
                                    folderRow(name: folder.name, label: folder.name, icon: "folder.fill", color: .bscPrimary)
                                }
                            }
                        }
                        .padding(BSCSpacing.lg)
                    }

                    VStack(spacing: BSCSpacing.sm) {
                        Button {
                            onSelect(selectedName)
                        } label: {
                            Text("\(confirmLabel) \(selectedName ?? rootLabel)")
                                .bscFont(size: 16, weight: .bold)
                                .foregroundColor(.bscOnPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, BSCSpacing.md)
                                .background(LinearGradient.bscPrimaryGradient)
                                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                        }
                        .accessibilityIdentifier(AccessibilityID.CollectionPicker.confirmButton)

                        Button {
                            showingCreateFolder = true
                        } label: {
                            Text("Create New Folder")
                                .bscFont(size: 14, weight: .medium)
                                .foregroundColor(.bscTextSecondary)
                                .frame(minHeight: BSCTouchTarget.standard)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier(AccessibilityID.CollectionPicker.createFolderButton)
                    }
                    .padding(BSCSpacing.lg)
                    .background(Color.bscBackgroundElevated)
                }
            }
            .navigationTitle(title)
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
        .accessibilityIdentifier(AccessibilityID.CollectionPicker.sheet)
    }

    private func folderRow(name: String?, label: String, icon: String, color: Color) -> some View {
        let isSelected = selectedName == name
        return Button {
            selectedName = name
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

                Text(label)
                    .bscFont(size: 16, weight: .medium)
                    .foregroundColor(.bscTextPrimary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .bscFont(size: 22)
                        .foregroundColor(.bscPrimary)
                }
            }
            .padding(BSCSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .fill(isSelected ? Color.bscPrimary.opacity(0.1) : Color.bscSurfaceGlass)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .stroke(isSelected ? Color.bscPrimary.opacity(0.3) : Color.bscSurfaceBorder, lineWidth: 1)
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
                            .accessibilityIdentifier(AccessibilityID.CollectionPicker.newFolderField)
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
        // Depth-1 children of the library root only (collections are flat).
        let rootPath = libraryType.rootPath
        folders = mediaStore.getAllFolders(in: libraryType)
            .filter { $0.path == "\(rootPath)/\($0.name)" }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func createFolder() {
        let sanitizedName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedName.isEmpty else { return }

        if mediaStore.createFolder(name: sanitizedName, parentPath: libraryType.rootPath) {
            selectedName = sanitizedName
            loadFolders()
        }

        showingCreateFolder = false
        newFolderName = ""
    }
}
