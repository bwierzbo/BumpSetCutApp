import SwiftUI

// MARK: - BSCNameAlert
/// Alert with a single naming TextField: strips leading whitespace while
/// typing, caps input at 100 characters, and disables confirm while the name
/// is empty. `onCommit` receives the entered name, or nil when the
/// cancel-role button (Cancel/Skip) is chosen.
struct BSCNameAlert: ViewModifier {
    let title: String
    let message: String?
    let placeholder: String
    let initialText: String
    let confirmTitle: String
    let cancelTitle: String
    @Binding var isPresented: Bool
    let onCommit: (String?) -> Void

    @State private var nameInput = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, shown in
                if shown { nameInput = initialText }
            }
            .alert(title, isPresented: $isPresented) {
                TextField(placeholder, text: $nameInput)
                    .onChange(of: nameInput) { _, newValue in
                        let stripped = String(newValue.drop(while: { $0.isWhitespace }))
                        let limited = String(stripped.prefix(100))
                        if limited != newValue {
                            nameInput = limited
                        }
                    }
                Button(confirmTitle) {
                    onCommit(nameInput)
                    nameInput = ""
                }
                .disabled(nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(cancelTitle, role: .cancel) {
                    onCommit(nil)
                    nameInput = ""
                }
            } message: {
                if let message {
                    Text(message)
                }
            }
    }
}

extension View {
    func bscNameAlert(
        title: String,
        message: String? = nil,
        placeholder: String,
        initialText: String = "",
        confirmTitle: String,
        cancelTitle: String = "Cancel",
        isPresented: Binding<Bool>,
        onCommit: @escaping (String?) -> Void
    ) -> some View {
        modifier(BSCNameAlert(
            title: title,
            message: message,
            placeholder: placeholder,
            initialText: initialText,
            confirmTitle: confirmTitle,
            cancelTitle: cancelTitle,
            isPresented: isPresented,
            onCommit: onCommit
        ))
    }
}

// MARK: - Preview
private struct BSCNameAlertPreview: View {
    @State private var isPresented = false

    var body: some View {
        BSCButton(title: "Show Name Alert", style: .primary) {
            isPresented = true
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bscBackground)
        .bscNameAlert(
            title: "Name Your Video",
            message: "Give your video a custom name",
            placeholder: "Video name",
            confirmTitle: "Upload",
            cancelTitle: "Skip",
            isPresented: $isPresented,
            onCommit: { _ in }
        )
    }
}

#Preview("BSCNameAlert") {
    BSCNameAlertPreview()
}
