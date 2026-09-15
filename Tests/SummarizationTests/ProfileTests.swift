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
    }

    @Test("Le décodage est tolérant aux champs absents")
    func tolerantDecoding() throws {
        let json = #"{"id": "abc", "name": "Travail"}"#
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        #expect(profile.name == "Travail")
        #expect(profile.symbol == "person.crop.circle")
        #expect(profile.vocabulary.isEmpty)
        #expect(profile.customTemplates.isEmpty)
        #expect(profile.enabledTemplateIDs == [MeetingTemplate.personal.id])
        #expect(profile.defaultTemplateID == MeetingTemplate.personal.id)
        #expect(profile.defaultServiceKind == nil)
        #expect(profile.enabledServices.isEmpty)
        #expect(profile.localeIdentifier == "fr-FR")
        #expect(profile.recentTranscriptionLocales.isEmpty)
        #expect(profile.defaultOutputLanguage == .french)
        #expect(profile.detectMeetings == true)
        #expect(profile.autoStartOnDetection == false)
        #expect(profile.detectMeetingEnd == true)
        #expect(profile.autoSummarize == true)
        #expect(profile.autoPublish == false)
        #expect(profile.autoCreateJiraIssues == false)
        #expect(profile.diarizeMicrophoneTrack == false)
    }

    @Test("Un profil se décode avec toutes ses valeurs")
    func fullRoundTrip() throws {
        let original = Profile(
            name: "Travail",
            symbol: "briefcase",
            vocabulary: ["Confluence", "Jira"],
            customTemplates: [],
            enabledTemplateIDs: [MeetingTemplate.generic.id, MeetingTemplate.daily.id],
            defaultTemplateID: MeetingTemplate.generic.id,
            defaultServiceKind: .atlassian,
            enabledServices: [.atlassian, .notion],
            localeIdentifier: "en-US",
            recentTranscriptionLocales: ["en-US", "fr-FR"],
            defaultOutputLanguage: .english,
            detectMeetings: false,
            autoStartOnDetection: true,
            detectMeetingEnd: false,
            autoSummarize: false,
            autoPublish: true,
            autoCreateJiraIssues: true,
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
