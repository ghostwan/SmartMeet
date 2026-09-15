import Atlassian
import Foundation
import Notion
import Observation
import Summarization

/// Settings persisted in `UserDefaults`, excluding secrets which go to the keychain.
@MainActor
@Observable
public final class AppSettings {
    private enum Key {
        static let provider = "summaryProvider"
        static let opencodeModel = "opencodeModel"
        static let copilotACPModel = "copilotACPModel"
        static let ollamaModel = "ollamaModel"
        static let claudeCodeModel = "claudeCodeModel"
        static let locale = "transcriptionLocale"
        static let vocabulary = "vocabulary"
        static let knownPeople = "knownPeople"
        static let atlassian = "atlassianConfiguration"
        static let autoSummarize = "autoSummarize"
        static let useCalendar = "useCalendar"
        static let customTemplates = "customTemplates"
        static let defaultTemplate = "defaultTemplateID"
        static let userName = "userName"
        static let outputLanguage = "outputLanguage"
        static let detectMeetings = "detectMeetings"
        static let autoStartOnDetection = "autoStartOnDetection"
        static let detectMeetingEnd = "detectMeetingEnd"
        static let autoPublish = "autoPublish"
        static let autoCreateJiraIssues = "autoCreateJiraIssues"
        static let diarizeMicrophoneTrack = "diarizeMicrophoneTrack"
        static let notion = "notionConfiguration"
        static let disabledTemplateIDs = "disabledTemplateIDs"
        static let recentTranscriptionLocales = "recentTranscriptionLocales"
        static let profiles = "profiles"
        static let activeProfileID = "activeProfileID"
        static let enabledServices = "enabledServices"
        static let profileKnownPeopleMigrated = "profileKnownPeopleMigrated"
    }

    private let defaults = UserDefaults.standard
    private let keychain = KeychainStore()
    private let notionKeychain = KeychainStore(service: "com.smartmeet.notion")
    /// Keychain-backed values still need an in-memory observable copy:
    /// writing directly to the keychain doesn't invalidate SwiftUI views.
    /// Without these caches, `canPublishToNotion` stayed false after typing a
    /// token until some unrelated state change (such as switching services)
    /// happened to refresh the screen.
    private var cachedAtlassianToken = ""
    private var cachedNotionToken = ""
    /// Legacy fixed account name, from before tokens were scoped per profile.
    /// Kept only so the one-time migration in `init()` can find a
    /// pre-existing token to carry over to the seed profile's own account.
    static let legacyTokenAccount = "atlassian-api-token"
    static let legacyNotionTokenAccount = "notion-integration-token"

    /// Per-profile account name: each profile can point at a different
    /// Atlassian site / Notion workspace with its own token.
    static func tokenAccount(for profileID: String) -> String {
        "atlassian-api-token.\(profileID)"
    }
    static func notionTokenAccount(for profileID: String) -> String {
        "notion-integration-token.\(profileID)"
    }

