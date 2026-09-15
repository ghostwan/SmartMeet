import Foundation
import Testing

@testable import Summarization

@Suite("Profils")
struct ProfileTests {
    @Test("Un profil neuf ne propose que le type générique")
    func freshProfileStartsWithGenericOnly() {
        let profile = Profile(name: "Perso")
        #expect(profile.enabledTemplateIDs == [MeetingTemplate.personal.id])
        #expect(profile.defaultTemplateID == MeetingTemplate.personal.id)
        #expect(profile.enabledOutputLanguages == [.english])
        #expect(profile.defaultOutputLanguage == .english)
    }

    @Test("Le décodage est tolérant aux champs absents")
    func tolerantDecoding() throws {
        let json = #"{"id": "abc", "name": "Travail"}"#
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        #expect(profile.name == "Travail")
        #expect(profile.symbol == "person.crop.circle")
        #expect(profile.vocabulary.isEmpty)
        #expect(profile.knownPeople.isEmpty)
        #expect(profile.customTemplates.isEmpty)
        #expect(profile.enabledTemplateIDs == [MeetingTemplate.personal.id])
        #expect(profile.defaultTemplateID == MeetingTemplate.personal.id)
        #expect(profile.defaultServiceKind == nil)
        #expect(profile.enabledServices.isEmpty)
        #expect(profile.servicesIncludingTranscript == [.atlassian])
        #expect(profile.localeIdentifier == "fr-FR")
        #expect(profile.recentTranscriptionLocales.isEmpty)
        #expect(profile.defaultOutputLanguage == .english)
        #expect(profile.enabledOutputLanguages == [.english])
        #expect(profile.detectMeetings == true)
        #expect(profile.autoStartOnDetection == false)
        #expect(profile.detectMeetingEnd == true)
        #expect(profile.autoSummarize == true)
        #expect(profile.autoPublish == false)
        #expect(profile.autoCreateJiraIssues == false)
        #expect(profile.autoCreateNotionTasks == false)
        #expect(profile.diarizeMicrophoneTrack == false)
    }

    @Test("Un profil se décode avec toutes ses valeurs")
    func fullRoundTrip() throws {
        let original = Profile(
            name: "Travail",
            symbol: "briefcase",
            vocabulary: ["Confluence", "Jira"],
            knownPeople: ["Alice", "Bob"],
            customTemplates: [],
            enabledTemplateIDs: [MeetingTemplate.generic.id, MeetingTemplate.daily.id],
            defaultTemplateID: MeetingTemplate.generic.id,
            defaultServiceKind: .atlassian,
            enabledServices: [.atlassian, .notion],
            servicesIncludingTranscript: [.notion],
            localeIdentifier: "en-US",
            recentTranscriptionLocales: ["en-US", "fr-FR"],
            defaultOutputLanguage: .english,
            enabledOutputLanguages: [.french, .english],
            detectMeetings: false,
            autoStartOnDetection: true,
            detectMeetingEnd: false,
            autoSummarize: false,
            autoPublish: true,
            autoCreateJiraIssues: true,
            autoCreateNotionTasks: true,
            diarizeMicrophoneTrack: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        #expect(decoded == original)
    }

    @Test("Deux profils gardent des préférences de comportement indépendantes")
    func behaviorPreferencesAreIndependentPerProfile() {
        let work = Profile(name: "Travail", autoPublish: true, diarizeMicrophoneTrack: false)
        let personal = Profile(name: "Perso", autoPublish: false, diarizeMicrophoneTrack: true)
        #expect(work.autoPublish != personal.autoPublish)
        #expect(work.diarizeMicrophoneTrack != personal.diarizeMicrophoneTrack)
    }

    @Test("Deux profils gardent des listes de personnes indépendantes")
    func knownPeopleAreIndependentPerProfile() {
        let work = Profile(name: "Travail", knownPeople: ["Alice"])
        let personal = Profile(name: "Perso", knownPeople: ["Bob"])
        #expect(work.knownPeople == ["Alice"])
        #expect(personal.knownPeople == ["Bob"])
    }

    @Test("Chaque profil garde ses préférences de transcription par service")
    func transcriptPublicationPreferencesAreIndependent() {
        let work = Profile(
            name: "Travail",
            servicesIncludingTranscript: [.atlassian]
        )
        let personal = Profile(
            name: "Perso",
            servicesIncludingTranscript: [.notion]
        )
        #expect(work.servicesIncludingTranscript == [.atlassian])
        #expect(personal.servicesIncludingTranscript == [.notion])
    }

    @Test("La langue par défaut reste toujours proposée")
    func defaultOutputLanguageIsAlwaysEnabled() {
        let profile = Profile(
            name: "Travail",
            defaultOutputLanguage: .french,
            enabledOutputLanguages: [.english]
        )
        #expect(profile.enabledOutputLanguages == [.french, .english])
    }

    @Test("Toutes les langues de compte rendu ont des métadonnées complètes")
    func outputLanguagesHaveCompleteMetadata() {
        #expect(SummaryLanguage.allCases.count == 14)
        for language in SummaryLanguage.allCases {
            #expect(!language.displayName.isEmpty)
            #expect(!language.flag.isEmpty)
            #expect(!language.promptName.isEmpty)
            #expect(SummaryLanguage(rawValue: language.rawValue) == language)
        }
    }
}

@Suite("Résolution du service de publication")
struct ProfilePublicationServiceTests {
    @Test("Le service par défaut actif est utilisé")
    func enabledDefaultWins() {
        let profile = Profile(
            name: "Travail",
            defaultServiceKind: .notion,
            enabledServices: [.notion, .atlassian]
        )
        #expect(profile.effectivePublicationServiceKind == .notion)
    }

