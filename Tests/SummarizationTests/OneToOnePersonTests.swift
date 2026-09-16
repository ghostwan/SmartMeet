import Foundation
import Testing

@testable import Summarization

@Suite("Personnes configurées pour les one-to-one")
struct OneToOnePersonTests {
    @Test("Le décodage est tolérant aux champs absents")
    func tolerantDecoding() throws {
        let json = #"{"name": "Sandra"}"#
        let person = try JSONDecoder().decode(OneToOnePerson.self, from: Data(json.utf8))
        #expect(person.name == "Sandra")
        #expect(person.email.isEmpty)
        #expect(person.confluenceAccountID.isEmpty)
        #expect(person.destination == .profileDefault)
        #expect(person.jiraShareEmail.isEmpty)
        #expect(!person.id.isEmpty)
    }

    @Test("Une personne se décode avec toutes ses valeurs")
    func fullRoundTrip() throws {
        let original = OneToOnePerson(
            name: "Sandra",
            email: "sandra@example.com",
            confluenceAccountID: "557058:abcabc-abcabc-abcabc",
            destination: .page(id: "123456"),
            jiraShareEmail: "manager@example.com"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OneToOnePerson.self, from: data)
        #expect(decoded == original)
    }

    @Test("Deux personnes gardent des destinations indépendantes")
    func destinationsAreIndependent() {
        let sandra = OneToOnePerson(name: "Sandra", destination: .page(id: "1"))
        let bob = OneToOnePerson(name: "Bob", destination: .profileDefault)
        #expect(sandra.destination != bob.destination)
    }
}

@Suite("Profils — personnes one-to-one")
struct ProfileOneToOnePeopleTests {
    @Test("Un profil neuf n'a aucune personne configurée")
    func freshProfileHasNoPeople() {
        let profile = Profile(name: "Perso")
        #expect(profile.oneToOnePeople.isEmpty)
    }

    @Test("Le décodage d'un profil est tolérant à l'absence de la liste de personnes")
    func tolerantDecoding() throws {
        let json = #"{"id": "abc", "name": "Travail"}"#
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        #expect(profile.oneToOnePeople.isEmpty)
    }

    @Test("Deux profils gardent des personnes one-to-one indépendantes")
    func peopleAreIndependentPerProfile() {
        let work = Profile(name: "Travail", oneToOnePeople: [OneToOnePerson(name: "Sandra")])
        let personal = Profile(name: "Perso", oneToOnePeople: [OneToOnePerson(name: "Bob")])
        #expect(work.oneToOnePeople.map(\.name) == ["Sandra"])
        #expect(personal.oneToOnePeople.map(\.name) == ["Bob"])
    }
}