    public var providerKind: SummaryProviderKind {
        didSet { defaults.set(providerKind.rawValue, forKey: Key.provider) }
    }
    public var opencodeModel: String {
        didSet { defaults.set(opencodeModel, forKey: Key.opencodeModel) }
    }
    public var copilotACPModel: String {
        didSet { defaults.set(copilotACPModel, forKey: Key.copilotACPModel) }
    }
    public var ollamaModel: String {
        didSet { defaults.set(ollamaModel, forKey: Key.ollamaModel) }
    }
    public var claudeCodeModel: String {
        didSet { defaults.set(claudeCodeModel, forKey: Key.claudeCodeModel) }
    }
    /// Spoken language expected during transcription for the active profile.
    public var localeIdentifier: String {
        get { activeProfile.localeIdentifier }
        set {
            var profile = activeProfile
            profile.localeIdentifier = newValue
            activeProfile = profile
        }
    }
    /// Recently used spoken languages under the active profile, most recent
    /// first — lets them surface at the top of the picker instead of getting
    /// lost in the framework's full list of supported locales.
    public var recentTranscriptionLocales: [String] {
        get { activeProfile.recentTranscriptionLocales }
        set {
            var profile = activeProfile
            profile.recentTranscriptionLocales = newValue
            activeProfile = profile
        }
    }
    /// Profiles (Work, Personal…), each scoping its own meeting types,
    /// vocabulary, behavior preferences, service credentials, and default
    /// publication service.
    public var profiles: [Profile] {
        didSet {
            guard let data = try? JSONEncoder().encode(profiles) else { return }
            defaults.set(data, forKey: Key.profiles)
        }
    }
    /// Profile currently in effect — drives `vocabulary`, `customTemplates`,
    /// `allTemplates`, `defaultTemplateID` below, all of which proxy into it.
    public var activeProfileID: String {
        didSet {
            defaults.set(activeProfileID, forKey: Key.activeProfileID)
            cachedAtlassianToken = keychain.read(
                account: Self.tokenAccount(for: activeProfileID)
            ) ?? ""
            cachedNotionToken = notionKeychain.read(
                account: Self.notionTokenAccount(for: activeProfileID)
            ) ?? ""
        }
    }
    /// Publication services added under the active profile. Notion and
    /// Atlassian's own settings (tokens, sites, pages…) stay stored
    /// separately per profile regardless of this set, so removing a service
    /// here only hides it — it doesn't wipe its configuration, in case it's
    /// added back later under the same profile.
    public var enabledServices: Set<ServiceKind> {
        get { activeProfile.enabledServices }
        set {
            var profile = activeProfile
            profile.enabledServices = newValue
            activeProfile = profile
        }
    }
    /// Domain vocabulary specific to the active profile, injected into speech
    /// recognition and the minutes prompt.
    public var vocabulary: [String] {
        get { activeProfile.vocabulary }
        set {
            var profile = activeProfile
            profile.vocabulary = newValue
            activeProfile = profile
        }
    }
    /// First (and last) names associated with the active profile. Kept
    /// separate from domain vocabulary for readability, but used the same
    /// way by speech recognition and the minutes prompt.
    public var knownPeople: [String] {
        get { activeProfile.knownPeople }
        set {
            var profile = activeProfile
            profile.knownPeople = newValue
            activeProfile = profile
        }
    }
    /// User's name: the transcript only knows them by the label "Moi" ("Me").
    public var userName: String {
        didSet { defaults.set(userName, forKey: Key.userName) }
    }
    /// Default language proposed for the minutes under the active profile.
    public var defaultOutputLanguage: SummaryLanguage {
        get { activeProfile.defaultOutputLanguage }
        set {
            var profile = activeProfile
            profile.defaultOutputLanguage = newValue
            profile.enabledOutputLanguages.insert(newValue)
            activeProfile = profile
        }
    }
    /// Minutes languages offered under the active profile.
    public var enabledOutputLanguages: Set<SummaryLanguage> {
        get { activeProfile.enabledOutputLanguages }
        set {
            var profile = activeProfile
            let normalized = newValue.isEmpty ? [SummaryLanguage.english] : newValue
            profile.enabledOutputLanguages = normalized
            if !normalized.contains(profile.defaultOutputLanguage) {
                profile.defaultOutputLanguage = Self.orderedOutputLanguages(in: normalized)[0]
            }
            activeProfile = profile
        }
    }

    public var availableOutputLanguages: [SummaryLanguage] {
        Self.orderedOutputLanguages(in: enabledOutputLanguages)
    }

    public func setOutputLanguage(_ language: SummaryLanguage, enabled: Bool) {
        var languages = enabledOutputLanguages
        if enabled {
            languages.insert(language)
        } else if languages.count > 1 {
            languages.remove(language)
        }
        enabledOutputLanguages = languages
    }

