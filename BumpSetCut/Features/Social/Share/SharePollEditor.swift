//
//  SharePollEditor.swift
//  BumpSetCut
//
//  The share sheet's poll editor: question, 2–5 options, add/remove.
//

import SwiftUI

struct SharePollEditor: View {
    @Bindable var viewModel: ShareRallyViewModel

    var body: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $viewModel.includePoll) {
                HStack(spacing: BSCSpacing.sm) {
                    Image(systemName: "chart.bar.xaxis")
                        .bscFont(size: 15)
                        .foregroundColor(.bscTextSecondary)
                    VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                        Text("Add a poll")
                            .bscFont(size: 14, weight: .medium)
                            .foregroundColor(.bscTextPrimary)
                        Text("Let viewers vote on your rally")
                            .bscFont(size: 12)
                            .foregroundColor(.bscTextSecondary)
                    }
                }
            }
            .tint(.bscPrimary)
            .padding(BSCSpacing.sm)

            if viewModel.includePoll {
                Divider().overlay(Color.bscSurfaceBorder)

                VStack(spacing: BSCSpacing.sm) {
                    TextField("Ask a question...", text: $viewModel.pollQuestion)
                        .textFieldStyle(.plain)
                        .bscFont(size: 15, weight: .medium)
                        .foregroundColor(.bscTextPrimary)
                        .padding(BSCSpacing.sm)
                        .background(Color.bscSurfaceGlass.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous))

                    ForEach($viewModel.pollOptions) { $option in
                        let number = (viewModel.pollOptions.firstIndex { $0.id == option.id } ?? 0) + 1
                        HStack(spacing: BSCSpacing.xs) {
                            Circle()
                                .stroke(Color.bscTextSecondary, lineWidth: 1.5)
                                .frame(width: 16, height: 16)

                            TextField("Option \(number)", text: $option.text)
                                .textFieldStyle(.plain)
                                .bscFont(size: 14)
                                .foregroundColor(.bscTextPrimary)

                            if viewModel.pollOptions.count > 2 {
                                Button {
                                    viewModel.removePollOption(option.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .bscFont(size: 16)
                                        .foregroundColor(.bscTextSecondary)
                                        .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("Remove option \(number)")
                            }
                        }
                        .padding(.horizontal, BSCSpacing.sm)
                        .padding(.vertical, BSCSpacing.xs)
                        .background(Color.bscSurfaceGlass.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous))
                    }

                    if viewModel.pollOptions.count < 5 {
                        Button {
                            viewModel.addPollOption()
                        } label: {
                            HStack(spacing: BSCSpacing.xs) {
                                Image(systemName: "plus.circle.fill")
                                    .bscFont(size: 14)
                                Text("Add option")
                                    .bscFont(size: 13, weight: .medium)
                            }
                            .foregroundColor(.bscPrimaryText)
                            .frame(minHeight: BSCTouchTarget.standard)
                            .contentShape(Rectangle())
                        }
                    }
                }
                .padding(BSCSpacing.sm)
            }
        }
        .background(Color.bscSurfaceGlass)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
    }
}
