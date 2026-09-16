import Foundation
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
