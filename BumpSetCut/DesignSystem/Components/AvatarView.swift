import SwiftUI

// MARK: - Avatar View

/// Reusable avatar component that loads a remote image with initial-letter fallback.
struct AvatarView: View {
    let url: URL?
    let name: String
    let size: CGFloat

    init(url: URL? = nil, name: String, size: CGFloat = 44) {
        self.url = url
        self.name = name
        self.size = size
    }

    var body: some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                case .failure:
                    fallbackInitial
                default:
                    fallbackInitial
                        .overlay(
                            ProgressView()
                                .tint(.bscTextTertiary)
                                .scaleEffect(size > 50 ? 0.8 : 0.6)
                        )
                }
            }
        } else {
            fallbackInitial
        }
    }

    private var fallbackInitial: some View {
        Circle()
            .fill(Color.bscSurfaceGlass)
            .frame(width: size, height: size)
            .overlay(
                Text(name.prefix(1).uppercased())
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundColor(.bscOrange)
            )
    }
}
