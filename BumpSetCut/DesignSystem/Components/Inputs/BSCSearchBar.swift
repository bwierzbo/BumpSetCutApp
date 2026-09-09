import SwiftUI

// MARK: - BSCSearchBar
/// A glass morphism search bar with animations
struct BSCSearchBar: View {
    // MARK: - Properties
    @Binding var text: String
    var placeholder: String = "Search"
    var onSubmit: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var showCancelButton: Bool = false

    @FocusState private var isFocused: Bool

    // MARK: - Body
    var body: some View {
        HStack(spacing: BSCSpacing.md) {
            // Search field
            HStack(spacing: BSCSpacing.sm) {
                // Search icon
                Image(systemName: "magnifyingglass")
                    .bscFont(size: 16, weight: .medium)
                    .foregroundColor(isFocused ? .bscPrimary : .bscTextSecondary)
                    .accessibilityHidden(true)

                // Text field
                TextField(placeholder, text: $text)
                    .bscFont(size: 16)
                    .foregroundColor(.bscTextPrimary)
                    .focused($isFocused)
                    .submitLabel(.search)
                    .onSubmit {
                        onSubmit?()
                    }

                // Clear button
                if !text.isEmpty {
                    Button {
                        withAnimation(.bscQuick) {
                            text = ""
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .bscFont(size: 16)
                            .foregroundColor(.bscTextSecondary)
                            .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Clear search")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, BSCSpacing.md)
            .padding(.vertical, BSCSpacing.md)
            .background(Color.bscSurfaceGlass)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(
                        isFocused ? Color.bscPrimary.opacity(0.5) : Color.bscSurfaceBorder,
                        lineWidth: isFocused ? 2 : 1
                    )
            )
            .animation(.bscQuick, value: isFocused)

            // Cancel button
            if showCancelButton && (isFocused || !text.isEmpty) {
                Button {
                    withAnimation(.bscQuick) {
                        text = ""
                        isFocused = false
                        onCancel?()
                    }
                } label: {
                    Text("Cancel")
                        .bscFont(size: 16)
                        .foregroundColor(.bscPrimaryText)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.bscSpring, value: showCancelButton && (isFocused || !text.isEmpty))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Search")
        .accessibilityValue(text.isEmpty ? "Empty" : text)
    }
}

// MARK: - Preview
#Preview("BSCSearchBar") {
    VStack(spacing: BSCSpacing.xxl) {
        Text("Search Bar")
            .font(.headline)
            .foregroundColor(.bscTextPrimary)

        BSCSearchBar(
            text: .constant(""),
            placeholder: "Search videos..."
        )

        BSCSearchBar(
            text: .constant("volleyball"),
            placeholder: "Search videos...",
            showCancelButton: true
        )
    }
    .padding()
    .background(Color.bscBackground)
}
