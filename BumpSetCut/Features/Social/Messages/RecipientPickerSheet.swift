//
//  RecipientPickerSheet.swift
//  BumpSetCut
//
//  Choose who to send a rally to. Recent conversations first, then people
//  you follow; typing switches to a search. Tap a row to pick.
//

import SwiftUI

struct RecipientPickerSheet: View {
    @State private var viewModel: RecipientPickerViewModel
    let onSelect: (UserProfile) -> Void
    let onCancel: () -> Void

    init(currentUserId: String,
         apiClient: (any APIClient)? = nil,
         onSelect: @escaping (UserProfile) -> Void,
         onCancel: @escaping () -> Void) {
        _viewModel = State(initialValue: RecipientPickerViewModel(currentUserId: currentUserId, apiClient: apiClient))
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            BSCSearchBar(text: $viewModel.query, placeholder: "Search people")
                .padding(.horizontal, BSCSpacing.lg)
                .padding(.vertical, BSCSpacing.sm)
                .accessibilityIdentifier(AccessibilityID.Messages.recipientSearch)
                .onChange(of: viewModel.query) { _, _ in
                    viewModel.searchTextChanged()
                }

            content
        }
        .background(Color.bscBackground.ignoresSafeArea())
        .navigationTitle("Send to")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
                    .foregroundColor(.bscTextSecondary)
            }
        }
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        let sections = viewModel.visibleSections
        if viewModel.isLoading && sections.isEmpty {
            skeleton
        } else if sections.isEmpty {
            emptyState
        } else {
            List {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.users) { user in
                            Button {
                                onSelect(user)
                            } label: {
                                userRow(user)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.bscBackground)
                            .accessibilityIdentifier(AccessibilityID.Messages.recipientRow)
                        }
                    } header: {
                        Text(section.title)
                            .bscFont(size: 12, weight: .semibold)
                            .foregroundColor(.bscTextSecondary)
                            .textCase(.uppercase)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private func userRow(_ user: UserProfile) -> some View {
        HStack(spacing: BSCSpacing.md) {
            AvatarView(url: user.avatarURL, name: user.username, size: 44)
            Text(user.username)
                .bscFont(size: 15, weight: .semibold)
                .foregroundColor(.bscTextPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .bscFont(size: 12)
                .foregroundColor(.bscTextSecondary)
        }
        .padding(.vertical, BSCSpacing.xs)
        // The Spacer is the widest part of the row; without a shape it is dead.
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(user.username)
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.isQueryActive {
            if viewModel.isSearching {
                ProgressView().tint(.bscPrimary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BSCEmptyState.noSearchResults(query: viewModel.query) {
                    viewModel.query = ""
                }
            }
        } else if viewModel.loadFailed {
            BSCEmptyState.loadFailed {
                Task { await viewModel.load() }
            }
        } else {
            VStack(spacing: BSCSpacing.sm) {
                Image(systemName: "person.2")
                    .bscFont(size: 28)
                    .foregroundColor(.bscTextSecondary)
                Text("No one to send to yet")
                    .bscFont(size: 16, weight: .semibold)
                    .foregroundColor(.bscTextPrimary)
                Text("Follow people or search for a username.")
                    .bscFont(size: 14)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(BSCSpacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var skeleton: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { _ in
                    HStack(spacing: BSCSpacing.md) {
                        BSCSkeletonView().frame(width: 44, height: 44).clipShape(Circle())
                        BSCSkeletonView().frame(width: 140, height: 14).clipShape(Capsule())
                        Spacer()
                    }
                    .padding(.horizontal, BSCSpacing.lg)
                    .padding(.vertical, BSCSpacing.md)
                }
            }
        }
    }
}