    private static func orderedOutputLanguages(
        in languages: Set<SummaryLanguage>
    ) -> [SummaryLanguage] {
        SummaryLanguage.allCases.filter { languages.contains($0) }
    }
    /// Suggests recording when a meeting is detected, under the active profile.
    public var detectMeetings: Bool {
        get { activeProfile.detectMeetings }
        set {
            var profile = activeProfile
            profile.detectMeetings = newValue
            activeProfile = profile
        }
    }
    /// Starts without asking. Deliberately off by default: recording people
    /// without their knowledge isn't a behavior you turn on on their behalf.
    public var autoStartOnDetection: Bool {
        get { activeProfile.autoStartOnDetection }
        set {
            var profile = activeProfile
            profile.autoStartOnDetection = newValue
            activeProfile = profile
        }
    }
    /// Suggests (never forces) stopping and generating the minutes when the
    /// tracked video-conferencing app has stopped picking up the microphone
    /// for a while. On by default: it's just a notification, symmetric to
    /// `detectMeetings` — unlike `autoStartOnDetection`, nothing is stopped
    /// without the user explicitly requesting it by tapping the action.
    public var detectMeetingEnd: Bool {
        get { activeProfile.detectMeetingEnd }
        set {
            var profile = activeProfile
            profile.detectMeetingEnd = newValue
            activeProfile = profile
        }
    }
    public var autoSummarize: Bool {
        get { activeProfile.autoSummarize }
        set {
            var profile = activeProfile
            profile.autoSummarize = newValue
            activeProfile = profile
        }
    }
    /// Publishes to Confluence without review. Off by default: the minutes
    /// are generated by a model, they deserve a look before landing on a
    /// team space.
    public var autoPublish: Bool {
        get { activeProfile.autoPublish }
        set {
            var profile = activeProfile
            profile.autoPublish = newValue
            activeProfile = profile
        }
    }
    /// Also creates Jira tickets during an automatic publication.
    public var autoCreateJiraIssues: Bool {
        get { activeProfile.autoCreateJiraIssues }
        set {
            var profile = activeProfile
            profile.autoCreateJiraIssues = newValue
            activeProfile = profile
        }
    }
    public var autoCreateNotionTasks: Bool {
        get { activeProfile.autoCreateNotionTasks }
        set {
            var profile = activeProfile
            profile.autoCreateNotionTasks = newValue
            activeProfile = profile
        }
    }
    public var useCalendar: Bool {
        didSet { defaults.set(useCalendar, forKey: Key.useCalendar) }
    }
    /// Experimental microphone-track diarization: distinguishes up to two
    /// speakers sharing the same microphone (in-person meeting), based on
    /// classic acoustic features — not a speech-recognition model. Off by
    /// default: the separation can get it wrong, especially if the two
    /// voices sound alike.
    public var diarizeMicrophoneTrack: Bool {
        get { activeProfile.diarizeMicrophoneTrack }
        set {
            var profile = activeProfile
            profile.diarizeMicrophoneTrack = newValue
            activeProfile = profile
        }
    }
    /// Meeting types created by the user for the active profile, in addition
    /// to the built-in templates.
    public var customTemplates: [MeetingTemplate] {
        get { activeProfile.customTemplates }
        set {
            var profile = activeProfile
            profile.customTemplates = newValue
            activeProfile = profile
        }
    }
    /// Template proposed by default when starting a recording under the
    /// active profile.
    public var defaultTemplateID: String {
        get { activeProfile.defaultTemplateID }
        set {
            var profile = activeProfile
            profile.defaultTemplateID = newValue
            activeProfile = profile
        }
    }

