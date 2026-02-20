//
//  AdvancedSearchView.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 9/1/25.
//

import SwiftUI

struct AdvancedSearchView: View {
    @ObservedObject var searchViewModel: SearchViewModel
    let onNavigateToFolder: (String) -> Void
    let onNavigateToVideo: (VideoMetadata) -> Void
    
    @State private var showingSaveSearchDialog = false
    @State private var saveSearchName = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Search bar and controls
            searchHeaderView
            
            // Quick filters
            quickFiltersView
            
            // Search results
            searchResultsView
        }
        .sheet(isPresented: $showingSaveSearchDialog) {
            saveSearchSheet
        }
    }
    
    // MARK: - Search Header
    
    private var searchHeaderView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Main search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.bscTextSecondary)

                    TextField("Search videos and folders...", text: $searchViewModel.searchText)
                        .textFieldStyle(PlainTextFieldStyle())

                    if !searchViewModel.searchText.isEmpty {
                        Button {
                            searchViewModel.clearSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.bscTextSecondary)
                        }
                    }
                }
                .padding(.horizontal, BSCSpacing.md)
                .padding(.vertical, BSCSpacing.sm)
                .background(Color.bscSurfaceGlass)
                .cornerRadius(10)
                
                // Filter toggle
                Button {
                    searchViewModel.isShowingFilters.toggle()
                } label: {
                    Image(systemName: searchViewModel.isShowingFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .foregroundColor(.bscPrimary)
                        .font(.title2)
                }
            }
            
            // Filter and sort controls (when expanded)
            if searchViewModel.isShowingFilters {
                filterControlsView
            }
            
            // Action buttons
            if !searchViewModel.searchText.isEmpty {
                actionButtonsView
            }
        }
        .padding(.horizontal, BSCSpacing.lg)
        .padding(.vertical, BSCSpacing.md)
        .background(Color.bscBackgroundMuted)
    }
    
    private var filterControlsView: some View {
        VStack(spacing: 12) {
            // Sort and file type filters
            HStack(spacing: 12) {
                // Sort picker
                Menu {
                    Picker("Sort", selection: $searchViewModel.sortOption) {
                        ForEach(AdvancedSortOption.allCases, id: \.self) { option in
                            Label(option.rawValue, systemImage: sortIcon(for: option))
                                .tag(option)
                        }
                    }
                } label: {
                    HStack {
                        Text("Sort: \(searchViewModel.sortOption.rawValue)")
                            .font(.caption)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundColor(.bscPrimary)
                    .padding(.horizontal, BSCSpacing.sm)
                    .padding(.vertical, BSCSpacing.xs)
                    .background(Color.bscPrimary.opacity(0.1))
                    .cornerRadius(6)
                }

                Spacer()

                // File type filter
                Menu {
                    Picker("File Type", selection: $searchViewModel.searchFilter.fileType) {
                        ForEach(SearchFilter.FileTypeFilter.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                } label: {
                    HStack {
                        Text(searchViewModel.searchFilter.fileType.rawValue)
                            .font(.caption)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundColor(.bscPrimary)
                    .padding(.horizontal, BSCSpacing.sm)
                    .padding(.vertical, BSCSpacing.xs)
                    .background(Color.bscPrimary.opacity(0.1))
                    .cornerRadius(6)
                }
            }
            
            // Date and size filters
            HStack(spacing: 12) {
                // Date range filter
                Menu {
                    Picker("Date Range", selection: $searchViewModel.searchFilter.dateRange) {
                        ForEach(SearchFilter.DateRangeFilter.allCases, id: \.self) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                } label: {
                    HStack {
                        Text(searchViewModel.searchFilter.dateRange.rawValue)
                            .font(.caption)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundColor(.bscSuccess)
                    .padding(.horizontal, BSCSpacing.sm)
                    .padding(.vertical, BSCSpacing.xs)
                    .background(Color.bscSuccess.opacity(0.1))
                    .cornerRadius(6)
                }
                
                Spacer()
                
                // Size filter
                Menu {
                    Picker("File Size", selection: $searchViewModel.searchFilter.sizeRange) {
                        ForEach(SearchFilter.FileSizeFilter.allCases, id: \.self) { size in
                            Text(size.rawValue).tag(size)
                        }
                    }
                } label: {
                    HStack {
                        Text(searchViewModel.searchFilter.sizeRange.rawValue)
                            .font(.caption)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundColor(.bscWarmAccent)
                    .padding(.horizontal, BSCSpacing.sm)
                    .padding(.vertical, BSCSpacing.xs)
                    .background(Color.bscWarmAccent.opacity(0.1))
                    .cornerRadius(6)
                }
            }
            
            // Folder depth filter
            HStack {
                Menu {
                    Picker("Folder Depth", selection: $searchViewModel.searchFilter.folderDepth) {
                        ForEach(SearchFilter.FolderDepthFilter.allCases, id: \.self) { depth in
                            Text(depth.rawValue).tag(depth)
                        }
                    }
                } label: {
                    HStack {
                        Text("Folder: \(searchViewModel.searchFilter.folderDepth.rawValue)")
                            .font(.caption)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundColor(.bscTeal)
                    .padding(.horizontal, BSCSpacing.sm)
                    .padding(.vertical, BSCSpacing.xs)
                    .background(Color.bscTeal.opacity(0.1))
                    .cornerRadius(6)
                }
                
                Spacer()
                
                // Reset filters
                Button {
                    searchViewModel.resetFilters()
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Reset")
                    }
                    .font(.caption)
                    .foregroundColor(.bscError)
                    .padding(.horizontal, BSCSpacing.sm)
                    .padding(.vertical, BSCSpacing.xs)
                    .background(Color.bscError.opacity(0.1))
                    .cornerRadius(6)
                }
            }
        }
        .padding(BSCSpacing.md)
        .background(Color.bscSurfaceGlass)
        .cornerRadius(10)
    }
    
    private var actionButtonsView: some View {
        HStack(spacing: 12) {
            // Search history
            Button {
                searchViewModel.isShowingHistory.toggle()
            } label: {
                HStack {
                    Image(systemName: "clock")
                    Text("History")
                }
                .font(.caption)
                .foregroundColor(.bscPrimary)
            }

            Spacer()

            // Saved searches
            Button {
                searchViewModel.isShowingSavedSearches.toggle()
            } label: {
                HStack {
                    Image(systemName: "bookmark")
                    Text("Saved")
                }
                .font(.caption)
                .foregroundColor(.bscPrimary)
            }

            Spacer()

            // Save search
            Button {
                showingSaveSearchDialog = true
            } label: {
                HStack {
                    Image(systemName: "plus")
                    Text("Save")
                }
                .font(.caption)
                .foregroundColor(.bscSuccess)
            }
        }
        .padding(.horizontal, 4)
    }
    
    // MARK: - Quick Filters
    
    private var quickFiltersView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(QuickFilter.allCases, id: \.self) { filter in
                    quickFilterButton(filter)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, BSCSpacing.sm)
        .background(Color.bscBackground)
    }
    
    private func quickFilterButton(_ filter: QuickFilter) -> some View {
        let isActive = searchViewModel.activeQuickFilters.contains(filter)
        
        return Button {
            searchViewModel.toggleQuickFilter(filter)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: filter.systemImage)
                Text(filter.displayName)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isActive ? Color.bscPrimary : Color.bscSurfaceGlass)
            .foregroundColor(isActive ? .white : .bscTextPrimary)
            .cornerRadius(16)
        }
    }
    
    // MARK: - Search Results
    
    private var searchResultsView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if searchViewModel.searchText.isEmpty {
                    searchPlaceholderView
                } else if searchViewModel.isSearching {
                    SearchEmptyStateView(query: searchViewModel.searchText, isSearching: true)
                } else if searchViewModel.searchResults.isEmpty {
                    SearchEmptyStateView(query: searchViewModel.searchText, isSearching: false)
                } else {
                    VStack(spacing: 0) {
                        // Results stats
                        SearchResultStatsView(
                            resultCount: searchViewModel.searchResults.count,
                            searchDuration: nil
                        )
                        
                        // Results list
                        SearchResultsListView(
                            results: searchViewModel.searchResults,
                            query: searchViewModel.searchText,
                            onResultTap: { result in
                                handleResultTap(result)
                            },
                            onNavigateToFolder: onNavigateToFolder
                        )
                        .padding(.horizontal, 16)
                    }
                }
                
                // History and saved searches popups
                if searchViewModel.isShowingHistory {
                    searchHistoryView
                }
                
                if searchViewModel.isShowingSavedSearches {
                    savedSearchesView
                }
            }
        }
        .background(Color.bscBackgroundMuted)
    }
    
    private var searchPlaceholderView: some View {
        VStack(spacing: 24) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 64))
                .foregroundColor(.bscTextTertiary)

            VStack(spacing: BSCSpacing.sm) {
                Text("Search Your Library")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Find videos and folders across your entire collection")
                    .font(.subheadline)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "textformat")
                    Text("Search by name, filename, or folder")
                        .font(.caption)
                        .foregroundColor(.bscTextSecondary)
                    Spacer()
                }

                HStack {
                    Image(systemName: "slider.horizontal.3")
                    Text("Use filters for advanced searches")
                        .font(.caption)
                        .foregroundColor(.bscTextSecondary)
                    Spacer()
                }

                HStack {
                    Image(systemName: "bookmark")
                    Text("Save frequently used searches")
                        .font(.caption)
                        .foregroundColor(.bscTextSecondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 40)
    }
    
    // MARK: - History and Saved Searches
    
    private var searchHistoryView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Searches")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    searchViewModel.searchHistory.removeAll()
                }
                .font(.caption)
                .foregroundColor(.bscError)
            }
            
            LazyVStack(spacing: 8) {
                ForEach(searchViewModel.searchHistory.prefix(10)) { history in
                    Button {
                        searchViewModel.searchFromHistory(history)
                        searchViewModel.isShowingHistory = false
                    } label: {
                        HStack {
                            Image(systemName: "clock")
                                .foregroundColor(.bscTextSecondary)

                            VStack(alignment: .leading) {
                                Text(history.query)
                                    .font(.subheadline)
                                Text("\(history.resultCount) results")
                                    .font(.caption)
                                    .foregroundColor(.bscTextSecondary)
                            }

                            Spacer()

                            Text(RelativeDateTimeFormatter().localizedString(for: history.timestamp, relativeTo: Date()))
                                .font(.caption)
                                .foregroundColor(.bscTextSecondary)
                        }
                        .padding(.vertical, 8)
                    }
                    .foregroundColor(.bscTextPrimary)
                }
            }
        }
        .padding(BSCSpacing.lg)
        .background(Color.bscBackgroundElevated)
        .cornerRadius(BSCRadius.md)
        .padding(.horizontal, BSCSpacing.lg)
    }

    private var savedSearchesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved Searches")
                .font(.headline)
            
            LazyVStack(spacing: 8) {
                ForEach(searchViewModel.savedSearches) { savedSearch in
                    HStack {
                        Button {
                            searchViewModel.loadSavedSearch(savedSearch)
                            searchViewModel.isShowingSavedSearches = false
                        } label: {
                            HStack {
                                Image(systemName: "bookmark.fill")
                                    .foregroundColor(.bscPrimary)
                                
                                VStack(alignment: .leading) {
                                    Text(savedSearch.name)
                                        .font(.subheadline)
                                    Text(savedSearch.query)
                                        .font(.caption)
                                        .foregroundColor(.bscTextSecondary)
                                }
                                
                                Spacer()
                            }
                        }
                        .foregroundColor(.bscTextPrimary)

                        Button {
                            searchViewModel.deleteSavedSearch(savedSearch)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.bscError)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .padding(BSCSpacing.lg)
        .background(Color.bscBackgroundElevated)
        .cornerRadius(BSCRadius.md)
        .padding(.horizontal, BSCSpacing.lg)
    }

    // MARK: - Save Search Sheet
    
    private var saveSearchSheet: some View {
        NavigationView {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Search Name")
                        .font(.headline)
                    
                    TextField("Enter a name for this search", text: $saveSearchName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Search Query")
                        .font(.headline)
                    
                    Text(searchViewModel.searchText)
                        .padding()
                        .background(Color.bscSurfaceGlass)
                        .cornerRadius(8)
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Save Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        showingSaveSearchDialog = false
                        saveSearchName = ""
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        searchViewModel.saveSearch(name: saveSearchName.trimmingCharacters(in: .whitespacesAndNewlines))
                        showingSaveSearchDialog = false
                        saveSearchName = ""
                    }
                    .disabled(saveSearchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func handleResultTap(_ result: SearchResult) {
        switch result.type {
        case .video(let video):
            onNavigateToVideo(video)
        case .folder(let folder):
            onNavigateToFolder(folder.path)
        }
    }
    
    private func sortIcon(for option: AdvancedSortOption) -> String {
        switch option {
        case .relevance: return "star"
        case .name: return "textformat"
        case .dateCreated: return "calendar"
        case .dateModified: return "calendar.badge.clock"
        case .fileSize: return "externaldrive"
        case .folderDepth: return "folder"
        case .videoCount: return "number"
        }
    }
}

// MARK: - Preview

struct AdvancedSearchView_Previews: PreviewProvider {
    static var previews: some View {
        AdvancedSearchView(
            searchViewModel: SearchViewModel(mediaStore: MediaStore()),
            onNavigateToFolder: { _ in },
            onNavigateToVideo: { _ in }
        )
    }
}