    @Test("Un service unique est utilisé même sans valeur par défaut")
    func singleServiceIsUnambiguous() {
        let profile = Profile(name: "Travail", enabledServices: [.atlassian])
        #expect(profile.effectivePublicationServiceKind == .atlassian)
    }

    @Test("Plusieurs services sans valeur par défaut restent ambigus")
    func multipleServicesNeedDefault() {
        let profile = Profile(name: "Travail", enabledServices: [.notion, .atlassian])
        #expect(profile.effectivePublicationServiceKind == nil)
    }

    @Test("Un service par défaut retiré n'est pas utilisé")
    func removedDefaultIsIgnored() {
        let profile = Profile(
            name: "Travail",
            defaultServiceKind: .notion,
            enabledServices: [.atlassian]
        )
        #expect(profile.effectivePublicationServiceKind == .atlassian)
    }

    @Test("Le service du type remplace le service par défaut du profil")
    func templateServiceOverridesProfileDefault() {
        var template = MeetingTemplate.personal
        template.serviceKind = .notion
        let profile = Profile(
            name: "Travail",
            defaultServiceKind: .atlassian,
            enabledServices: [.atlassian, .notion]
        )
        #expect(profile.effectivePublicationServiceKind(for: template) == .notion)
    }

    @Test("Un service explicite retiré ne bascule pas vers un autre service")
    func disabledExplicitTemplateServiceDoesNotFallBack() {
        var template = MeetingTemplate.personal
        template.serviceKind = .notion
        let profile = Profile(
            name: "Travail",
            defaultServiceKind: .atlassian,
            enabledServices: [.atlassian]
        )
        #expect(profile.effectivePublicationServiceKind(for: template) == nil)
    }
}

@Suite("Services de publication")
struct ServiceKindTests {
    @Test("Tous les services ont un nom et un symbole")
    func displayNamesAndSymbols() {
        for kind in ServiceKind.allCases {
            #expect(!kind.displayName.isEmpty)
            #expect(!kind.symbol.isEmpty)
        }
    }

    @Test("Le brut se décode dans les deux sens")
    func rawValueRoundTrip() {
        #expect(ServiceKind(rawValue: "notion") == .notion)
        #expect(ServiceKind(rawValue: "atlassian") == .atlassian)
        #expect(ServiceKind(rawValue: "inconnu") == nil)
    }
}
