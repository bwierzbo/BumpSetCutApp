import SwiftUI

struct PollView: View {
    let poll: Poll
    let isAuthenticated: Bool
    let onVote: (String) -> Void

    private var hasVoted: Bool { poll.myVoteOptionId != nil }
    // Everyone (including the poll's author) votes first, then sees results.
    private var showResults: Bool { hasVoted }

    var body: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.sm) {
            Text(poll.question)
                .bscFont(size: 15, weight: .semibold)
                .foregroundColor(.bscTextPrimary)
                .lineLimit(3)

            ForEach(poll.options.sorted { $0.sortOrder < $1.sortOrder }) { option in
                optionRow(option: option)
            }

            Text("\(poll.totalVotes) vote\(poll.totalVotes == 1 ? "" : "s") \u{00B7} tap to \(hasVoted ? "change" : "vote")")
                .bscFont(size: 12)
                .foregroundColor(.bscTextSecondary)
        }
        .padding(BSCSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bscSurfaceGlass)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                .stroke(Color.bscSurfaceBorder, lineWidth: 1)
        )
        // Animate the buttons↔results swap and bar fills when the vote changes.
        .animation(.bscSnappy, value: poll.myVoteOptionId)
        .animation(.bscSnappy, value: poll.totalVotes)
    }

    // MARK: - Option Row (tappable to vote or change vote)

    private func optionRow(option: PollOption) -> some View {
        Button {
            guard isAuthenticated else { return }
            UIImpactFeedbackGenerator.light()
            onVote(option.id)
        } label: {
            if showResults {
                resultBarLabel(option: option)
            } else {
                voteButtonLabel(option: option)
            }
        }
        .buttonStyle(PollOptionButtonStyle())
        .disabled(!isAuthenticated)
    }

    private func voteButtonLabel(option: PollOption) -> some View {
        Text(option.text)
            .bscFont(size: 14, weight: .medium)
            .foregroundColor(.bscPrimaryText)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BSCSpacing.md)
            .padding(.vertical, BSCSpacing.sm)
            .frame(minHeight: BSCTouchTarget.standard)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous)
                    .stroke(Color.bscPrimary, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }

    private func resultBarLabel(option: PollOption) -> some View {
        let fraction = poll.totalVotes > 0 ? Double(option.voteCount) / Double(poll.totalVotes) : 0
        let percentage = Int(fraction * 100)
        let isMyVote = option.id == poll.myVoteOptionId

        return HStack(spacing: BSCSpacing.xs) {
            if isMyVote {
                Image(systemName: "checkmark.circle.fill")
                    .bscFont(size: 13)
                    .foregroundColor(.bscPrimaryText)
            }
            Text(option.text)
                .bscFont(size: 14, weight: isMyVote ? .bold : .medium)
                .foregroundColor(.bscTextPrimary)
                .lineLimit(1)

            Spacer()

            Text("\(percentage)%")
                .bscFont(size: 13, weight: .bold)
                .foregroundColor(isMyVote ? .bscPrimaryText : .bscTextSecondary)
        }
        .padding(.horizontal, BSCSpacing.md)
        .padding(.vertical, BSCSpacing.sm)
        .frame(minHeight: BSCTouchTarget.standard)
        .background(
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous)
                    .fill(isMyVote ? Color.bscPrimary.opacity(0.3) : Color.bscPrimarySubtle)
                    .frame(width: geo.size.width * fraction)
            }
        )
        .background(
            RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous)
                .fill(Color.bscSurfaceGlass)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Press Feedback

private struct PollOptionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.bscQuick, value: configuration.isPressed)
    }
}
