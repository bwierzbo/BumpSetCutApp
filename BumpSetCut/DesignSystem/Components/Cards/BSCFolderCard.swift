import SwiftUI

// MARK: - BSCFolderCard
/// Unified folder card with glass effects supporting both list and grid modes
struct BSCFolderCard: View {
    // MARK: - Display Mode
    enum DisplayMode {
        case list
        case grid
    }

    // MARK: - Properties
    let folder: FolderMetadata
    let displayMode: DisplayMode
    /// Highlights the card as an active drop zone while a video is dragged over it.
    var isDropTargeted: Bool = false
    let onTap: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    private var cornerRadius: CGFloat {
        displayMode == .list ? BSCRadius.md : BSCRadius.xl
    }

    @State private var showingRenameDialog = false
    @State private var showingDeleteConfirmation = false
    @State private var newName = ""
    @State private var isPressed = false

    // MARK: - Body
    var body: some View {
        Group {
            switch displayMode {
            case .list:
                listContent
            case .grid:
                gridContent
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.bscPrimary, lineWidth: 2.5)
                .opacity(isDropTargeted ? 1 : 0)
        )
        .scaleEffect(isDropTargeted ? 1.04 : (isPressed ? 0.97 : 1.0))
        .animation(.bscBounce, value: isPressed)
        .animation(.bscQuick, value: isDropTargeted)
        .onLongPressGesture(minimumDuration: 0.1, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
        .contextMenu {
            contextMenuContent
        }
        .alert("Rename Folder", isPresented: $showingRenameDialog) {
            TextField("Folder name", text: $newName)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                onRename(newName)
            }
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter a new name for the folder.")
        }
        .alert("Delete Folder", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                onDelete()
            }
        } message: {
            Text(folder.videoCount > 0 ?
                 "This folder contains \(folder.videoCount) videos. They will be moved to the parent folder." :
                 "Are you sure you want to delete this folder?")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.name) folder, \(folder.videoCount) videos")
        .accessibilityHint("Double tap to open, long press for options")
    }

    // MARK: - List Content
    private var listContent: some View {
        HStack(spacing: BSCSpacing.lg) {
            // Folder icon
            folderIcon(size: 56)

            // Folder info
            listInfoView

            Spacer()

            // Menu button
            menuButton

            // Quick open button
            quickOpenButton
        }
        .padding(.vertical, BSCSpacing.sm)
        .padding(.trailing, BSCSpacing.md)
        .bscInteractive(isSelected: false, cornerRadius: BSCRadius.md)
    }

    // MARK: - Grid Content
    private var gridContent: some View {
        VStack(spacing: BSCSpacing.md) {
            // Folder icon with overlay
            ZStack {
                folderIcon(size: 64)

                // Chevron indicator
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Circle()
                            .fill(Color.bscMediaScrim)
                            .frame(width: BSCIconSize.lg, height: BSCIconSize.lg)
                            .overlay(
                                Image(systemName: "chevron.right")
                                    .bscFont(size: 10, weight: .bold)
                                    .foregroundColor(.bscOnMedia)
                            )
                            .accessibilityHidden(true)
                    }
                }
                .padding(BSCSpacing.xs)
            }
            .frame(width: 72, height: 72)

            // Folder info
            gridInfoView

            Spacer(minLength: 0)
        }
        .frame(height: 160)
        .frame(maxWidth: .infinity)
        .padding(BSCSpacing.lg)
        .overlay(alignment: .topTrailing) {
            menuButton
        }
        .bscInteractive(isSelected: false, cornerRadius: BSCRadius.xl)
    }

    // MARK: - Folder Icon
    private func folderIcon(size: CGFloat) -> some View {
        ZStack {
            // Outer glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.bscPrimary.opacity(0.2), Color.clear],
                        center: .center,
                        startRadius: size * 0.3,
                        endRadius: size * 0.6
                    )
                )
                .frame(width: size * 1.2, height: size * 1.2)

            // Main circle
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.bscPrimary.opacity(0.2), Color.bscPrimary.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .overlay(
                    Circle()
                        .stroke(Color.bscPrimary.opacity(0.3), lineWidth: 1)
                )

            // Icon
            Image(systemName: "folder.fill")
                .font(.system(size: size * 0.45, weight: .medium))
                .accessibilityHidden(true)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.bscPrimary, Color.bscPrimary.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    // MARK: - List Info View
    private var listInfoView: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
            // Title
            Text(folder.name)
                .bscFont(size: 16, weight: .semibold)
                .foregroundColor(.bscTextPrimary)
                .lineLimit(1)

            // Content badge
            contentBadge

            Spacer(minLength: BSCSpacing.xxs)

            // Metadata row
            HStack {
                dateText
                Spacer()
            }
        }
        .frame(height: 56, alignment: .top)
    }

    // MARK: - Grid Info View
    private var gridInfoView: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.xs) {
            // Title
            Text(folder.name)
                .bscFont(size: 14, weight: .semibold)
                .foregroundColor(.bscTextPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // Content badge
            HStack {
                Spacer()
                contentBadge
                Spacer()
            }

            // Date
            HStack {
                Spacer()
                dateText
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60, alignment: .top)
    }

    // MARK: - Content Badge
    private var contentBadge: some View {
        HStack(spacing: BSCSpacing.sm) {
            // Video count
            HStack(spacing: BSCSpacing.xxs) {
                Image(systemName: "video.fill")
                    .bscFont(size: 10)
                    .accessibilityHidden(true)
                Text("\(folder.videoCount)")
                    .bscFont(size: 11, weight: .medium)
            }
            .foregroundColor(folder.videoCount > 0 ? .bscPrimary : .bscTextTertiary)

            // Subfolder count
            if folder.subfolderCount > 0 {
                HStack(spacing: BSCSpacing.xxs) {
                    Image(systemName: "folder.fill")
                        .bscFont(size: 10)
                        .accessibilityHidden(true)
                    Text("\(folder.subfolderCount)")
                        .bscFont(size: 11, weight: .medium)
                }
                .foregroundColor(.bscTextSecondary)
            }
        }
    }

    // MARK: - Date Text
    private var dateText: some View {
        Text(folder.modifiedDate.formatted(date: .abbreviated, time: .omitted))
            .font(.caption2)
            .foregroundColor(.bscTextTertiary)
    }

    // MARK: - Action Buttons
    private var menuButton: some View {
        Menu {
            contextMenuContent
        } label: {
            Image(systemName: "ellipsis")
                .bscFont(size: 16, weight: .medium)
                .foregroundColor(.bscTextSecondary)
                .frame(width: 32, height: 32)
                .background(Color.bscSurfaceGlass)
                .clipShape(Circle())
                .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Folder options")
    }

    private var quickOpenButton: some View {
        Button {
            onTap()
        } label: {
            Image(systemName: "arrow.right.circle.fill")
                .bscFont(size: 20)
                .foregroundColor(.bscPrimary)
                .frame(width: 32, height: 32)
                .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Open folder")
    }

    // MARK: - Context Menu
    @ViewBuilder
    private var contextMenuContent: some View {
        Button {
            onTap()
        } label: {
            Label("Open", systemImage: "folder")
        }

        Divider()

        Button {
            newName = folder.name
            showingRenameDialog = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button(role: .destructive) {
            showingDeleteConfirmation = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

// MARK: - Preview
#Preview("BSCFolderCard") {
    let folder = FolderMetadata(
        name: "Game Footage",
        path: "Game Footage",
        parentPath: nil,
        createdDate: Date(),
        modifiedDate: Date(),
        videoCount: 12,
        subfolderCount: 2
    )

    let emptyFolder = FolderMetadata(
        name: "Empty Folder",
        path: "Empty Folder",
        parentPath: nil,
        createdDate: Date(),
        modifiedDate: Date(),
        videoCount: 0,
        subfolderCount: 0
    )

    ScrollView {
        VStack(spacing: BSCSpacing.lg) {
            Text("List Mode")
                .font(.headline)
                .foregroundColor(.bscTextPrimary)

            BSCFolderCard(
                folder: folder,
                displayMode: .list,
                onTap: {},
                onRename: { _ in },
                onDelete: {}
            )

            BSCFolderCard(
                folder: emptyFolder,
                displayMode: .list,
                onTap: {},
                onRename: { _ in },
                onDelete: {}
            )

            Text("Grid Mode")
                .font(.headline)
                .foregroundColor(.bscTextPrimary)

            HStack(spacing: BSCSpacing.md) {
                BSCFolderCard(
                    folder: folder,
                    displayMode: .grid,
                    onTap: {},
                    onRename: { _ in },
                    onDelete: {}
                )

                BSCFolderCard(
                    folder: emptyFolder,
                    displayMode: .grid,
                    onTap: {},
                    onRename: { _ in },
                    onDelete: {}
                )
            }
        }
        .padding()
    }
    .background(Color.bscBackground)
}
