import Foundation
import Summarization
import Testing

@testable import MeetingStore

@Suite("Décodage tolérant de Meeting")
struct MeetingDecodingTests {
    private let baseJSON = """
    {"id":"\(UUID().uuidString)","title":"1:1 Sandra","startedAt":845035200,"duration":600}
    """

    @Test("Une réunion enregistrée avant le picker Confluence reste lisible, sans accountId")
    func legacyMeetingHasNoAccountID() throws {
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(baseJSON.utf8))
        #expect(meeting.oneToOneParticipant == nil)
        #expect(meeting.oneToOneParticipantEmail == nil)
        #expect(meeting.oneToOneParticipantAccountID == nil)
    }

    @Test("Une réunion enregistrée avant les personnes configurées reste lisible, sans destination ni partage Jira")
    func legacyMeetingHasNoConfiguredPersonFields() throws {
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(baseJSON.utf8))
        #expect(meeting.oneToOneDestination == nil)
        #expect(meeting.oneToOneJiraShareEmail == nil)
    }

    @Test("La destination et le partage Jira d'une personne configurée sont décodés quand présents")
    func decodesConfiguredPersonFieldsWhenPresent() throws {
        var meeting = try JSONDecoder().decode(Meeting.self, from: Data(baseJSON.utf8))
        meeting.oneToOneParticipant = "Sandra"
        meeting.oneToOneDestination = .page(id: "123456")
        meeting.oneToOneJiraShareEmail = "manager@example.com"

        let data = try JSONEncoder().encode(meeting)
        let decoded = try JSONDecoder().decode(Meeting.self, from: data)

        #expect(decoded.oneToOneDestination == .page(id: "123456"))
        #expect(decoded.oneToOneJiraShareEmail == "manager@example.com")
    }

    @Test("L'accountId Confluence résolu par la recherche est décodé quand présent")
    func decodesAccountIDWhenPresent() throws {
        var meeting = try JSONDecoder().decode(Meeting.self, from: Data(baseJSON.utf8))
        meeting.oneToOneParticipant = "Sandra"
        meeting.oneToOneParticipantAccountID = "557058:abcabc-abcabc-abcabc"

        let data = try JSONEncoder().encode(meeting)
        let decoded = try JSONDecoder().decode(Meeting.self, from: data)

        #expect(decoded.oneToOneParticipant == "Sandra")
        #expect(decoded.oneToOneParticipantAccountID == "557058:abcabc-abcabc-abcabc")
    }

    @Test("Un accountId invraisemblable (chaîne vide) n'est pas confondu avec l'absence de valeur")
    func emptyAccountIDIsPreserved() throws {
        let json = baseJSON.dropLast() + ",\"oneToOneParticipantAccountID\":\"\"}"
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(json.utf8))
        #expect(meeting.oneToOneParticipantAccountID == "")
    }
}

