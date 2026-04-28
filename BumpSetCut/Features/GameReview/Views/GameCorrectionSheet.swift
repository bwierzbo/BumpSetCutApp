//
//  GameCorrectionSheet.swift
//  BumpSetCut
//
//  Quick correction sheet for Game Review — fix point winner or server.
//

import SwiftUI

struct GameCorrectionSheet: View {
    let currentServer: CourtSide
    let onConfirm: (CourtSide, CourtSide, Bool) -> Void // (winner, server, applyToRest)
    let onCancel: () -> Void

    @State private var selectedWinner: CourtSide = .near
    @State private var adjustedServer: CourtSide
    @State private var showServerAdjust: Bool = false
    @State private var applyToRest: Bool = false

    init(currentServer: CourtSide, onConfirm: @escaping (CourtSide, CourtSide, Bool) -> Void, onCancel: @escaping () -> Void) {
        self.currentServer = currentServer
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self._adjustedServer = State(wrappedValue: currentServer)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: BSCSpacing.xl) {
                // Who won?
                VStack(spacing: BSCSpacing.sm) {
                    Text("Who won this point?")
                        .font(.headline)

                    HStack(spacing: BSCSpacing.lg) {
                        winnerButton(side: .near)
                        winnerButton(side: .far)
                    }
                }

                // Adjust server (expandable)
                VStack(spacing: BSCSpacing.sm) {
                    Button {
                        withAnimation { showServerAdjust.toggle() }
                    } label: {
                        HStack {
                            Text("Adjust Server")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: showServerAdjust ? "chevron.up" : "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if showServerAdjust {
                        Picker("Server", selection: $adjustedServer) {
                            ForEach(CourtSide.allCases, id: \.self) { side in
                                Text(side.displayName).tag(side)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                // Apply to remaining
                Toggle("Apply to remaining rallies", isOn: $applyToRest)
                    .font(.subheadline)

                Spacer()
            }
            .padding(BSCSpacing.lg)
            .navigationTitle("Correct Point")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") {
                        onConfirm(selectedWinner, adjustedServer, applyToRest)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func winnerButton(side: CourtSide) -> some View {
        Button {
            selectedWinner = side
        } label: {
            VStack(spacing: BSCSpacing.xs) {
                Image(systemName: "flag.fill")
                    .font(.title2)
                Text(side.displayName)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BSCSpacing.lg)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.md)
                    .fill(selectedWinner == side ? Color.bscPrimary.opacity(0.2) : Color.bscSurfaceGlass)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.md)
                    .stroke(selectedWinner == side ? Color.bscPrimary : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}
