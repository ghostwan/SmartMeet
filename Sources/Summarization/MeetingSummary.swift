import Foundation

/// Structured minutes produced by the LLM. This is the contract shared by every
/// provider: none of them offers native structured output, so the schema is
/// imposed through the prompt and then validated on receipt.
public struct MeetingSummary: Codable, Sendable, Equatable {
    public var title: String
    public var tldr: String
    public var attendees: [String]
    public var topics: [Topic]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var openQuestions: [String]
    public var nextSteps: [String]

    // Sections specific to certain meeting types. Empty when the model wasn't
    // asked about them.

    /// What's blocking the team — a daily opens with this.
    public var blockers: [Blocker]
    /// One entry per person, for a daily.
    public var participantReports: [ParticipantReport]
    /// Named mood, for a retrospective.
    public var moods: [ParticipantMood]
    /// Sprint weather: icons, justification and comments from each member.
    public var sprintWeather: [SprintWeatherEntry]
    /// 4L format for a retrospective.
    public var fourL: FourL?

    /// Meeting type used for generation, which also drives rendering.
    public var templateID: String?

    public init(
        title: String = "",
        tldr: String = "",
        attendees: [String] = [],
        topics: [Topic] = [],
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [String] = [],
        nextSteps: [String] = [],
        blockers: [Blocker] = [],
        participantReports: [ParticipantReport] = [],
        moods: [ParticipantMood] = [],
        sprintWeather: [SprintWeatherEntry] = [],
        fourL: FourL? = nil,
        templateID: String? = nil
    ) {
        self.title = title
        self.tldr = tldr
        self.attendees = attendees
        self.topics = topics
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.nextSteps = nextSteps
        self.blockers = blockers
        self.participantReports = participantReports
        self.moods = moods
        self.sprintWeather = sprintWeather
        self.fourL = fourL
        self.templateID = templateID
    }

    private enum CodingKeys: String, CodingKey {
        case title, tldr, attendees, topics, decisions, actionItems, openQuestions, nextSteps
        case blockers, participantReports, moods, sprintWeather, fourL, templateID
    }

