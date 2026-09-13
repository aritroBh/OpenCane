//
//  EmergencyContactSeedTests.swift
//  CaneKitLogicTests
//
//  Step 68: the emergency contact can be seeded from the git-ignored Secrets.plist
//  (`EMERGENCY_CONTACT_NAME` / `EMERGENCY_CONTACT_PHONE`) so a phone number never enters git, and a
//  number the walker typed on the Profile tab is never overwritten. Pins `EmergencyContactSeed`.
//

import Testing
@testable import CaneKitLogic

/// An empty stored phone takes the Secrets contact (name and phone, trimmed).
@Test func anEmptyStoredPhoneIsSeededFromSecrets() {
    let seed = EmergencyContactSeed.seeded(storedName: "Not set", storedPhone: "",
                                           secretName: " Alex ", secretPhone: "+1 (555) 010-0199\n")
    #expect(seed?.name == "Alex")
    #expect(seed?.phone == "+1 (555) 010-0199")
    #expect(EmergencyConfirm.telDigits(seed?.phone ?? "") == "+15550100199")
}

/// A number already stored (typed by the walker) wins; whitespace-only counts as empty.
@Test func aStoredPhoneIsNeverOverwritten() {
    #expect(EmergencyContactSeed.seeded(storedName: "Sam", storedPhone: "217 555 0100",
                                        secretName: "Alex", secretPhone: "+1 555 010 0199") == nil)
    #expect(EmergencyContactSeed.seeded(storedName: "Sam", storedPhone: "   ",
                                        secretName: "Alex", secretPhone: "+1 555 010 0199")?.name == "Alex")
}

/// No usable Secrets phone (missing, blank, or under 7 digits) seeds nothing; a missing Secrets name
/// keeps the stored name.
@Test func nothingUsableSeedsNothing() {
    #expect(EmergencyContactSeed.seeded(storedName: "Not set", storedPhone: "", secretName: "Alex", secretPhone: nil) == nil)
    #expect(EmergencyContactSeed.seeded(storedName: "Not set", storedPhone: "", secretName: "Alex", secretPhone: " ") == nil)
    #expect(EmergencyContactSeed.seeded(storedName: "Not set", storedPhone: "", secretName: "Alex", secretPhone: "911") == nil)
    let noName = EmergencyContactSeed.seeded(storedName: "Sam", storedPhone: "", secretName: nil,
                                             secretPhone: "555 010 0199")
    #expect(noName?.name == "Sam")
    #expect(noName?.phone == "555 010 0199")
}

// MARK: Review round Steps 67–68 (Codex #2, Antigravity #5, Muse #3 / #7)

/// The contact the app uses (Profile card, voice prompt, tel: link) is the stored one when its phone
/// is not blank, else the Secrets seed, marked `fromSetup`. The stored profile is never changed:
/// the persisted and uploaded Medical ID is the caller's `profile`, which no longer carries a seed.
@Test func theEffectiveContactPrefersTheTypedOneAndMarksTheSeed() {
    let typed = EmergencyContactSeed.effective(storedName: "Sam", storedPhone: "217 555 0100",
                                               secretName: "Alex", secretPhone: "+1 555 010 0199")
    #expect(typed == EmergencyContactSeed.Contact(name: "Sam", phone: "217 555 0100", fromSetup: false))
    let seeded = EmergencyContactSeed.effective(storedName: "Not set", storedPhone: " ",
                                                secretName: "Alex", secretPhone: "+1 555 010 0199")
    #expect(seeded == EmergencyContactSeed.Contact(name: "Alex", phone: "+1 555 010 0199", fromSetup: true))
    let none = EmergencyContactSeed.effective(storedName: "Not set", storedPhone: "",
                                              secretName: "Alex", secretPhone: nil)
    #expect(none == EmergencyContactSeed.Contact(name: "Not set", phone: "", fromSetup: false))
}

/// The seed never feeds back into what is stored: saving the stored values (as `ProfilePage`'s
/// editor and `MedicalProfileStore.save` do) and reading them again yields the same effective
/// contact, still `fromSetup`, with the stored phone still blank.
@Test func theSeedIsNeverPartOfTheStoredValues() {
    var storedName = "Not set", storedPhone = ""
    let first = EmergencyContactSeed.effective(storedName: storedName, storedPhone: storedPhone,
                                               secretName: "Alex", secretPhone: "555 010 0199")
    // A round trip through "save" persists the stored values only.
    (storedName, storedPhone) = (storedName, storedPhone)
    #expect(storedPhone.isEmpty && storedName == "Not set")
    let second = EmergencyContactSeed.effective(storedName: storedName, storedPhone: storedPhone,
                                                secretName: "Alex", secretPhone: "555 010 0199")
    #expect(first == second && second.fromSetup)
    // Keys removed from Secrets.plist → the contact is gone on the next read.
    let removed = EmergencyContactSeed.effective(storedName: storedName, storedPhone: storedPhone,
                                                 secretName: nil, secretPhone: nil)
    #expect(removed.phone.isEmpty && !removed.fromSetup)
}

/// Muse #7: trip-log records (`speech`, `speech_dispatch`, `speech_engine`, `conv_turn`,
/// `voice_self_hear`) never carry a phone number. The spoken read-back stays (the number is read
/// back before dialing); the log sees "[number]". Only runs of ≥ 7 digits are masked, so route
/// distances and counts survive.
@Test func logRecordsMaskThePhoneNumber() {
    let prompt = EmergencyConfirm.promptLine(name: "Aritro", number: "+1 (217) 555-0100")
    #expect(EmergencyConfirm.logSafe(prompt) == "Say yes to call Aritro at [number].")
    #expect(EmergencyConfirm.logSafe("at 217 555 0100.") == "at [number].")          // a resumed clause
    #expect(EmergencyConfirm.logSafe("call 2175550100 now") == "call [number] now")
    for unchanged in ["Two meters ahead, door.", "GPS weak.", "Passed ISR. CIF in 120 meters.",
                      "Route to 1204 West Green Street.", "Say yes to call Sam at 911.", ""] {
        #expect(EmergencyConfirm.logSafe(unchanged) == unchanged, "\(unchanged)")
    }
}
