//
//  VideoUploadNamingDialog.swift
//  BumpSetCut
//
//  Created by Claude on 9/1/25.
//

import SwiftUI
import MijickPopups

struct VideoUploadNamingDialog: CenterPopup {
    let uploadItem: UploadItem
    let onName: (String) -> Void
    let onSkip: () -> Void
    let onCancel: () -> Void
    
    @State private var customName: String
    @State private var useCustomName: Bool = false
    @State private var suggestedNames: [String] = []
    @FocusState private var isTextFieldFocused: Bool
    
    init(uploadItem: UploadItem, onName: @escaping (String) -> Void, onSkip: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.uploadItem = uploadItem
        self.onName = onName
        self.onSkip = onSkip
        self.onCancel = onCancel
        self._customName = State(initialValue: uploadItem.displayName)
    }
    
    func configurePopup(config: CenterPopupConfig) -> CenterPopupConfig {
        config
            .backgroundColor(.clear)
            .cornerRadius(16)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Name Your Video")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Choose a custom name or use one of our suggestions")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Preview
            HStack(spacing: 12) {
                if let thumbnail = uploadItem.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "video")
                        .frame(width: 60, height: 60)
                        .background(Color(.systemGray5))
                        .foregroundColor(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(uploadItem.originalFileName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text(formatFileSize(uploadItem.fileSize))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // Naming Options
            VStack(spacing: 16) {
                // Custom Name Option
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button {
                            useCustomName = true
                            if useCustomName {
                                isTextFieldFocused = true
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: useCustomName ? "largecircle.fill.circle" : "circle")
                                    .foregroundColor(useCustomName ? .blue : .secondary)
                                Text("Custom Name")
                                    .font(.headline)
                            }
                        }
                        .buttonStyle(.plain)
                        
                        Spacer()
                    }
                    
                    TextField("Enter video name", text: $customName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .focused($isTextFieldFocused)
                        .disabled(!useCustomName)
                        .opacity(useCustomName ? 1.0 : 0.6)
                        .onTapGesture {
                            useCustomName = true
                            isTextFieldFocused = true
                        }
                }
                
                // Auto-generated Options
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button {
                            useCustomName = false
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: !useCustomName ? "largecircle.fill.circle" : "circle")
                                    .foregroundColor(!useCustomName ? .blue : .secondary)
                                Text("Auto-generated Names")
                                    .font(.headline)
                            }
                        }
                        .buttonStyle(.plain)
                        
                        Spacer()
                    }
                    
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 1), spacing: 8) {
                        ForEach(getSuggestedNames(), id: \.self) { suggestion in
                            Button {
                                useCustomName = false
                                customName = suggestion
                            } label: {
                                HStack {
                                    Text(suggestion)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if !useCustomName && customName == suggestion {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.blue)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    (!useCustomName && customName == suggestion) ? 
                                    Color.blue.opacity(0.1) : Color(.systemGray6)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .disabled(useCustomName)
                    .opacity(useCustomName ? 0.6 : 1.0)
                }
            }
            
            // Actions
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.systemGray5))
                .foregroundColor(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                
                Button("Use Original") {
                    onSkip()
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.systemGray4))
                .foregroundColor(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                
                Button("Name Video") {
                    let finalName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
                    onName(finalName)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 
                           Color(.systemGray4) : Color.blue)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .onAppear {
            customName = getSuggestedNames().first ?? uploadItem.displayName
        }
    }
    
    private func getSuggestedNames() -> [String] {
        let now = Date()
        let dateFormatter = DateFormatter()
        
        let suggestions: [String] = [
            // Date-based suggestions
            {
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
                return "Video \(dateFormatter.string(from: now))"
            }(),
            
            {
                dateFormatter.dateFormat = "MMMM d, yyyy"
                return "Practice Session \(dateFormatter.string(from: now))"
            }(),
            
            {
                dateFormatter.dateFormat = "yyyy-MM-dd"
                return "Game \(dateFormatter.string(from: now))"
            }(),
            
            // Activity-based suggestions
            "Beach Volleyball Training",
            "Technique Practice",
            "Match Highlights",
            "Skill Development",
            "Team Scrimmage",
            
            // Time-based suggestions  
            {
                let hour = Calendar.current.component(.hour, from: now)
                switch hour {
                case 6..<12: return "Morning Practice"
                case 12..<17: return "Afternoon Training"
                case 17..<21: return "Evening Session"
                default: return "Late Night Practice"
                }
            }()
        ]
        
        return Array(suggestions.prefix(4)) // Return first 4 suggestions
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
}

//#Preview {
//    VideoUploadNamingDialog(
//        uploadItem: {
//            let item = UploadItem(
//                sourceData: Data(),
//                originalFileName: "VID_20240901_143052.mp4",
//                fileSize: 15_728_640
//            )
//            return item
//        }(),
//        onName: { name in print("Named: \(name)") },
//        onSkip: { print("Skipped") },
//        onCancel: { print("Cancelled") }
//    )
//}