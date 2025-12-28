import SwiftUI

// MARK: - BSCBreadcrumb
/// A breadcrumb navigation component for folder hierarchy
struct BSCBreadcrumb: View {
    // MARK: - Types
    struct Crumb: Identifiable {
        let id: String
        let name: String
        let path: String
        let isRoot: Bool

        init(id: String = UUID().uuidString, name: String, path: String, isRoot: Bool = false) {
            self.id = id
            self.name = name
            self.path = path
            self.isRoot = isRoot
        }
    }

    // MARK: - Properties
    let crumbs: [Crumb]
    let currentPath: String
    let onNavigate: (String) -> Void
    var showHomeIcon: Bool = true
    var maxVisibleCrumbs: Int = 4

    // MARK: - Body
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BSCSpacing.xs) {
                    // Home button
                    if showHomeIcon {
                        homeButton
                    }

                    // Breadcrumb items
                    ForEach(Array(displayCrumbs.enumerated()), id: \.element.id) { index, crumb in
                        if index > 0 || showHomeIcon {
                            separator
                        }

                        crumbButton(for: crumb, isLast: crumb.path == currentPath)
                            .id(crumb.id)
                    }
                }
                .padding(.horizontal, BSCSpacing.md)
                .padding(.vertical, BSCSpacing.sm)
            }
            .onChange(of: currentPath) { _, _ in
                if let lastCrumb = displayCrumbs.last {
                    withAnimation(.bscSpring) {
                        proxy.scrollTo(lastCrumb.id, anchor: .trailing)
                    }
                }
            }
        }
        .background(Color.bscSurfaceGlass)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.bscSurfaceBorder, lineWidth: 1)
        )
    }

    // MARK: - Display Crumbs
    private var displayCrumbs: [Crumb] {
        if crumbs.count <= maxVisibleCrumbs {
            return crumbs
        }

        // Show first, ellipsis placeholder, and last few
        var result: [Crumb] = []

        // First crumb (root)
        if let first = crumbs.first {
            result.append(first)
        }

        // Ellipsis placeholder
        result.append(Crumb(id: "ellipsis", name: "...", path: "", isRoot: false))

        // Last crumbs
        let lastCrumbs = Array(crumbs.suffix(maxVisibleCrumbs - 2))
        result.append(contentsOf: lastCrumbs)

        return result
    }

    // Hidden crumbs for ellipsis menu
    private var hiddenCrumbs: [Crumb] {
        guard crumbs.count > maxVisibleCrumbs else { return [] }
        // Get the middle crumbs that are hidden (skip first, take middle ones)
        let hiddenRange = 1..<(crumbs.count - (maxVisibleCrumbs - 2))
        return Array(crumbs[hiddenRange])
    }

    // MARK: - Home Button
    private var homeButton: some View {
        Button {
            onNavigate("")
        } label: {
            Image(systemName: "house.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(currentPath.isEmpty ? .bscOrange : .bscTextSecondary)
                .frame(width: 28, height: 28)
                .background(currentPath.isEmpty ? Color.bscOrange.opacity(0.15) : Color.clear)
                .clipShape(Circle())
        }
        .accessibilityLabel("Home")
    }

    // MARK: - Separator
    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.bscTextTertiary)
    }

    // MARK: - Crumb Button
    @ViewBuilder
    private func crumbButton(for crumb: Crumb, isLast: Bool) -> some View {
        if crumb.id == "ellipsis" {
            // Ellipsis shows a menu of hidden folders
            Menu {
                ForEach(hiddenCrumbs) { hiddenCrumb in
                    Button {
                        onNavigate(hiddenCrumb.path)
                    } label: {
                        Label(hiddenCrumb.name, systemImage: "folder")
                    }
                }
            } label: {
                Text("...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.bscBlue)
                    .padding(.horizontal, BSCSpacing.sm)
                    .padding(.vertical, BSCSpacing.xs)
                    .background(Color.bscBlue.opacity(0.1))
                    .clipShape(Capsule())
            }
            .accessibilityLabel("Show hidden folders")
            .accessibilityHint("Tap to see \(hiddenCrumbs.count) hidden folders")
        } else {
            Button {
                onNavigate(crumb.path)
            } label: {
                HStack(spacing: BSCSpacing.xs) {
                    if crumb.isRoot && !showHomeIcon {
                        Image(systemName: "house.fill")
                            .font(.system(size: 12))
                    }

                    Text(crumb.name)
                        .font(.system(size: 13, weight: isLast ? .semibold : .regular))
                        .lineLimit(1)
                }
                .foregroundColor(isLast ? .bscTextPrimary : .bscTextSecondary)
                .padding(.horizontal, BSCSpacing.sm)
                .padding(.vertical, BSCSpacing.xs)
                .background(isLast ? Color.bscBlue.opacity(0.15) : Color.clear)
                .clipShape(Capsule())
            }
            .disabled(isLast)
            .accessibilityLabel(crumb.name)
            .accessibilityHint(isLast ? "Current location" : "Navigate to \(crumb.name)")
        }
    }
}

