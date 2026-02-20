import SwiftUI

struct PollView: View {
    let poll: Poll
    let isAuthor: Bool
    let isAuthenticated: Bool
    let onVote: (String) -> Void

    private var hasVoted: Bool { poll.myVoteOptionId != nil }
    private var showResults: Bool { hasVoted || isAuthor }

    var body: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.sm) {
            Text(poll.question)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)

            ForEach(poll.options.sorted { $0.sortOrder < $1.sortOrder }) { option in
                if showResults {
                    resultBar(option: option)
                } else {
                    voteButton(option: option)
                }
            }

            Text("\(poll.totalVotes) vote\(poll.totalVotes == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(BSCSpacing.sm)
        .frame(maxWidth: 260)
        .background(.ultraThinMaterial.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
    }

    // MARK: - Vote Button (pre-vote)

    private func voteButton(option: PollOption) -> some View {
        Button {
            guard isAuthenticated else { return }
            onVote(option.id)
        } label: {
            Text(option.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, BSCSpacing.sm)
                .padding(.vertical, BSCSpacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous)
                        .stroke(Color.white.opacity(0.5), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Result Bar (post-vote / author)

    private func resultBar(option: PollOption) -> some View {
        let fraction = poll.totalVotes > 0 ? Double(option.voteCount) / Double(poll.totalVotes) : 0
        let percentage = Int(fraction * 100)
        let isMyVote = option.id == poll.myVoteOptionId

        return HStack(spacing: BSCSpacing.xs) {
            Text(option.text)
                .font(.system(size: 13, weight: isMyVote ? .bold : .medium))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer()

            Text("\(percentage)%")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(isMyVote ? .bscPrimary : .white.opacity(0.8))
        }
        .padding(.horizontal, BSCSpacing.sm)
        .padding(.vertical, BSCSpacing.xs)
        .background(
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous)
                    .fill(isMyVote ? Color.bscPrimary.opacity(0.4) : Color.white.opacity(0.15))
                    .frame(width: geo.size.width * fraction)
            }
        )
        .background(
            RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }
}
