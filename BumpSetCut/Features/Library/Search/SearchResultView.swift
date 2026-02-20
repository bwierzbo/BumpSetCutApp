//
//  SearchResultView.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 9/1/25.
//

import SwiftUI

struct SearchResultView: View {
    let result: SearchResult
    let query: String
    let onTap: () -> Void
    let onNavigateToFolder: (String) -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Icon based on result type
                resultIcon
                
                VStack(alignment: .leading, spacing: 4) {
                    // Title with highlighting
                    HighlightedText(
                        text: result.title,
                        query: query,
                        font: .headline,
                        highlightColor: .bscPrimary
                    )
                    
                    // Subtitle with context
                    Text(result.subtitle)
                        .font(.caption)
                        .foregroundColor(.bscTextSecondary)
                        .lineLimit(1)
                    
                    // Folder path with navigation
                    if !result.folderPath.isEmpty {
                        folderPathView
                    }
                }
                
                Spacer()
                
                // Relevance indicator
                if result.relevanceScore > 50 {
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                        .font(.caption2)
                }
                
                // Navigation chevron
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.bscTextSecondary)
            }
            .padding(.vertical, BSCSpacing.sm)
            .padding(.horizontal, BSCSpacing.md)
            .background(Color.bscBackgroundElevated)
            .cornerRadius(BSCRadius.sm)
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.sm)
                    .stroke(Color.bscSurfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    @ViewBuilder
    private var resultIcon: some View {
        switch result.type {
        case .video(_):
            Image(systemName: "video.fill")
                .foregroundColor(.bscPrimary)
                .font(.title2)
        case .folder(_):
            Image(systemName: "folder.fill")
                .foregroundColor(.bscWarmAccent)
                .font(.title2)
        }
    }
    
    @ViewBuilder
    private var folderPathView: some View {
        Button {
            onNavigateToFolder(result.folderPath)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.caption2)
                
                HighlightedText(
                    text: result.folderPath,
                    query: query,
                    font: .caption2,
                    highlightColor: .bscPrimary
                )
                
                Image(systemName: "arrow.up.right.square")
                    .font(.caption2)
            }
            .foregroundColor(.bscPrimary)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct HighlightedText: View {
    let text: String
    let query: String
    let font: Font
    let highlightColor: Color
    let backgroundColor: Color
    
    init(
        text: String,
        query: String,
        font: Font = .body,
        highlightColor: Color = .primary,
        backgroundColor: Color = .yellow.opacity(0.3)
    ) {
        self.text = text
        self.query = query
        self.font = font
        self.highlightColor = highlightColor
        self.backgroundColor = backgroundColor
    }
    
    var body: some View {
        if query.isEmpty {
            Text(text)
                .font(font)
        } else {
            highlightedText
        }
    }
    
    private var highlightedText: some View {
        let attributedString = createHighlightedAttributedString()
        return Text(AttributedString(attributedString))
    }
    
    private func createHighlightedAttributedString() -> NSAttributedString {
        let attributedString = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: text.count)
        
        // Set default attributes
        attributedString.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: textStyle), range: range)
        attributedString.addAttribute(.foregroundColor, value: UIColor.label, range: range)
        
        // Find and highlight matches
        let searchRanges = findRanges(of: query, in: text)
        
        for searchRange in searchRanges {
            attributedString.addAttribute(.backgroundColor, value: UIColor(backgroundColor), range: searchRange)
            attributedString.addAttribute(.foregroundColor, value: UIColor(highlightColor), range: searchRange)
            attributedString.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: UIFont.preferredFont(forTextStyle: textStyle).pointSize), range: searchRange)
        }
        
        return attributedString
    }
    
    private func findRanges(of searchString: String, in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: text.count)
        
        while searchRange.location < text.count {
            let foundRange = (text as NSString).range(
                of: searchString,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            )
            
            if foundRange.location != NSNotFound {
                ranges.append(foundRange)
                searchRange.location = foundRange.location + foundRange.length
                searchRange.length = text.count - searchRange.location
            } else {
                break
            }
        }
        
        return ranges
    }
    
    private var textStyle: UIFont.TextStyle {
        switch font {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}

struct SearchResultsListView: View {
    let results: [SearchResult]
    let query: String
    let onResultTap: (SearchResult) -> Void
    let onNavigateToFolder: (String) -> Void
    
    var body: some View {
        LazyVStack(spacing: 8) {
            ForEach(results) { result in
                SearchResultView(
                    result: result,
                    query: query,
                    onTap: { onResultTap(result) },
                    onNavigateToFolder: onNavigateToFolder
                )
            }
        }
    }
}

struct SearchEmptyStateView: View {
    let query: String
    let isSearching: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            if isSearching {
                ProgressView()
                    .scaleEffect(1.2)
                Text("Searching...")
                    .font(.headline)
                    .foregroundColor(.bscTextSecondary)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundColor(.bscTextTertiary)

                Text("No results found")
                    .font(.headline)
                    .foregroundColor(.bscTextSecondary)

                if !query.isEmpty {
                    Text("Try adjusting your search terms or filters")
                        .font(.subheadline)
                        .foregroundColor(.bscTextSecondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(.vertical, 40)
    }
}

struct SearchResultStatsView: View {
    let resultCount: Int
    let searchDuration: TimeInterval?
    
    var body: some View {
        HStack {
            Text(resultText)
                .font(.caption)
                .foregroundColor(.bscTextSecondary)

            Spacer()

            if let duration = searchDuration {
                Text("(\(String(format: "%.2f", duration))s)")
                    .font(.caption)
                    .foregroundColor(.bscTextSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
    
    private var resultText: String {
        switch resultCount {
        case 0: return "No results"
        case 1: return "1 result"
        default: return "\(resultCount) results"
        }
    }
}

// MARK: - Preview

struct SearchResultView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            SearchResultView(
                result: SearchResult(
                    type: .video(VideoMetadata(
                        originalURL: URL(fileURLWithPath: "/test/video.mov"),
                        customName: "My Test Video",
                        folderPath: "Volleyball/Practice",
                        createdDate: Date(),
                        fileSize: 1024 * 1024 * 100,
                        duration: 120
                    )),
                    title: "My Test Video",
                    subtitle: "100 MB • Volleyball/Practice",
                    folderPath: "Volleyball/Practice",
                    matchedText: "Test",
                    relevanceScore: 85.0
                ),
                query: "test",
                onTap: {},
                onNavigateToFolder: { _ in }
            )
            
            SearchResultView(
                result: SearchResult(
                    type: .folder(FolderMetadata(
                        name: "Practice Footage",
                        path: "Volleyball/Practice",
                        parentPath: "Volleyball",
                        createdDate: Date(),
                        modifiedDate: Date(),
                        videoCount: 15,
                        subfolderCount: 3
                    )),
                    title: "Practice Footage",
                    subtitle: "15 videos, 3 folders • Volleyball",
                    folderPath: "Volleyball/Practice",
                    matchedText: "Practice",
                    relevanceScore: 92.0
                ),
                query: "practice",
                onTap: {},
                onNavigateToFolder: { _ in }
            )
        }
        .padding()
        .background(Color.bscBackgroundMuted)
    }
}