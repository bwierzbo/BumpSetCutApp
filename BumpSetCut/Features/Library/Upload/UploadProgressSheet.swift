//
//  UploadProgressSheet.swift
//  BumpSetCut
//
//  Opened from the global upload pill — the import's counterpart to the
//  processing screen: live progress, what leaving the app means, and the
//  only place to cancel (the same way processing is cancelled).
//

import SwiftUI

struct UploadProgressSheet: View {
    let uploadCoordinator: UploadCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var showCancelConfirm = false
    /// Latched: the coordinator clears `showCompleted` a couple of seconds
    /// after finishing, and the sheet must not snap back to a progress view.
    @State private var didComplete = false

    private var isComplete: Bool { didComplete || uploadCoordinator.showCompleted }

    var body: some View {
        NavigationView {
            VStack(spacing: BSCSpacing.xxl) {
                Spacer()

                if isComplete {
                    completedContent
                } else {
                    progressContent
                }

                Spacer()

                if !isComplete {
                    BSCButton(title: "Cancel Import", icon: "xmark", style: .ghost, size: .medium) {
                        showCancelConfirm = true
                    }
                    .accessibilityIdentifier(AccessibilityID.Upload.cancelButton)
                }
            }
            .padding(BSCSpacing.xl)
            .background(Color.bscBackground)
            .navigationTitle("Importing Video")
            .navigationBarTitleDisplayMode(.inline)
        }
        .confirmationDialog("Cancel import?", isPresented: $showCancelConfirm, titleVisibility: .visible) {
            Button("Cancel Import", role: .destructive) {
                uploadCoordinator.cancelImport()
                dismiss()
            }
            Button("Keep Importing", role: .cancel) {}
        }
        .onChange(of: uploadCoordinator.showCompleted) { _, completed in
            if completed { didComplete = true }
        }
        .onChange(of: uploadCoordinator.isUploadInProgress) { _, inProgress in
            // Failed or cancelled elsewhere (system progress UI, storage
            // alert): nothing left to show — the alert takes over.
            if !inProgress && !isComplete { dismiss() }
        }
    }

    private var progressContent: some View {
        VStack(spacing: BSCSpacing.xl) {
            ZStack {
                Circle()
                    .fill(Color.bscSurfaceGlass)
                    .frame(width: 148, height: 148)
                if let fraction = uploadCoordinator.importProgress {
                    BSCExportProgressRing(progress: fraction)
                } else {
                    // Indeterminate: before load progress arrives, or drag-drop.
                    ProgressView()
                        .tint(.bscPrimary)
                        .scaleEffect(1.6)
                }
            }

            VStack(spacing: BSCSpacing.sm) {
                Text("Importing \(uploadCoordinator.currentVideoName)…")
                    .bscFont(size: 20, weight: .bold)
                    .foregroundColor(.bscTextPrimary)
                    .multilineTextAlignment(.center)

                if !uploadCoordinator.uploadProgressText.isEmpty {
                    Text(uploadCoordinator.uploadProgressText)
                        .bscFont(size: 15)
                        .foregroundColor(.bscTextSecondary)
                        .multilineTextAlignment(.center)
                }
            }

            Label(
                ProcessingBackgroundKeeper.importing.isActive
                    ? "You're free to leave the app — the import keeps going."
                    : "Keep BumpSetCut open until the import finishes.",
                systemImage: ProcessingBackgroundKeeper.importing.isActive
                    ? "checkmark.circle"
                    : "exclamationmark.triangle"
            )
            .bscFont(size: 14)
            .foregroundColor(.bscTextSecondary)
            .multilineTextAlignment(.center)
        }
    }

    private var completedContent: some View {
        VStack(spacing: BSCSpacing.xl) {
            Image(systemName: "checkmark.circle.fill")
                .bscFont(size: 60)
                .foregroundColor(.bscSuccessText)

            VStack(spacing: BSCSpacing.sm) {
                Text("Import Complete")
                    .bscFont(size: 20, weight: .bold)
                    .foregroundColor(.bscTextPrimary)

                Text("\(uploadCoordinator.currentVideoName) is in your library.")
                    .bscFont(size: 15)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .bscFont(size: 17, weight: .semibold)
                    .foregroundColor(.bscOnPrimary)
                    .padding(.vertical, BSCSpacing.md)
                    .frame(maxWidth: .infinity)
                    .background(LinearGradient.bscPrimaryGradient)
                    .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
            }
            .accessibilityIdentifier(AccessibilityID.Upload.doneButton)
        }
    }
}