    /// Atlassian configuration per profile ID. Kept out of `Profile` itself
    /// (in the `Summarization` module) to avoid a dependency cycle — see the
    /// note at the top of `Profile.swift`.
    private var atlassianConfigsByProfile: [String: AtlassianConfiguration] {
        didSet {
            guard let data = try? JSONEncoder().encode(atlassianConfigsByProfile) else { return }
            defaults.set(data, forKey: Key.atlassian)
        }
    }
    public var atlassian: AtlassianConfiguration {
        get { atlassianConfigsByProfile[activeProfileID] ?? AtlassianConfiguration() }
        set { atlassianConfigsByProfile[activeProfileID] = newValue }
    }

    /// API token: read from and written to the keychain, never to the
    /// preferences, under an account name that varies per profile so each
    /// profile can point at a different Atlassian site.
    public var atlassianToken: String {
        get { cachedAtlassianToken }
        set {
            cachedAtlassianToken = newValue
            keychain.write(newValue, account: Self.tokenAccount(for: activeProfileID))
        }
    }

    /// Notion configuration per profile ID — same rationale as
    /// `atlassianConfigsByProfile`.
    private var notionConfigsByProfile: [String: NotionConfiguration] {
        didSet {
            guard let data = try? JSONEncoder().encode(notionConfigsByProfile) else { return }
            defaults.set(data, forKey: Key.notion)
        }
    }
    public var notion: NotionConfiguration {
        get { notionConfigsByProfile[activeProfileID] ?? NotionConfiguration() }
        set { notionConfigsByProfile[activeProfileID] = newValue }
    }

    /// Notion integration token: keychain, never the preferences, one
    /// account per profile.
    public var notionToken: String {
        get { cachedNotionToken }
        set {
            cachedNotionToken = newValue
            notionKeychain.write(newValue, account: Self.notionTokenAccount(for: activeProfileID))
        }
    }

    /// Meeting types (built-in or custom) visible in the selection list for
    /// the active profile — an allow-list rather than a deny-list, so that a
    /// fresh profile can start with only the generic type instead of every
    /// built-in enabled by default.
    public var enabledTemplateIDs: Set<String> {
        get { activeProfile.enabledTemplateIDs }
        set {
            var profile = activeProfile
            profile.enabledTemplateIDs = newValue
            activeProfile = profile
        }
    }