// MARK: - Folder Path Builder
extension BSCBreadcrumb {
    /// Creates breadcrumb items from a folder path string
    static func crumbs(from folderPath: String, rootName: String = "Library") -> [Crumb] {
        var result: [Crumb] = []

        // Add root
        result.append(Crumb(name: rootName, path: "", isRoot: true))

        // Add path components
        if !folderPath.isEmpty {
            let components = folderPath.components(separatedBy: "/").filter { !$0.isEmpty }
            var currentPath = ""

            for component in components {
                currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
                result.append(Crumb(name: component, path: currentPath))
            }
        }

        return result
    }
}

// MARK: - Compact Breadcrumb
/// A simpler breadcrumb showing just parent and current
struct BSCCompactBreadcrumb: View {
    let parentName: String?
    let currentName: String
    let onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: BSCSpacing.sm) {
            if let parentName = parentName, let onBack = onBack {
                Button(action: onBack) {
                    HStack(spacing: BSCSpacing.xs) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))

                        Text(parentName)
                            .font(.system(size: 14))
                            .lineLimit(1)
                    }
                    .foregroundColor(.bscTextSecondary)
                }

                Text("/")
                    .font(.system(size: 14))
                    .foregroundColor(.bscTextTertiary)
            }

            Text(currentName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.bscTextPrimary)
                .lineLimit(1)
        }
    }
}

// MARK: - Preview
#Preview("BSCBreadcrumb") {
    VStack(spacing: BSCSpacing.xxl) {
        Text("Full Breadcrumb")
            .font(.headline)
            .foregroundColor(.bscTextPrimary)

        BSCBreadcrumb(
            crumbs: BSCBreadcrumb.crumbs(from: "Games/Beach/Summer 2024"),
            currentPath: "Games/Beach/Summer 2024",
            onNavigate: { path in
                print("Navigate to: \(path)")
            }
        )

        Text("Short Path")
            .font(.headline)
            .foregroundColor(.bscTextPrimary)

        BSCBreadcrumb(
            crumbs: BSCBreadcrumb.crumbs(from: "Games"),
            currentPath: "Games",
            onNavigate: { _ in }
        )

        Text("At Root")
            .font(.headline)
            .foregroundColor(.bscTextPrimary)

        BSCBreadcrumb(
            crumbs: BSCBreadcrumb.crumbs(from: ""),
            currentPath: "",
            onNavigate: { _ in }
        )

        Text("Compact")
            .font(.headline)
            .foregroundColor(.bscTextPrimary)

        BSCCompactBreadcrumb(
            parentName: "Beach",
            currentName: "Summer 2024",
            onBack: {}
        )
    }
    .padding()
    .background(Color.bscBackground)
}