    /// Tolerant decoding: models regularly omit empty sections. Requiring every
    /// key would fail the whole generation for a missing `attendees`, even
    /// though the minutes were otherwise usable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        tldr = try container.decodeIfPresent(String.self, forKey: .tldr) ?? ""
        attendees = try container.decodeIfPresent([String].self, forKey: .attendees) ?? []
        topics = try container.decodeIfPresent([Topic].self, forKey: .topics) ?? []
        decisions = try container.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        openQuestions = try container.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        nextSteps = try container.decodeIfPresent([String].self, forKey: .nextSteps) ?? []
        blockers = try container.decodeIfPresent([Blocker].self, forKey: .blockers) ?? []
        participantReports = try container.decodeIfPresent(
            [ParticipantReport].self, forKey: .participantReports
        ) ?? []
        moods = try container.decodeIfPresent([ParticipantMood].self, forKey: .moods) ?? []
        sprintWeather = try container.decodeIfPresent(
            [SprintWeatherEntry].self, forKey: .sprintWeather
        ) ?? []
        fourL = try container.decodeIfPresent(FourL.self, forKey: .fourL)
        templateID = try container.decodeIfPresent(String.self, forKey: .templateID)
    }

    /// A blocker reported during the meeting.
    public struct Blocker: Codable, Sendable, Equatable, Identifiable {
        public enum Severity: String, Codable, Sendable, CaseIterable {
            case blocking = "bloquant"
            case risk = "risque"

            public var symbol: String {
                switch self {
                case .blocking: "exclamationmark.octagon.fill"
                case .risk: "exclamationmark.triangle.fill"
                }
            }
        }

        public var id: UUID
        public var person: String?
        public var description: String
        public var severity: Severity

        public init(
            id: UUID = UUID(),
            person: String? = nil,
            description: String,
            severity: Severity = .blocking
        ) {
            self.id = id
            self.person = person
            self.description = description
            self.severity = severity
        }

        private enum CodingKeys: String, CodingKey { case person, description, severity }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = UUID()
            person = try container.decodeIfPresent(String.self, forKey: .person)
            description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
            // The model sometimes drifts from the imposed vocabulary: fall back to
            // "bloquant", the costliest case to miss.
            let raw = try container.decodeIfPresent(String.self, forKey: .severity)?.lowercased()
            severity = raw.flatMap(Severity.init(rawValue:)) ?? .blocking
        }
    }

    /// One person's update during a daily.
    public struct ParticipantReport: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var person: String
        public var done: [String]
        public var next: [String]
        public var blockers: [String]

        public init(
            id: UUID = UUID(),
            person: String,
            done: [String] = [],
            next: [String] = [],
            blockers: [String] = []
        ) {
            self.id = id
            self.person = person
            self.done = done
            self.next = next
            self.blockers = blockers
        }

        private enum CodingKeys: String, CodingKey { case person, done, next, blockers }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = UUID()
            person = try container.decodeIfPresent(String.self, forKey: .person) ?? ""
            done = try container.decodeIfPresent([String].self, forKey: .done) ?? []
            next = try container.decodeIfPresent([String].self, forKey: .next) ?? []
            blockers = try container.decodeIfPresent([String].self, forKey: .blockers) ?? []
        }
    }

    /// What a person says about their sprint, along with the weather icons they chose.
    ///
    /// Named section, deliberately not summarized: it's shared with the
    /// person's manager, and must reflect what they actually expressed.
    public struct SprintWeatherEntry: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var person: String
        /// A member may pick several icons for a mixed sprint.
        public var icons: [WeatherIcon]
        /// Why these icons.
        public var explanation: String
        /// What the person says about their sprint.
        public var sprintFeedback: [String]

        public init(
            id: UUID = UUID(),
            person: String,
            icons: [WeatherIcon] = [],
            explanation: String = "",
            sprintFeedback: [String] = []
        ) {
            self.id = id
            self.person = person
            self.icons = icons
            self.explanation = explanation
            self.sprintFeedback = sprintFeedback
        }

        private enum CodingKeys: String, CodingKey {
            case person, icons, explanation, sprintFeedback
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = UUID()
            person = try container.decodeIfPresent(String.self, forKey: .person) ?? ""
            explanation = try container.decodeIfPresent(String.self, forKey: .explanation) ?? ""
            sprintFeedback = try container.decodeIfPresent(
                [String].self, forKey: .sprintFeedback
            ) ?? []
            // The model returns free-form text: it's mapped back to the controlled
            // vocabulary, ignoring anything unrecognized rather than failing.
            let raw = try container.decodeIfPresent([String].self, forKey: .icons) ?? []
            icons = raw.compactMap(WeatherIcon.parse).uniqued()
        }
    }

    /// 4L-format retrospective, depersonalized and grouped by topic.
    public struct FourL: Codable, Sendable, Equatable {
        public var liked: [Topic]
        public var learned: [Topic]
        public var lacked: [Topic]
        public var longedFor: [Topic]

        public init(
            liked: [Topic] = [],
            learned: [Topic] = [],
            lacked: [Topic] = [],
            longedFor: [Topic] = []
        ) {
            self.liked = liked
            self.learned = learned
            self.lacked = lacked
            self.longedFor = longedFor
        }

        private enum CodingKeys: String, CodingKey { case liked, learned, lacked, longedFor }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            liked = try container.decodeIfPresent([Topic].self, forKey: .liked) ?? []
            learned = try container.decodeIfPresent([Topic].self, forKey: .learned) ?? []
            lacked = try container.decodeIfPresent([Topic].self, forKey: .lacked) ?? []
            longedFor = try container.decodeIfPresent([Topic].self, forKey: .longedFor) ?? []
        }

        public var isEmpty: Bool {
            liked.isEmpty && learned.isEmpty && lacked.isEmpty && longedFor.isEmpty
        }

        /// The four axes in order, with their localized label.
        public func axes(in language: SummaryLanguage) -> [(label: String, symbol: String, topics: [Topic])] {
            [
                (language.pick(fr: "Ce qui a plu", en: "Liked"), "hand.thumbsup", liked),
                (language.pick(fr: "Ce qu'on a appris", en: "Learned"), "lightbulb", learned),
                (language.pick(fr: "Ce qui a manqué", en: "Lacked"), "exclamationmark.triangle", lacked),
                (language.pick(fr: "Ce qu'on aurait voulu", en: "Longed for"), "sparkles", longedFor),
            ]
        }
    }

    /// One person's mood during a retrospective.
    public struct ParticipantMood: Codable, Sendable, Equatable, Identifiable {
        public enum Tone: String, Codable, Sendable, CaseIterable {
            case positive = "positif"
            case neutral = "neutre"
            case negative = "négatif"

            public var symbol: String {
                switch self {
                case .positive: "face.smiling"
                case .neutral: "minus.circle"
                case .negative: "face.dashed"
                }
            }
        }

        public var id: UUID
        public var person: String
        public var mood: Tone
        public var comment: String

        public init(
            id: UUID = UUID(),
            person: String,
            mood: Tone = .neutral,
            comment: String = ""
        ) {
            self.id = id
            self.person = person
            self.mood = mood
            self.comment = comment
        }

        private enum CodingKeys: String, CodingKey { case person, mood, comment }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = UUID()
            person = try container.decodeIfPresent(String.self, forKey: .person) ?? ""
            comment = try container.decodeIfPresent(String.self, forKey: .comment) ?? ""
            let raw = try container.decodeIfPresent(String.self, forKey: .mood)?
                .lowercased()
                .folding(options: .diacriticInsensitive, locale: nil)
            mood = switch raw {
            case "positif", "positive", "positiv": .positive
            case "negatif", "negative": .negative
            default: .neutral
            }
        }
    }

    public struct Topic: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var heading: String
        public var bullets: [String]

        public init(id: UUID = UUID(), heading: String, bullets: [String]) {
            self.id = id
            self.heading = heading
            self.bullets = bullets
        }

        private enum CodingKeys: String, CodingKey { case heading, bullets }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = UUID()
            heading = try container.decodeIfPresent(String.self, forKey: .heading) ?? ""
            bullets = try container.decodeIfPresent([String].self, forKey: .bullets) ?? []
        }
    }

    /// Nature of the ticket an action item will become in Jira.
    ///
    /// Proposed by the model based on the minutes' content; it remains
    /// editable in the review window before publication.
    public enum IssueType: String, Codable, Sendable, CaseIterable, Identifiable {
        case bug
        case task
        case story
        case epic
        case initiative
        case risk

        public var id: String { rawValue }

        public var symbol: String {
            switch self {
            case .bug: "ladybug.fill"
            case .task: "checkmark.circle"
            case .story: "book.closed"
            case .epic: "flag.fill"
            case .initiative: "target"
            case .risk: "exclamationmark.triangle.fill"
            }
        }

        public func displayName(in language: SummaryLanguage) -> String {
            switch self {
            case .bug: language.pick(fr: "Bug", en: "Bug")
            case .task: language.pick(fr: "Tâche", en: "Task")
            case .story: language.pick(fr: "Story", en: "Story")
            case .epic: language.pick(fr: "Epic", en: "Epic")
            case .initiative: language.pick(fr: "Initiative", en: "Initiative")
            case .risk: language.pick(fr: "Risque", en: "Risk")
            }
        }

        /// Name of the corresponding Jira issue type, as expected by the API.
        /// Not every Jira project has a "Risk" type: stays editable in settings
        /// or directly in the review window if the target project uses different
        /// vocabulary.
        public var defaultJiraIssueTypeName: String {
            switch self {
            case .bug: "Bug"
            case .task: "Task"
            case .story: "Story"
            case .epic: "Epic"
            case .initiative: "Initiative"
            case .risk: "Risk"
            }
        }

        /// Recognizes a free-form value returned by the model, in French or
        /// English, with a few common spelling variants.
        public static func parse(_ raw: String?) -> IssueType? {
            guard let normalized = raw?
                .lowercased()
                .folding(options: .diacriticInsensitive, locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            else { return nil }
            switch normalized {
            case "bug", "anomalie", "defaut", "défaut": return .bug
            case "task", "tache", "tâche": return .task
            case "story", "histoire", "user story": return .story
            case "epic", "epopee", "épopée": return .epic
            case "initiative": return .initiative
            case "risk", "risque": return .risk
            default: return nil
            }
        }

        /// Fallback classification when the model omits `issueType` or returns
        /// an unrecognized value: a few keywords are enough to steer the most
        /// frequent cases, with a generic `task` covering the rest.
        public static func detect(from description: String) -> IssueType {
            let text = description
                .lowercased()
                .folding(options: .diacriticInsensitive, locale: nil)

            let bugWords = [
                "bug", "erreur", "crash", "plante", "casse", "cassé", "ne fonctionne pas",
                "ne marche pas", "regression", "défaut", "defaut", "anomalie",
            ]
            let riskWords = ["risque", "risk", "menace", "danger"]
            let epicWords = ["epic", "chantier", "gros chantier"]
            let initiativeWords = ["initiative", "programme", "objectif strategique", "objectif stratégique"]
            let storyWords = ["story", "user story", "fonctionnalite", "fonctionnalité", "feature"]

            if bugWords.contains(where: text.contains) { return .bug }
            if riskWords.contains(where: text.contains) { return .risk }
            if epicWords.contains(where: text.contains) { return .epic }
            if initiativeWords.contains(where: text.contains) { return .initiative }
            if storyWords.contains(where: text.contains) { return .story }
            return .task
        }
    }

    public struct ActionItem: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var owner: String?
        public var description: String
        public var dueDate: String?
        /// Checked in the review window: only these items become tickets.
        public var isSelected: Bool
        /// Nature of the ticket to create, proposed by the model and editable
        /// before publication.
        public var issueType: IssueType
        /// Filled in after publication.
        public var jiraKey: String?
        public var notionTaskURL: String?

        public init(
            id: UUID = UUID(),
            owner: String? = nil,
            description: String,
            dueDate: String? = nil,
            isSelected: Bool = true,
            issueType: IssueType = .task,
            jiraKey: String? = nil,
            notionTaskURL: String? = nil
        ) {
            self.id = id
            self.owner = owner
            self.description = description
            self.dueDate = dueDate
            self.isSelected = isSelected
            self.issueType = issueType
            self.jiraKey = jiraKey
            self.notionTaskURL = notionTaskURL
        }

        private enum CodingKeys: String, CodingKey {
            case owner, description, dueDate, isSelected, issueType, jiraKey, notionTaskURL
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = UUID()
            owner = try container.decodeIfPresent(String.self, forKey: .owner)
            description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
            dueDate = try container.decodeIfPresent(String.self, forKey: .dueDate)
            isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected) ?? true
            let rawIssueType = try container.decodeIfPresent(String.self, forKey: .issueType)
            issueType = IssueType.parse(rawIssueType) ?? IssueType.detect(from: description)
            jiraKey = try container.decodeIfPresent(String.self, forKey: .jiraKey)
            notionTaskURL = try container.decodeIfPresent(String.self, forKey: .notionTaskURL)
        }
    }
}

