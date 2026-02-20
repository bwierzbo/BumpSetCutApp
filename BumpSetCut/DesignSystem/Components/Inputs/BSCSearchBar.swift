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
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isFocused ? .bscPrimary : .bscTextSecondary)

                // Text field
                TextField(placeholder, text: $text)
                    .font(.system(size: 16))
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
                            .font(.system(size: 16))
                            .foregroundColor(.bscTextTertiary)
                    }
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
                        .font(.system(size: 16))
                        .foregroundColor(.bscPrimary)
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

// MARK: - BSCTextField
/// A styled text field with glass effect
struct BSCTextField: View {
    // MARK: - Properties
    let placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var isSecure: Bool = false
    var errorMessage: String? = nil
    var onSubmit: (() -> Void)? = nil

    @FocusState private var isFocused: Bool

    // MARK: - Body
    var body: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.xs) {
            HStack(spacing: BSCSpacing.sm) {
                // Leading icon
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isFocused ? .bscPrimary : .bscTextSecondary)
                        .frame(width: 24)
                }

                // Text field
                Group {
                    if isSecure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .font(.system(size: 16))
                .foregroundColor(.bscTextPrimary)
                .focused($isFocused)
                .onSubmit {
                    onSubmit?()
                }
            }
            .padding(.horizontal, BSCSpacing.lg)
            .padding(.vertical, BSCSpacing.md)
            .background(Color.bscBackgroundMuted)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .stroke(borderColor, lineWidth: isFocused ? 2 : 1)
            )
            .animation(.bscQuick, value: isFocused)

            // Error message
            if let errorMessage = errorMessage {
                HStack(spacing: BSCSpacing.xs) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                    Text(errorMessage)
                        .font(.system(size: 12))
                }
                .foregroundColor(.bscError)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.bscQuick, value: errorMessage)
    }

    private var borderColor: Color {
        if errorMessage != nil {
            return .bscError
        } else if isFocused {
            return .bscPrimary.opacity(0.5)
        } else {
            return .bscSurfaceBorder
        }
    }
}

// MARK: - BSCTextArea
/// A multi-line text input with glass effect
struct BSCTextArea: View {
    // MARK: - Properties
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 100
    var maxHeight: CGFloat = 200

    @FocusState private var isFocused: Bool

    // MARK: - Body
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Placeholder
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 16))
                    .foregroundColor(.bscTextTertiary)
                    .padding(.horizontal, BSCSpacing.lg)
                    .padding(.vertical, BSCSpacing.md)
            }

            // Text editor
            TextEditor(text: $text)
                .font(.system(size: 16))
                .foregroundColor(.bscTextPrimary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, BSCSpacing.md)
                .padding(.vertical, BSCSpacing.sm)
                .focused($isFocused)
        }
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .background(Color.bscBackgroundMuted)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                .stroke(
                    isFocused ? Color.bscPrimary.opacity(0.5) : Color.bscSurfaceBorder,
                    lineWidth: isFocused ? 2 : 1
                )
        )
        .animation(.bscQuick, value: isFocused)
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

        Divider()
            .background(Color.bscSurfaceBorder)

        Text("Text Field")
            .font(.headline)
            .foregroundColor(.bscTextPrimary)

        BSCTextField(
            placeholder: "Enter name",
            text: .constant(""),
            icon: "person"
        )

        BSCTextField(
            placeholder: "Email",
            text: .constant("invalid@"),
            icon: "envelope",
            errorMessage: "Please enter a valid email"
        )

        Divider()
            .background(Color.bscSurfaceBorder)

        Text("Text Area")
            .font(.headline)
            .foregroundColor(.bscTextPrimary)

        BSCTextArea(
            placeholder: "Enter description...",
            text: .constant("")
        )
    }
    .padding()
    .background(Color.bscBackground)
}
