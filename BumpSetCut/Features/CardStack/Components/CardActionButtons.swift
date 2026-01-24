import SwiftUI

// MARK: - Card Action Buttons

/// Action buttons for card stack (heart to save, trash to remove)
/// Uses highPriorityGesture to prevent drag interference
struct CardActionButtons: View {
    // MARK: - Properties

    let onRemove: () -> Void
    let onSave: () -> Void

    @State private var isTrashPressed = false
    @State private var isHeartPressed = false

    // MARK: - Constants

    private let buttonSize: CGFloat = 56
    private let buttonSpacing: CGFloat = 60

    // MARK: - Body

    var body: some View {
        HStack(spacing: buttonSpacing) {
            // Trash button (left)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: buttonSize))
                    .foregroundColor(.red)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(isPressed: $isTrashPressed))
            .highPriorityGesture(TapGesture())  // Prevents parent DragGesture interference

            // Heart button (right)
            Button(action: onSave) {
                Image(systemName: "heart.circle.fill")
                    .font(.system(size: buttonSize))
                    .foregroundColor(.green)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(isPressed: $isHeartPressed))
            .highPriorityGesture(TapGesture())  // Prevents parent DragGesture interference
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 40)
    }
}

// MARK: - Pressable Button Style

/// Button style that provides visual feedback on press
private struct PressableButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.bscQuick, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, newValue in
                isPressed = newValue
            }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        VStack {
            Spacer()

            CardActionButtons(
                onRemove: { print("Removed") },
                onSave: { print("Saved") }
            )
        }
    }
}