public extension MeetingSummary {
    /// Minimal consistency check: minutes without a title signal a failed
    /// generation, even if the JSON is syntactically valid.
    ///
    /// The summary isn't required: a daily puts blockers first and relegates
    /// `tldr` to the end, when it requests one at all.
    var isUsable: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !tldr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !blockers.isEmpty
            || !participantReports.isEmpty
            || !moods.isEmpty
            || !sprintWeather.isEmpty
            || !(fourL?.isEmpty ?? true)
            || !topics.isEmpty
            || !decisions.isEmpty
            || !actionItems.isEmpty
    }

    /// True if the section has something to display.
    func hasContent(_ section: SummarySection) -> Bool {
        switch section {
        case .tldr: !tldr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .blockers: !blockers.isEmpty
        case .participantReports: !participantReports.isEmpty
        case .moods: !moods.isEmpty
        case .sprintWeather: !sprintWeather.isEmpty
        case .fourL: !(fourL?.isEmpty ?? true)
        case .topics: !topics.isEmpty
        case .decisions: !decisions.isEmpty
        case .actionItems: !actionItems.isEmpty
        case .openQuestions: !openQuestions.isEmpty
        case .nextSteps: !nextSteps.isEmpty
        }
    }

    /// Markdown rendering in the order of the meeting type's sections.
    func markdown(
        template: MeetingTemplate = .generic,
        language: SummaryLanguage = .french
    ) -> String {
        var output = "# \(title)\n\n"
        if !attendees.isEmpty {
            let label = language.pick(fr: "Participants", en: "Attendees")
            output += "**\(label) :** \(attendees.joined(separator: ", "))\n\n"
        }

        for section in template.sections where hasContent(section) {
            let heading = section.displayName(in: language)
            switch section {
            case .tldr:
                output += "\(tldr)\n\n"

            case .blockers:
                output += "## \(heading)\n\n"
                for blocker in blockers {
                    let marker = blocker.severity == .blocking ? "🛑" : "⚠️"
                    let who = blocker.person.map { "**\($0)** — " } ?? ""
                    output += "- \(marker) \(who)\(blocker.description)\n"
                }
                output += "\n"

            case .participantReports:
                output += "## \(heading)\n\n"
                for report in participantReports {
                    output += "### \(report.person)\n\n"
                    if !report.done.isEmpty {
                        output += "_Fait :_\n" + report.done.map { "- \($0)\n" }.joined()
                    }
                    if !report.next.isEmpty {
                        output += "_À venir :_\n" + report.next.map { "- \($0)\n" }.joined()
                    }
                    if !report.blockers.isEmpty {
                        output += "_Bloqué par :_\n" + report.blockers.map { "- \($0)\n" }.joined()
                    }
                    output += "\n"
                }

            case .moods:
                output += "## \(heading)\n\n"
                for mood in moods {
                    let icon = switch mood.mood {
                    case .positive: "🙂"
                    case .neutral: "😐"
                    case .negative: "🙁"
                    }
                    output += "- \(icon) **\(mood.person)** — \(mood.comment)\n"
                }
                output += "\n"

            case .sprintWeather:
                output += "## \(heading)\n\n"
                for entry in sprintWeather {
                    let icons = entry.icons.map(\.emoji).joined(separator: " ")
                    output += "### \(icons.isEmpty ? "" : icons + " ")\(entry.person)\n\n"
                    if !entry.explanation.isEmpty {
                        output += "\(entry.explanation)\n\n"
                    }
                    for point in entry.sprintFeedback {
                        output += "- \(point)\n"
                    }
                    output += "\n"
                }

            case .fourL:
                guard let fourL else { break }
                output += "## \(heading)\n\n"
                for axis in fourL.axes(in: language) where !axis.topics.isEmpty {
                    output += "### \(axis.label)\n\n"
                    for topic in axis.topics {
                        if !topic.heading.isEmpty {
                            output += "**\(topic.heading)**\n\n"
                        }
                        output += topic.bullets.map { "- \($0)\n" }.joined()
                        output += "\n"
                    }
                }

            case .topics:
                for topic in topics where !topic.heading.isEmpty {
                    output += "## \(topic.heading)\n\n"
                    output += topic.bullets.map { "- \($0)\n" }.joined()
                    output += "\n"
                }

            case .decisions:
                output += "## \(heading)\n\n"
                output += decisions.map { "- \($0)\n" }.joined() + "\n"

            case .actionItems:
                output += "## \(heading)\n\n"
                for item in actionItems {
                    let owner = item.owner.map { "**\($0)** — " } ?? ""
                    let due = item.dueDate.map { " _(échéance \($0))_" } ?? ""
                    let key = item.jiraKey.map { " [\($0)]" } ?? ""
                    let type = "_[\(item.issueType.displayName(in: language))]_ "
                    output += "- \(type)\(owner)\(item.description)\(due)\(key)\n"
                }
                output += "\n"

            case .openQuestions:
                output += "## \(heading)\n\n"
                output += openQuestions.map { "- \($0)\n" }.joined() + "\n"

            case .nextSteps:
                output += "## \(heading)\n\n"
                output += nextSteps.map { "- \($0)\n" }.joined() + "\n"
            }
        }
        return output
    }

    /// Rendering using the meeting type stored in the minutes.
    var markdown: String {
        markdown(template: MeetingTemplate.resolve(id: templateID, in: []))
    }
}
