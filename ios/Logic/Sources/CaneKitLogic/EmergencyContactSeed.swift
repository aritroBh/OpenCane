//
//  EmergencyContactSeed.swift
//  CaneKitLogic
//
//  Step 68 (owner: "my emergency contact is not set"). A real phone number must never enter git
//  (AGENTS.md hard rule 4, and `CKMedicalProfile.standardDefault` ships no PII), so the walker's
//  contact can come from the git-ignored `Secrets.plist` keys `EMERGENCY_CONTACT_NAME` /
//  `EMERGENCY_CONTACT_PHONE` instead. This is the rule for when those keys apply.
//
//  Pure, Foundation-only. Caller: `MedicalProfileStore.effectiveEmergencyContact` (app target), which
//  reads the keys via `Secrets.string` on every read. Review round Steps 67–68 (Codex #2, Antigravity
//  #5, Muse #3): the seed is never written into `MedicalProfileStore.profile` — Step 68 put it there
//  in `init`, so any profile edit saved it to UserDefaults and the cloud mirror's first push
//  uploaded it. The profile, UserDefaults and `CloudSync.saveMedicalProfile` see only what the
//  walker typed; the Profile card, the voice emergency prompt and the tel: link read `effective`.
//  Tests: `EmergencyContactSeedTests.swift`.
//

import Foundation

/// Seeds the emergency contact from Secrets when the stored one has no phone. Namespace only.
public enum EmergencyContactSeed {
    /// Fewest digits a seeded number must have (`EmergencyConfirm.telDigits`, plus sign excluded):
    /// a local 7-digit number is the shortest real contact; "911" is not a contact.
    public static let minDigits = 7

    /// The contact to use, or nil to leave the stored profile alone.
    /// - Parameters:
    ///   - storedName: the profile's `emergencyContactName` ("Not set" by default).
    ///   - storedPhone: the profile's `emergencyContactPhone`; any non-blank value wins.
    ///   - secretName: `EMERGENCY_CONTACT_NAME`, nil when missing; blank keeps `storedName`.
    ///   - secretPhone: `EMERGENCY_CONTACT_PHONE`, nil when missing.
    /// - Returns: trimmed name and phone when the stored phone is blank and the Secrets phone has at
    ///   least `minDigits` digits. Pinned by `anEmptyStoredPhoneIsSeededFromSecrets`,
    ///   `aStoredPhoneIsNeverOverwritten`, `nothingUsableSeedsNothing`.
    /// The emergency contact the app acts on.
    public struct Contact: Sendable, Equatable {
        /// Name to show and speak ("Not set" when nothing is known).
        public let name: String
        /// Phone number as typed or as in Secrets.plist; empty = no contact.
        public let phone: String
        /// True when it came from Secrets.plist (the Profile card captions it "From this phone's setup").
        public let fromSetup: Bool
        /// - Parameters: see the properties.
        public init(name: String, phone: String, fromSetup: Bool) {
            self.name = name
            self.phone = phone
            self.fromSetup = fromSetup
        }
    }

    /// The contact to display, prompt and dial: the stored one when its phone is not blank, else the
    /// Secrets seed (`seeded`, marked `fromSetup`), else the stored one (blank phone = no contact).
    /// Never a value to persist — persist the stored profile. Pinned by
    /// `theEffectiveContactPrefersTheTypedOneAndMarksTheSeed`, `theSeedIsNeverPartOfTheStoredValues`.
    /// - Parameters: as `seeded(storedName:storedPhone:secretName:secretPhone:)`.
    /// - Returns: the contact.
    public static func effective(storedName: String, storedPhone: String,
                                 secretName: String?, secretPhone: String?) -> Contact {
        if let seed = seeded(storedName: storedName, storedPhone: storedPhone,
                             secretName: secretName, secretPhone: secretPhone) {
            return Contact(name: seed.name, phone: seed.phone, fromSetup: true)
        }
        return Contact(name: storedName, phone: storedPhone, fromSetup: false)
    }

    public static func seeded(storedName: String, storedPhone: String,
                              secretName: String?, secretPhone: String?) -> (name: String, phone: String)? {
        guard storedPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let phone = (secretPhone ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard EmergencyConfirm.telDigits(phone).filter(\.isNumber).count >= minDigits else { return nil }
        let name = (secretName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? storedName : name, phone)
    }
}
