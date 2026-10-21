import Foundation

public struct MeetingSpeakerBindings: Codable {
    public let sessionID: UUID
    public private(set) var speakers: [Int: MeetingPerson] = [:]
    public private(set) var confirmedParticipants: [MeetingPerson] = []
    public init(sessionID: UUID) { self.sessionID = sessionID }
    public mutating func bind(_ person: MeetingPerson, to speaker: Int) {
        guard (1...8).contains(speaker) else { return }
        speakers[speaker] = person
        confirmAttendance(person)
    }
    public mutating func unbind(speaker: Int) { speakers[speaker] = nil }
    public mutating func confirmAttendance(_ person: MeetingPerson) {
        if let index = confirmedParticipants.firstIndex(where: { $0.id == person.id }) {
            confirmedParticipants[index] = person
        } else { confirmedParticipants.append(person) }
    }
    public mutating func removeAttendance(personID: String) {
        confirmedParticipants.removeAll { $0.id == personID }
        speakers = speakers.filter { $0.value.id != personID }
    }
}
