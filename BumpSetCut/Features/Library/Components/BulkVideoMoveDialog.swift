//
//  BulkVideoMoveDialog.swift
//  BumpSetCut
//
//  Created by Claude on 9/1/25.
//

import SwiftUI

struct BulkVideoMoveDialog: View {
    let mediaStore: MediaStore
    let videoFileNames: [String]
    let currentFolder: String
    let onMove: (String) -> Void
    let onCancel: () -> Void

    @State private var selectedFolderPath: String = ""
    @State private var folders: [FolderMetadata] = []
    @State private var isLoading = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                    Text("Move \(videoFileNames.count) Videos")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.bscTextPrimary)

                    Text("Select destination folder for all selected videos")
                        .font(.system(size: 13))
                        .foregroundColor(.bscTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(BSCSpacing.lg)

                // Current location
                if !currentFolder.isEmpty {
                    VStack(alignment: .leading, spacing: BSCSpacing.xs) {
                        Text("Current Location:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.bscTextSecondary)
                            .textCase(.uppercase)
                            .tracking(0.5)

                        Text(currentFolder.isEmpty ? "Root" : currentFolder)
                            .font(.system(size: 14))
                            .foregroundColor(.bscTextPrimary)
                            .padding(.horizontal, BSCSpacing.md)
                            .padding(.vertical, BSCSpacing.sm)
                            .background(Color.bscSurfaceGlass)
                            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm))
                            .overlay(
                                RoundedRectangle(cornerRadius: BSCRadius.sm)
                                    .stroke(Color.bscSurfaceBorder, lineWidth: 1)
                            )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, BSCSpacing.lg)
                }

                // Video list preview
                VStack(alignment: .leading, spacing: BSCSpacing.xs) {
                    Text("Videos to move:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.bscTextSecondary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: BSCSpacing.sm) {
                            ForEach(videoFileNames.prefix(5), id: \.self) { fileName in
                                Text(URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.bscTextSecondary)
                                    .padding(.horizontal, BSCSpacing.sm)
                                    .padding(.vertical, BSCSpacing.xs)
                                    .background(Color.bscSurfaceGlass)
                                    .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: BSCRadius.sm)
                                            .stroke(Color.bscSurfaceBorder, lineWidth: 1)
                                    )
                            }

                            if videoFileNames.count > 5 {
                                Text("+\(videoFileNames.count - 5) more")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.bscTextTertiary)
                                    .padding(.horizontal, BSCSpacing.sm)
                                    .padding(.vertical, BSCSpacing.xs)
                                    .background(Color.bscBackgroundElevated)
                                    .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm))
                            }
                        }
                        .padding(.horizontal, BSCSpacing.lg)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, BSCSpacing.lg)
                .padding(.top, BSCSpacing.sm)

                Divider()
                    .background(Color.bscSurfaceBorder)
                    .padding(.vertical, BSCSpacing.sm)

                // Folder list
                if isLoading {
                    VStack(spacing: BSCSpacing.md) {
                        ProgressView()
                            .tint(.bscBlue)
                            .padding()
                        Text("Loading folders...")
                            .font(.system(size: 13))
                            .foregroundColor(.bscTextSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: BSCSpacing.xs) {
                            // Root folder option
                            BulkFolderRowView(
                                icon: "house.fill",
                                iconColor: .bscBlue,
                                name: "Root",
                                subtitle: "Main folder",
                                isSelected: selectedFolderPath.isEmpty,
                                isDisabled: false
                            ) {
                                selectedFolderPath = ""
                            }

                            // Other folders
                            ForEach(folders, id: \.id) { folder in
                                BulkFolderRowView(
                                    icon: "folder.fill",
                                    iconColor: .bscOrange,
                                    name: folder.name,
                                    subtitle: "\(folder.videoCount) videos",
                                    isSelected: selectedFolderPath == folder.path,
                                    isDisabled: folder.path == currentFolder
                                ) {
                                    selectedFolderPath = folder.path
                                }
                            }
                        }
                        .padding(.horizontal, BSCSpacing.lg)
                    }
                }

                // Action buttons
                HStack(spacing: BSCSpacing.md) {
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
                        onMove(selectedFolderPath)
                    } label: {
                        Text("Move \(videoFileNames.count) Videos")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(BSCSpacing.md)
                            .background(canMoveToSelectedFolder ? Color.bscBlue : Color.bscSurfaceGlass)
                            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg))
                    }
                    .disabled(!canMoveToSelectedFolder)
                }
                .padding(BSCSpacing.lg)
                .background(Color.bscBackgroundElevated)
            }
            .background(Color.bscBackground)
        }
        .onAppear {
            loadFolders()
            selectedFolderPath = currentFolder
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var canMoveToSelectedFolder: Bool {
        selectedFolderPath != currentFolder && !isLoading
    }

    private func loadFolders() {
        isLoading = true

        Task {
            // Get all folders from MediaStore
            let rootFolders = mediaStore.getFolders(in: "")
            var allFolders = rootFolders

            // Recursively get subfolders
            for folder in rootFolders {
                allFolders.append(contentsOf: getAllSubfolders(in: folder.path))
            }

            await MainActor.run {
                folders = allFolders.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
                isLoading = false
            }
        }
    }

    private func getAllSubfolders(in path: String) -> [FolderMetadata] {
        let directFolders = mediaStore.getFolders(in: path)
        var allFolders = directFolders

        for folder in directFolders {
            allFolders.append(contentsOf: getAllSubfolders(in: folder.path))
        }

        return allFolders
    }
}

// MARK: - Bulk Folder Row View

private struct BulkFolderRowView: View {
    let icon: String
    let iconColor: Color
    let name: String
    let subtitle: String
    let isSelected: Bool
    let isDisabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: BSCSpacing.md) {
                // Icon with gradient
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [iconColor.opacity(0.2), Color.clear],
                                center: .center,
                                startRadius: 6,
                                endRadius: 16
                            )
                        )
                        .frame(width: 36, height: 36)

                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [iconColor, iconColor.opacity(0.7)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                    Text(name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.bscTextPrimary)

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.bscTextSecondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.bscBlue)
                }
            }
            .padding(BSCSpacing.md)
            .background(isSelected ? Color.bscBlue.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.md)
                    .stroke(isSelected ? Color.bscBlue.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .opacity(isDisabled ? 0.5 : 1.0)
        .disabled(isDisabled)
    }
}

#Preview {
    BulkVideoMoveDialog(
        mediaStore: MediaStore(),
        videoFileNames: ["video1.mp4", "video2.mov", "video3.mp4"],
        currentFolder: "Folder1",
        onMove: { folderPath in
            print("Move to: \(folderPath)")
        },
        onCancel: {
            print("Cancelled")
        }
    )
}