    public init() {
        providerKind = SummaryProviderKind(
            rawValue: defaults.string(forKey: Key.provider) ?? ""
        ) ?? .opencode
        opencodeModel = defaults.string(forKey: Key.opencodeModel) ?? "github-copilot/claude-sonnet-5"
        copilotACPModel = defaults.string(forKey: Key.copilotACPModel) ?? "claude-sonnet-5"
        ollamaModel = defaults.string(forKey: Key.ollamaModel) ?? "gemma4"
        claudeCodeModel = defaults.string(forKey: Key.claudeCodeModel) ?? "sonnet"
        userName = defaults.string(forKey: Key.userName) ?? NSFullUserName()
        useCalendar = defaults.object(forKey: Key.useCalendar) as? Bool ?? true

        // Profiles: load if present, otherwise migrate every pre-profile
        // global setting (vocabulary, custom templates, hidden types,
        // default type, behavior toggles, spoken/output language) into a
        // single seed profile, so upgrading doesn't reset anyone's
        // configuration.
        let isFreshMigration = defaults.data(forKey: Key.profiles) == nil
        var resolvedProfiles: [Profile]
        if let data = defaults.data(forKey: Key.profiles),
           let decoded = try? JSONDecoder().decode([Profile].self, from: data), !decoded.isEmpty {
            resolvedProfiles = decoded
            // `knownPeople` used to be global. Copy the legacy list into every
            // existing profile once so upgrading preserves current speech and
            // one-to-one suggestions, then each profile evolves independently.
            if !defaults.bool(forKey: Key.profileKnownPeopleMigrated) {
                let legacyKnownPeople = defaults.stringArray(forKey: Key.knownPeople) ?? []
                if !legacyKnownPeople.isEmpty {
                    for index in resolvedProfiles.indices where resolvedProfiles[index].knownPeople.isEmpty {
                        resolvedProfiles[index].knownPeople = legacyKnownPeople
                    }
                }
                defaults.set(true, forKey: Key.profileKnownPeopleMigrated)
            }
        } else {
            let legacyVocabulary = defaults.stringArray(forKey: Key.vocabulary) ?? [
                "Confluence", "Jira", "SmartMeet",
            ]
            let legacyKnownPeople = defaults.stringArray(forKey: Key.knownPeople) ?? []
            var legacyCustomTemplates: [MeetingTemplate] = []
            if let data = defaults.data(forKey: Key.customTemplates),
               let decoded = try? JSONDecoder().decode([MeetingTemplate].self, from: data) {
                legacyCustomTemplates = decoded
            }
            let legacyDisabled = Set(defaults.stringArray(forKey: Key.disabledTemplateIDs) ?? [])
            let legacyCustomIDs = Set(legacyCustomTemplates.map(\.id))
                .subtracting(MeetingTemplate.builtIns.map(\.id))
            let legacyEnabled = Set(MeetingTemplate.builtIns.map(\.id))
                .union(legacyCustomIDs)
                .subtracting(legacyDisabled)
            let legacyDefaultTemplateID = defaults.string(forKey: Key.defaultTemplate)
                ?? MeetingTemplate.personal.id
            let legacyLocaleIdentifier = defaults.string(forKey: Key.locale) ?? "fr-FR"
            let legacyRecentLocales = defaults.stringArray(
                forKey: Key.recentTranscriptionLocales
            ) ?? []
            let legacyDetectMeetings = defaults.object(forKey: Key.detectMeetings) as? Bool ?? true
            let legacyAutoStart = defaults.object(
                forKey: Key.autoStartOnDetection
            ) as? Bool ?? false
            let legacyDetectMeetingEnd = defaults.object(
                forKey: Key.detectMeetingEnd
            ) as? Bool ?? true
            let legacyAutoSummarize = defaults.object(forKey: Key.autoSummarize) as? Bool ?? true
            let legacyAutoPublish = defaults.object(forKey: Key.autoPublish) as? Bool ?? false
            let legacyAutoCreateJiraIssues = defaults.object(
                forKey: Key.autoCreateJiraIssues
            ) as? Bool ?? false
            let legacyDiarize = defaults.object(
                forKey: Key.diarizeMicrophoneTrack
            ) as? Bool ?? false
            var legacyEnabledServices: Set<ServiceKind> = []
            if let stored = defaults.array(forKey: Key.enabledServices) as? [String] {
                legacyEnabledServices = Set(stored.compactMap(ServiceKind.init(rawValue:)))
            }
            resolvedProfiles = [
                Profile(
                    name: L("Travail"),
                    symbol: "briefcase",
                    vocabulary: legacyVocabulary,
                    knownPeople: legacyKnownPeople,
                    customTemplates: legacyCustomTemplates,
                    enabledTemplateIDs: legacyEnabled,
                    defaultTemplateID: legacyDefaultTemplateID,
                    enabledServices: legacyEnabledServices,
                    localeIdentifier: legacyLocaleIdentifier,
                    recentTranscriptionLocales: legacyRecentLocales,
                    defaultOutputLanguage: .english,
                    enabledOutputLanguages: [.english],
                    detectMeetings: legacyDetectMeetings,
                    autoStartOnDetection: legacyAutoStart,
                    detectMeetingEnd: legacyDetectMeetingEnd,
                    autoSummarize: legacyAutoSummarize,
                    autoPublish: legacyAutoPublish,
                    autoCreateJiraIssues: legacyAutoCreateJiraIssues,
                    diarizeMicrophoneTrack: legacyDiarize
                ),
            ]
            defaults.set(true, forKey: Key.profileKnownPeopleMigrated)
        }
        profiles = resolvedProfiles
        let resolvedActiveProfileID: String
        if let stored = defaults.string(forKey: Key.activeProfileID),
           resolvedProfiles.contains(where: { $0.id == stored }) {
            resolvedActiveProfileID = stored
        } else {
            resolvedActiveProfileID = resolvedProfiles[0].id
        }
        activeProfileID = resolvedActiveProfileID

        // Atlassian/Notion configuration: new installs (or ones already
        // migrated by a previous run of this code) store a dictionary keyed
        // by profile ID; a legacy install stored a single object, which gets
        // attached to the seed profile created above.
        var resolvedAtlassianConfigs: [String: AtlassianConfiguration] = [:]
        if let data = defaults.data(forKey: Key.atlassian) {
            if let decoded = try? JSONDecoder().decode(
                [String: AtlassianConfiguration].self, from: data
            ) {
                resolvedAtlassianConfigs = decoded
            } else if let legacy = try? JSONDecoder().decode(
                AtlassianConfiguration.self, from: data
            ) {
                resolvedAtlassianConfigs[resolvedActiveProfileID] = legacy
            }
        }
        atlassianConfigsByProfile = resolvedAtlassianConfigs

        var resolvedNotionConfigs: [String: NotionConfiguration] = [:]
        if let data = defaults.data(forKey: Key.notion) {
            if let decoded = try? JSONDecoder().decode(
                [String: NotionConfiguration].self, from: data
            ) {
                resolvedNotionConfigs = decoded
            } else if let legacy = try? JSONDecoder().decode(
                NotionConfiguration.self, from: data
            ) {
                resolvedNotionConfigs[resolvedActiveProfileID] = legacy
            }
        }
        notionConfigsByProfile = resolvedNotionConfigs

        // Tokens: on a fresh migration, carry over the legacy fixed-account
        // token (if any) to the seed profile's own per-profile account, and
        // seed from the environment as before for a truly first launch.
        let profileAccount = Self.tokenAccount(for: resolvedActiveProfileID)
        if isFreshMigration, keychain.read(account: profileAccount) == nil,
           let legacyToken = keychain.read(account: Self.legacyTokenAccount) {
            keychain.write(legacyToken, account: profileAccount)
        }
        keychain.seedFromEnvironmentIfNeeded(
            account: profileAccount, variable: "ATLASSIAN_API_TOKEN"
        )

        let notionProfileAccount = Self.notionTokenAccount(for: resolvedActiveProfileID)
        if isFreshMigration, notionKeychain.read(account: notionProfileAccount) == nil,
           let legacyToken = notionKeychain.read(account: Self.legacyNotionTokenAccount) {
            notionKeychain.write(legacyToken, account: notionProfileAccount)
        }
        notionKeychain.seedFromEnvironmentIfNeeded(
            account: notionProfileAccount, variable: "NOTION_API_TOKEN"
        )
        cachedAtlassianToken = keychain.read(account: profileAccount) ?? ""
        cachedNotionToken = notionKeychain.read(account: notionProfileAccount) ?? ""

        // Property observers (`didSet`) never fire for a property's very
        // first assignment inside its own initializer — standard Swift
        // behavior, not a bug specific to this class. That's harmless for
        // values read verbatim from `defaults` (nothing changed, so nothing
        // needs re-persisting), but it would silently drop any data just
        // *derived* during migration above (the seed profile, its migrated
        // Atlassian/Notion configuration…): without this explicit write,
        // the next launch would find `Key.profiles` still absent and redo
        // the migration from scratch, minting a brand new profile ID every
        // time. Persisting once more here, unconditionally, is a no-op when
        // nothing was migrated and a correctness fix when something was.
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Key.profiles)
        }
        defaults.set(activeProfileID, forKey: Key.activeProfileID)
        if let data = try? JSONEncoder().encode(atlassianConfigsByProfile) {
            defaults.set(data, forKey: Key.atlassian)
        }
        if let data = try? JSONEncoder().encode(notionConfigsByProfile) {
            defaults.set(data, forKey: Key.notion)
        }
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }

    /// Profile currently in effect. `vocabulary`, `customTemplates`,
    /// `enabledTemplateIDs`, `defaultTemplateID` and `allTemplates` all read
    /// and write through it, so most of the app never needs to know profiles
    /// exist at all — it just calls `settings.vocabulary`, etc., as before.
    public var activeProfile: Profile {
        get { profiles.first { $0.id == activeProfileID } ?? profiles[0] }
        set {
            guard let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
            profiles[index] = newValue
        }
    }

    /// Creates a new profile (seeded with only the generic meeting type,
    /// empty vocabulary) and switches to it immediately.
    @discardableResult
    public func addProfile(
        name: String,
        symbol: String = "person.crop.circle",
        activate: Bool = true
    ) -> Profile {
        let profile = Profile(name: name, symbol: symbol)
        profiles.append(profile)
        if activate { activeProfileID = profile.id }
        return profile
    }

    /// Deletes a profile. Refuses to delete the last remaining one — there
    /// must always be at least one profile to record under. Switches away
    /// first if the deleted profile was active.
    public func removeProfile(_ profile: Profile) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id {
            activeProfileID = profiles[0].id
        }
        // Deleting a profile deletes its credentials too — a token or
        // Confluence site tied to a discarded profile has no reason to
        // linger in the keychain or preferences.
        atlassianConfigsByProfile[profile.id] = nil
        notionConfigsByProfile[profile.id] = nil
        keychain.write("", account: Self.tokenAccount(for: profile.id))
        notionKeychain.write("", account: Self.notionTokenAccount(for: profile.id))
    }

    /// Domain vocabulary and names combined: this is what needs to be
    /// injected into speech recognition and into the prompt, not just one
    /// or the other.
    public var contextualVocabulary: [String] { vocabulary + knownPeople }

    public func makeProvider() -> any SummaryProvider {
        switch providerKind {
        case .opencode: OpencodeProvider(model: opencodeModel)
        case .copilotACP: CopilotACPProvider(model: copilotACPModel)
        case .appleOnDevice: AppleFoundationModelProvider()
        case .ollama: OllamaProvider(model: ollamaModel)
        case .claudeCode: ClaudeCodeProvider(model: claudeCodeModel)
        }
    }

    public var canPublish: Bool {
        atlassian.isConfluenceReady && !atlassianToken.isEmpty
    }

    public var canPublishToNotion: Bool {
        !notionToken.isEmpty
    }

    public var automaticPublicationServiceKind: ServiceKind? {
        activeProfile.effectivePublicationServiceKind
    }

    public func publicationServiceKind(for template: MeetingTemplate) -> ServiceKind? {
        activeProfile.effectivePublicationServiceKind(for: template)
    }

    public func canPublish(to service: ServiceKind) -> Bool {
        switch service {
        case .atlassian: canPublish
        case .notion: canPublishToNotion
        }
    }

    public func canAutoPublish(template: MeetingTemplate) -> Bool {
        guard let service = publicationServiceKind(for: template) else { return false }
        return canPublish(to: service)
    }

    public var canAutoPublish: Bool {
        switch automaticPublicationServiceKind {
        case .atlassian: canPublish
        case .notion: canPublishToNotion
        case nil: false
        }
    }

    public func includesTranscript(for service: ServiceKind) -> Bool {
        activeProfile.servicesIncludingTranscript.contains(service)
    }

    public func setIncludesTranscript(_ included: Bool, for service: ServiceKind) {
        var profile = activeProfile
        if included {
            profile.servicesIncludingTranscript.insert(service)
        } else {
            profile.servicesIncludingTranscript.remove(service)
        }
        activeProfile = profile
    }

    /// Current sprint page, common parent of the sprint's meetings.
    public var sprintPage: SprintPage? {
        get { atlassian.sprintPage }
        set { atlassian.sprintPage = newValue }
    }

    /// True if at least one meeting type relies on the sprint page.
    public var usesSprintPage: Bool {
        allTemplates.contains { $0.parent.isSprintPage }
    }

    /// Built-in templates then custom templates, in display order, scoped to
    /// the active profile. An edited built-in type is represented by its
    /// current version (the possible override in `customTemplates`), not the
    /// original hardcoded version. Types not in `enabledTemplateIDs` don't
    /// appear here: this is the list offered for selection, not the full
    /// inventory.
    public var allTemplates: [MeetingTemplate] {
        let enabled = enabledTemplateIDs
        let effectiveBuiltIns = MeetingTemplate.builtIns.map { template(id: $0.id) }
        let trueCustoms = customTemplates.filter { custom in
            !MeetingTemplate.builtIns.contains { $0.id == custom.id }
        }
        return (effectiveBuiltIns + trueCustoms).filter { enabled.contains($0.id) }
    }

    public var availableBuiltInTemplates: [MeetingTemplate] {
        MeetingTemplate.builtIns.filter { !enabledTemplateIDs.contains($0.id) }
    }

    public func addBuiltInTemplate(_ template: MeetingTemplate) {
        guard template.hasBuiltInIdentity else { return }
        enabledTemplateIDs.insert(template.id)
    }

    @discardableResult
    public func createCustomTemplate() -> MeetingTemplate {
        let template = MeetingTemplate(
            name: L("Nouveau type"),
            symbol: "doc.text",
            sections: MeetingTemplate.personal.sections,
            instructions: "",
            titleFormat: "{summary} — {date}",
            parent: .spaceHome
        )
        customTemplates.append(template)
        enabledTemplateIDs.insert(template.id)
        return template
    }

    /// Removes a type from the active profile. Built-in overrides are retained
    /// so adding that built-in again restores the user's edits; custom types
    /// are deleted because they have no global canonical definition.
    public func removeTemplateFromActiveProfile(_ template: MeetingTemplate) {
        guard allTemplates.count > 1 else { return }
        enabledTemplateIDs.remove(template.id)
        if !template.hasBuiltInIdentity {
            customTemplates.removeAll { $0.id == template.id }
        }
        if defaultTemplateID == template.id {
            defaultTemplateID = allTemplates.first?.id ?? MeetingTemplate.personal.id
        }
    }

    public func resetBuiltInTemplate(_ template: MeetingTemplate) {
        guard template.hasBuiltInIdentity else { return }
        customTemplates.removeAll { $0.id == template.id }
    }

    public func template(id: String?) -> MeetingTemplate {
        MeetingTemplate.resolve(id: id, in: customTemplates)
    }

    /// Bumps a spoken language to the front of the "recent" list, so it
    /// appears at the top of the picker next time. Called when the language
    /// is actually used (start of recording), not on every selection change
    /// in the picker.
    public func recordTranscriptionLocaleUsed(_ identifier: String) {
        var recents = recentTranscriptionLocales.filter { $0 != identifier }
        recents.insert(identifier, at: 0)
        recentTranscriptionLocales = Array(recents.prefix(5))
    }

    /// Duplicates a template to create an independent variant, with a new
    /// identifier. Enabled immediately: an allow-list a fresh copy fell out
    /// of would make duplication look like it silently failed.
    public func duplicate(_ template: MeetingTemplate) -> MeetingTemplate {
        var copy = template
        copy.id = UUID().uuidString
        copy.name = L("%@ (copie)", template.localizedName)
        copy.isBuiltIn = false
        customTemplates.append(copy)
        enabledTemplateIDs.insert(copy.id)
        return copy
    }

    /// Saves a template, whether it's custom or an edit of a built-in type:
    /// in both cases it's an override stored by identifier.
    public func upsert(_ template: MeetingTemplate) {
        if let index = customTemplates.firstIndex(where: { $0.id == template.id }) {
            customTemplates[index] = template
        } else {
            customTemplates.append(template)
        }
    }

}
