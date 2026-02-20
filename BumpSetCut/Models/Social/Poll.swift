import Foundation

// MARK: - Poll Option

struct PollOption: Codable, Identifiable, Hashable {
    let id: String
    let pollId: String
    var text: String
    var voteCount: Int
    let sortOrder: Int

    init(id: String = UUID().uuidString.lowercased(), pollId: String, text: String,
         voteCount: Int = 0, sortOrder: Int = 0) {
        self.id = id
        self.pollId = pollId
        self.text = text
        self.voteCount = voteCount
        self.sortOrder = sortOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        pollId = try container.decode(String.self, forKey: .pollId)
        text = try container.decode(String.self, forKey: .text)
        voteCount = try container.decodeIfPresent(Int.self, forKey: .voteCount) ?? 0
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case id, pollId, text, voteCount, sortOrder
    }
}

// MARK: - Poll

struct Poll: Codable, Identifiable, Hashable {
    let id: String
    let highlightId: String
    var question: String
    var totalVotes: Int
    var options: [PollOption]
    var myVoteOptionId: String?

    init(id: String = UUID().uuidString.lowercased(), highlightId: String, question: String,
         totalVotes: Int = 0, options: [PollOption] = [], myVoteOptionId: String? = nil) {
        self.id = id
        self.highlightId = highlightId
        self.question = question
        self.totalVotes = totalVotes
        self.options = options
        self.myVoteOptionId = myVoteOptionId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        highlightId = try container.decode(String.self, forKey: .highlightId)
        question = try container.decode(String.self, forKey: .question)
        totalVotes = try container.decodeIfPresent(Int.self, forKey: .totalVotes) ?? 0
        options = try container.decodeIfPresent([PollOption].self, forKey: .options) ?? []
        myVoteOptionId = try container.decodeIfPresent(String.self, forKey: .myVoteOptionId)
    }

    private enum CodingKeys: String, CodingKey {
        case id, highlightId, question, totalVotes, options, myVoteOptionId
    }
}

// MARK: - Upload Types

struct PollUpload: Codable {
    let highlightId: String
    let question: String
}

struct PollOptionUpload: Codable {
    let pollId: String
    let text: String
    let sortOrder: Int
}

struct PollVoteUpload: Codable {
    let pollId: String
    let optionId: String
    let userId: String
}
