import Foundation

/// The user's content identity (§6). Separate from ContentStrategy so one voice
/// can serve several strategies, and so a user can keep distinct voices.
public struct VoiceProfile: Sendable, Hashable, Codable, Identifiable {
    public let id: Identifier<VoiceProfile>
    public let userID: Identifier<User>
    public var name: String
    /// Free-text instruction, which carries nuance no slider can.
    public var instruction: String
    public var axes: VoiceAxes
    public var emojiUsage: EmojiUsage
    public var hashtagStyle: HashtagStyle
    /// Per-platform output language, as BCP-47 tags. The brief's example is
    /// English on Instagram and Simplified Chinese on Xiaohongshu.
    public var languageByPlatform: [Platform: String]
    public var preferredVocabulary: [String]
    /// Words and phrases never to use. Enforced as a hard filter, not a hint,
    /// because "avoid clickbait" fails silently otherwise.
    public var bannedPhrases: [String]

    public init(
        id: Identifier<VoiceProfile> = Identifier(),
        userID: Identifier<User>,
        name: String,
        instruction: String,
        axes: VoiceAxes = .init(),
        emojiUsage: EmojiUsage = .sparing,
        hashtagStyle: HashtagStyle = .moderate,
        languageByPlatform: [Platform: String] = [:],
        preferredVocabulary: [String] = [],
        bannedPhrases: [String] = []
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.instruction = instruction
        self.axes = axes
        self.emojiUsage = emojiUsage
        self.hashtagStyle = hashtagStyle
        self.languageByPlatform = languageByPlatform
        self.preferredVocabulary = preferredVocabulary
        self.bannedPhrases = bannedPhrases
    }

    /// Output language for a platform, defaulting to English when unset.
    public func language(for platform: Platform) -> String {
        languageByPlatform[platform] ?? "en"
    }
}

/// The brief's tone dimensions (§6), each 0...1. Continuous rather than
/// categorical so that "mostly casual but still informative" is expressible.
public struct VoiceAxes: Sendable, Hashable, Codable {
    /// 0 = formal, 1 = casual.
    public var casualness: Double
    /// 0 = entertaining, 1 = educational.
    public var educational: Double
    /// 0 = concise, 1 = descriptive.
    public var descriptiveness: Double
    /// 0 = serious, 1 = humorous.
    public var humour: Double
    /// 0 = editorial, 1 = personal.
    public var personal: Double

    public init(
        casualness: Double = 0.5,
        educational: Double = 0.5,
        descriptiveness: Double = 0.5,
        humour: Double = 0.3,
        personal: Double = 0.6
    ) {
        self.casualness = casualness.clamped(to: 0...1)
        self.educational = educational.clamped(to: 0...1)
        self.descriptiveness = descriptiveness.clamped(to: 0...1)
        self.humour = humour.clamped(to: 0...1)
        self.personal = personal.clamped(to: 0...1)
    }
}

public enum EmojiUsage: String, Codable, Sendable, CaseIterable, Hashable {
    case none
    case sparing
    case moderate
    case liberal
}

public enum HashtagStyle: String, Codable, Sendable, CaseIterable, Hashable {
    case none
    /// A handful of specific, relevant tags.
    case minimal
    case moderate
    /// Many tags, as is conventional on some platforms.
    case extensive

    /// Suggested count, capped by the platform's own limit at generation time.
    public var suggestedCount: Int {
        switch self {
        case .none: return 0
        case .minimal: return 3
        case .moderate: return 8
        case .extensive: return 20
        }
    }
}

/// `[Platform: String]` needs explicit coding because Swift encodes dictionaries
/// with non-String keys as a flat array, which is awkward to read in Postgres
/// JSONB and brittle to hand-edit. This keeps it a real JSON object.
extension VoiceProfile {
    private enum CodingKeys: String, CodingKey {
        case id, userID, name, instruction, axes, emojiUsage, hashtagStyle
        case languageByPlatform, preferredVocabulary, bannedPhrases
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(Identifier<VoiceProfile>.self, forKey: .id)
        self.userID = try c.decode(Identifier<User>.self, forKey: .userID)
        self.name = try c.decode(String.self, forKey: .name)
        self.instruction = try c.decode(String.self, forKey: .instruction)
        self.axes = try c.decodeIfPresent(VoiceAxes.self, forKey: .axes) ?? .init()
        self.emojiUsage = try c.decodeIfPresent(EmojiUsage.self, forKey: .emojiUsage) ?? .sparing
        self.hashtagStyle = try c.decodeIfPresent(HashtagStyle.self, forKey: .hashtagStyle) ?? .moderate
        self.preferredVocabulary = try c.decodeIfPresent([String].self, forKey: .preferredVocabulary) ?? []
        self.bannedPhrases = try c.decodeIfPresent([String].self, forKey: .bannedPhrases) ?? []

        let raw = try c.decodeIfPresent([String: String].self, forKey: .languageByPlatform) ?? [:]
        var mapped: [Platform: String] = [:]
        for (key, value) in raw {
            // An unknown platform key is skipped rather than fatal: a newer
            // client may have written a platform this build does not know.
            if let platform = Platform(rawValue: key) {
                mapped[platform] = value
            }
        }
        self.languageByPlatform = mapped
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userID, forKey: .userID)
        try c.encode(name, forKey: .name)
        try c.encode(instruction, forKey: .instruction)
        try c.encode(axes, forKey: .axes)
        try c.encode(emojiUsage, forKey: .emojiUsage)
        try c.encode(hashtagStyle, forKey: .hashtagStyle)
        try c.encode(preferredVocabulary, forKey: .preferredVocabulary)
        try c.encode(bannedPhrases, forKey: .bannedPhrases)
        let raw = Dictionary(uniqueKeysWithValues: languageByPlatform.map { ($0.key.rawValue, $0.value) })
        try c.encode(raw, forKey: .languageByPlatform)
    }
}
