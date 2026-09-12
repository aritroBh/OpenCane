//
//  FamilyContacts.swift
//  CaneKitLogic
//
//  The list of family email addresses the Grok Bot routine should alert, and the one-off
//  registration event that hands it over.
//
//  How the two halves fit together (bot contract, 2026-09-12):
//    1. The walker edits the list in Settings → OpenCane POSTs one `family_contacts` event with
//       `emails: string[]`. The bot stores the list. `send_test: true` asks it to email each
//       address a short "you are on the OpenCane alert list" note.
//    2. Cane events (fall / sos / obstacle / …) are POSTed exactly as before, unchanged. The bot
//       looks up the saved list and Gmails whoever is on it.
//
//  ⚠ **The app never sends email.** It posts addresses once; the bot owns delivery. Nothing here
//  or in `FamilyAlerts` may grow an SMTP client, a `mailto:` or a share sheet.
//
//  ⚠ **Addresses are never shown to the summarizer model.** `AlertSummarizer` only ever sees
//  `AlertContextPrompt.text(…)`, which has no contacts in it, and `FamilyAlerts.registerContacts`
//  deliberately does not go through the enrichment path that calls it. A family's email addresses
//  are not context for a sentence; they are the most personal thing this app holds.
//
//  Key invariants:
//    · Pure: validation, normalisation and ordering only. No storage (app `Settings`), no network.
//    · `normalize` is idempotent — normalising a normalised list changes nothing, so a Save with
//      no edits posts the same bytes.
//    · An invalid address is dropped, never sent. The bot cannot tell "typo" from "real", and an
//      alert silently going to nobody is the failure this list exists to prevent.
//  Tests: FamilyContactsTests.swift.
//

import Foundation

/// Cleaning and checking the family email list.
public enum FamilyContacts {

    /// Most addresses one walker can register. Well above a real family, low enough that a paste
    /// accident cannot turn one Save into a hundred emails from the bot.
    public static let maxContacts = 10

    /// Longest address accepted (RFC 5321's practical ceiling).
    public static let maxAddressLength = 254

    /// True when `raw` looks like an address worth sending to the bot.
    ///
    /// Deliberately conservative rather than RFC-complete: this decides whether a walker's typo
    /// silently costs them an alert, so it rejects the shapes that are obviously wrong (no `@`,
    /// two `@`, no dot in the domain, whitespace, a leading/trailing dot) and accepts everything
    /// else. Full RFC 5322 is not checkable here and would not make the list any more deliverable
    /// — only the bot's first send proves that, which is what `send_test` is for.
    public static func isValid(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxAddressLength else { return false }
        guard !text.contains(where: { $0.isWhitespace }) else { return false }

        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }            // no @, or more than one
        let local = parts[0], domain = parts[1]
        guard !local.isEmpty, !domain.isEmpty else { return false }
        guard !local.hasPrefix("."), !local.hasSuffix(".") else { return false }
        guard !text.contains("..") else { return false }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }           // needs a dot in the domain
        guard labels.allSatisfy({ !$0.isEmpty }) else { return false }
        guard let tld = labels.last, tld.count >= 2,
              tld.allSatisfy({ $0.isLetter }) else { return false }
        return true
    }

    /// The list as it should be stored and sent: trimmed, lowercased, invalid entries dropped,
    /// duplicates removed keeping the first occurrence, capped at `maxContacts`.
    ///
    /// Lowercasing is safe for the domain always and for the local part in practice (every mail
    /// provider a family uses is case-insensitive), and it is what makes de-duplication work —
    /// "Mom@Example.com" and "mom@example.com" are one person and must not both get emailed.
    public static func normalize(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in raw {
            let address = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard isValid(address), !seen.contains(address) else { continue }
            seen.insert(address)
            out.append(address)
            if out.count == maxContacts { break }
        }
        return out
    }

    /// Addresses in `raw` that will be dropped by `normalize`, for telling the walker why their
    /// typo did not save instead of silently swallowing it.
    public static func rejected(_ raw: [String]) -> [String] {
        raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isValid($0) }
    }

    /// The registration event. `send_test` asks the bot to email each address a short confirmation
    /// — the app itself sends nothing.
    /// - Parameter emails: raw entries; normalised here, so a caller cannot post a malformed list.
    public static func registration(emails: [String], sendTest: Bool) -> OpenCaneEvent {
        var event = OpenCaneEvent(type: .familyContacts, severity: .info)
        event.emails = normalize(emails)
        // Omitted rather than `false`: absent means "do not test", and the contract only gives
        // meaning to the true case.
        event.sendTest = sendTest ? true : nil
        return event
    }
}
