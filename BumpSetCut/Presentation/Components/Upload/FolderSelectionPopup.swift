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
            .backgroundColor(Color(.systemBackground))
            .cornerRadius(16)
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose Upload Destination")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Select where to save your video")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                
                // Search
                SearchBar(text: $searchText, placeholder: "Search folders")
                    .padding(.horizontal)
                
                // Content
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Current folder option (Library root)
                        FolderOptionView(
                            folder: nil,
                            isSelected: selectedFolderPath.isEmpty,
                            isCurrentFolder: currentFolderPath.isEmpty
                        ) {
                            selectedFolderPath = ""
                        }
                        
                        Divider()
                            .padding(.horizontal)
                        
                        // Recent Folders Section
                        if !recentFolders.isEmpty {
                            Section {
                                ForEach(filteredRecentFolders, id: \.id) { folder in
                                    FolderOptionView(
                                        folder: folder,
                                        isSelected: selectedFolderPath == folder.path,
                                        isCurrentFolder: currentFolderPath == folder.path
                                    ) {
                                        selectedFolderPath = folder.path
                                    }
                                }
                            } header: {
                                SectionHeaderView(title: "Recent Folders")
                            }
                            
                            Divider()
                                .padding(.horizontal)
                        }
                        
                        // All Folders Section
                        Section {
                            ForEach(filteredFolders, id: \.id) { folder in
                                FolderOptionView(
                                    folder: folder,
                                    isSelected: selectedFolderPath == folder.path,
                                    isCurrentFolder: currentFolderPath == folder.path
                                ) {
                                    selectedFolderPath = folder.path
                                }
                            }
                        } header: {
                            SectionHeaderView(title: "All Folders")
                        }
                    }
                }
                
                // Actions
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Button("New Folder") {
                            showingCreateFolder = true
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray5))
                        .foregroundColor(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        Button("Cancel") {
                            onCancel()
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray4))
                        .foregroundColor(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        Button("Select") {
                            onFolderSelected(selectedFolderPath)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding()
                .background(Color(.systemBackground))
            }
        }
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
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Folder Name")
                        .font(.headline)
                    
                    TextField("Enter folder name", text: $newFolderName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        showingCreateFolder = false
                        newFolderName = ""
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        createNewFolder()
                    }
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
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

struct FolderOptionView: View {
    let folder: FolderMetadata?
    let isSelected: Bool
    let isCurrentFolder: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: folder == nil ? "house.fill" : "folder.fill")
                    .foregroundColor(folder == nil ? .blue : .orange)
                    .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder?.name ?? "Library")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    HStack {
                        Text(folder?.path.isEmpty == false ? folder!.path : "Root folder")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if isCurrentFolder {
                            Text("• Current")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                    
                    if let folder = folder {
                        Text("\(folder.videoCount) videos")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                }
            }
            .padding()
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
    }
}

struct SectionHeaderView: View {
    let title: String
    
    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

struct SearchBar: View {
    @Binding var text: String
    let placeholder: String
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
            
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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