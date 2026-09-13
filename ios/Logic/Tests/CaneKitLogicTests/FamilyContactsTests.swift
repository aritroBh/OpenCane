//
//  FamilyContactsTests.swift
//  CaneKitLogicTests
//
//  Pins the family email list and the `family_contacts` registration payload. The failure this
//  guards against is quiet and total: a malformed or duplicated address means a fall alert goes
//  to nobody, or twice, and neither the app nor the walker would ever hear about it.
//

import Foundation
import Testing
@testable import CaneKitLogic

// MARK: Validation

/// Ordinary addresses pass, including the plus-tags and subdomains families actually use.
@Test func plausibleAddressesAreAccepted() {
    #expect(FamilyContacts.isValid("mom@example.com"))
    #expect(FamilyContacts.isValid("dad@example.com"))
    #expect(FamilyContacts.isValid("first.last+opencane@mail.example.co.uk"))
}

/// The shapes that are obviously a typo are rejected, because the bot cannot tell a typo from a
/// real address and would report success either way.
@Test func malformedAddressesAreRejected() {
    #expect(!FamilyContacts.isValid(""))
    #expect(!FamilyContacts.isValid("mom"))                    // no @
    #expect(!FamilyContacts.isValid("mom@"))
    #expect(!FamilyContacts.isValid("@example.com"))
    #expect(!FamilyContacts.isValid("mom@@example.com"))       // two @
    #expect(!FamilyContacts.isValid("mom@example"))            // no dot in the domain
    #expect(!FamilyContacts.isValid("mom@example."))
    #expect(!FamilyContacts.isValid("mom@.com"))
    #expect(!FamilyContacts.isValid("mom name@example.com"))   // whitespace
    #expect(!FamilyContacts.isValid("mom@example.c"))          // one-letter TLD
    #expect(!FamilyContacts.isValid("mom@example.c0m"))        // digits in the TLD
    #expect(!FamilyContacts.isValid(".mom@example.com"))
    #expect(!FamilyContacts.isValid("mom..name@example.com"))
    #expect(!FamilyContacts.isValid(String(repeating: "a", count: 250) + "@example.com"))
}

// MARK: Normalisation

/// Stored and sent form: trimmed, lowercased, order preserved.
@Test func normalizeTrimsAndLowercases() {
    #expect(FamilyContacts.normalize(["  Mom@Example.COM ", "Dad@example.com"])
            == ["mom@example.com", "dad@example.com"])
}

/// ⚠ The same person written two ways must not be emailed twice. Lowercasing is what makes this
/// work, and the first spelling wins so the walker's order is kept.
@Test func normalizeRemovesDuplicates() {
    let list = FamilyContacts.normalize(["Mom@Example.com", "mom@example.com", "  MOM@EXAMPLE.COM"])
    #expect(list == ["mom@example.com"])
}

/// An invalid entry is dropped rather than posted; the good ones still save.
@Test func normalizeDropsInvalidEntries() {
    #expect(FamilyContacts.normalize(["mom@example.com", "oops", "", "dad@example.com"])
            == ["mom@example.com", "dad@example.com"])
}

/// A paste accident cannot turn one Save into a hundred emails.
@Test func normalizeCapsTheList() {
    let many = (0..<(FamilyContacts.maxContacts + 5)).map { "person\($0)@example.com" }
    let list = FamilyContacts.normalize(many)
    #expect(list.count == FamilyContacts.maxContacts)
    #expect(list.first == "person0@example.com")        // the cap keeps the earliest entries
}

/// Idempotent: saving twice with no edits posts the same bytes.
@Test func normalizeIsIdempotent() {
    let once = FamilyContacts.normalize(["Mom@Example.com", "bad", "dad@example.com"])
    #expect(FamilyContacts.normalize(once) == once)
}

/// The walker is told which entries were thrown away, rather than silently losing them.
@Test func rejectedListsTheTypos() {
    #expect(FamilyContacts.rejected(["mom@example.com", "oops", "  ", "dad@"]) == ["oops", "dad@"])
}

// MARK: The registration event

/// The payload matches the bot contract exactly: `type`, `emails`, and `send_test` only when asked.
@Test func registrationMatchesTheContract() throws {
    let event = FamilyContacts.registration(emails: ["Mom@Example.com", "dad@example.com"],
                                            sendTest: true)
    let json = try #require(JSONSerialization.jsonObject(with: event.jsonBody()) as? [String: Any])

    #expect(json["type"] as? String == "family_contacts")
    #expect(json["emails"] as? [String] == ["mom@example.com", "dad@example.com"])
    #expect(json["send_test"] as? Bool == true)          // ⚠ snake_case: the bot's key
}

/// `send_test` is absent, not `false`, when no test was asked for — the contract only gives
/// meaning to the true case.
@Test func sendTestIsOmittedWhenNotRequested() throws {
    let event = FamilyContacts.registration(emails: ["mom@example.com"], sendTest: false)
    let json = try #require(JSONSerialization.jsonObject(with: event.jsonBody()) as? [String: Any])
    #expect(json["send_test"] == nil)
    #expect(json["emails"] as? [String] == ["mom@example.com"])
}

/// A caller cannot post a malformed list: the constructor normalises for them.
@Test func registrationNormalizesWhateverItIsGiven() {
    let event = FamilyContacts.registration(emails: [" MOM@example.com ", "oops", "mom@example.com"],
                                            sendTest: false)
    #expect(event.emails == ["mom@example.com"])
}

/// Registration is `info`: it is bookkeeping, not an alert, and must never text anyone.
@Test func registrationIsQuiet() {
    #expect(FamilyContacts.registration(emails: [], sendTest: false).severity == .info)
}

/// ⚠ `emails` / `send_test` belong to `family_contacts` alone. A fall event must never carry the
/// family's addresses — it does not need them (the bot has the list) and every event is one more
/// place they could leak.
@Test func ordinaryEventsCarryNoAddresses() throws {
    let fall = FamilyAlertPolicy.fall(lat: 40.1, lng: -88.2, note: nil)
    let json = try #require(JSONSerialization.jsonObject(with: fall.jsonBody()) as? [String: Any])
    #expect(json["emails"] == nil)
    #expect(json["send_test"] == nil)
    #expect(fall.emails == nil)
}

/// The registration round-trips, so a stored or replayed payload decodes.
@Test func registrationRoundTrips() throws {
    let event = FamilyContacts.registration(emails: ["mom@example.com"], sendTest: true)
    let decoded = try JSONDecoder().decode(OpenCaneEvent.self, from: event.jsonBody())
    #expect(decoded == event)
    #expect(decoded.type == .familyContacts)
}
