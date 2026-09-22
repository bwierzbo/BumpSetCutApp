import SwiftUI

// MARK: - Toast Message
struct BSCToastMessage: Equatable {
    enum Style {
        case success
        case error
        case info

        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .error: return "exclamationmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .success: return .bscSuccessText
            case .error: return .bscErrorText
            case .info: return .bscPrimaryText
            }
        }
    }

    let text: String
    var style: Style = .info
    /// Optional trailing button — e.g. "View" on "Sent to @x". Tapping runs the
    /// handler and dismisses the toast.
    var action: BSCToastAction? = nil

    // Closures aren't Equatable; two toasts are the same toast when their
    // visible content is.
    static func == (lhs: BSCToastMessage, rhs: BSCToastMessage) -> Bool {
        lhs.text == rhs.text && lhs.style == rhs.style && lhs.action?.title == rhs.action?.title
    }
}

struct BSCToastAction {
    let title: String
    let handler: () -> Void
}

// MARK: - View Modifier
extension View {
    /// Transient feedback toast anchored to the bottom of the view. Set the
    /// binding to show; it auto-dismisses after `duration` and plays the
    /// matching notification haptic. Use for outcomes that would otherwise be
    /// silent (failed optimistic updates, background operation results).
    func bscToast(_ message: Binding<BSCToastMessage?>, duration: TimeInterval = 2.5) -> some View {
        modifier(BSCToastModifier(message: message, duration: duration))
    }
}

private struct BSCToastModifier: ViewModifier {
    @Binding var message: BSCToastMessage?
    let duration: TimeInterval

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = message {
                    HStack(spacing: BSCSpacing.sm) {
                        Image(systemName: toast.style.icon)
                            .bscFont(size: 16, weight: .semibold)
                            .foregroundColor(toast.style.tint)
                            .accessibilityHidden(true)
                        Text(toast.text)
                            .bscFont(size: 14, weight: .semibold)
                            .foregroundColor(.bscTextPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if let action = toast.action {
                            Button(action.title) {
                                message = nil
                                action.handler()
                            }
                            .bscFont(size: 14, weight: .bold)
                            .foregroundColor(.bscPrimaryText)
                            .padding(.leading, BSCSpacing.xs)
                        }
                    }
                    .padding(.horizontal, BSCSpacing.lg)
                    .padding(.vertical, BSCSpacing.md)
                    .background(Capsule().fill(Color.bscBackgroundElevated))
                    .overlay(Capsule().stroke(Color.bscSurfaceBorder, lineWidth: 1))
                    .bscShadow(BSCShadow.md)
                    .padding(.horizontal, BSCSpacing.lg)
                    .padding(.bottom, BSCSpacing.xl)
                    .transition(.bscSlideUp)
                    // Combined into one element normally; with an action the
                    // button must stay its own element or VoiceOver can't reach it.
                    .accessibilityElement(children: toast.action == nil ? .combine : .contain)
                    .task(id: toast) {
                        switch toast.style {
                        case .success:
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        case .error:
                            UINotificationFeedbackGenerator().notificationOccurred(.error)
                        case .info:
                            break
                        }
                        UIAccessibility.post(notification: .announcement, argument: toast.text)
                        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                        message = nil
                    }
                }
            }
            .animation(.bscStandard, value: message)
    }
}
