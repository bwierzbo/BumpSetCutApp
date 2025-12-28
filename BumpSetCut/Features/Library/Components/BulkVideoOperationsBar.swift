//
//  BulkVideoOperationsBar.swift
//  BumpSetCut
//
//  Created by Claude on 9/1/25.
//

import SwiftUI

struct BulkVideoOperationsBar: View {
    let selectedCount: Int
    let totalCount: Int
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    let onBulkMove: () -> Void
    let onBulkDelete: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack(spacing: 16) {
                // Selection info
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selectedCount) selected")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    if selectedCount < totalCount {
                        Button("Select All (\(totalCount))") {
                            onSelectAll()
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                    } else {
                        Button("Deselect All") {
                            onDeselectAll()
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                    }
                }
                
                Spacer()
                
                // Action buttons
                HStack(spacing: 12) {
                    Button {
                        onBulkMove()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.title3)
                            Text("Move")
                                .font(.caption2)
                        }
                        .foregroundColor(.blue)
                        .frame(width: 50, height: 50)
                    }
                    .disabled(selectedCount == 0)
                    
                    Button {
                        onBulkDelete()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.title3)
                            Text("Delete")
                                .font(.caption2)
                        }
                        .foregroundColor(.red)
                        .frame(width: 50, height: 50)
                    }
                    .disabled(selectedCount == 0)
                    
                    Button {
                        onCancel()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.title3)
                            Text("Cancel")
                                .font(.caption2)
                        }
                        .foregroundColor(.secondary)
                        .frame(width: 50, height: 50)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
        }
    }
}

#Preview {
    VStack {
        Spacer()
        BulkVideoOperationsBar(
            selectedCount: 3,
            totalCount: 10,
            onSelectAll: { print("Select all") },
            onDeselectAll: { print("Deselect all") },
            onBulkMove: { print("Bulk move") },
            onBulkDelete: { print("Bulk delete") },
            onCancel: { print("Cancel") }
        )
    }
}