//
//  EmergencyConfirm.swift
//  CaneKitLogic
//
//  Emergency by voice, confirmation-gated (Step 59): "emergency" prompts "Say yes to call <name>
//  at <number>."; a "yes" inside 8 s dials; "no", silence, or anything else does not.
//
//  Why this exists: the voice shell (Step 56) makes "emergency" one of the eight words, and a
//  word the recogniser can mishear must never ring a real person on its own. Two utterances, a
//  short window, and the number read back before the call — so a walker who said "emergency" by
//  mistake hears exactly who would be called and can say no. The `tel:` URL is opened by the app
//  (`UIApplication.open`), which leaves OpenCane; the trip log is flushed first.
//
//  Key invariants:
//    · Never dials on one word: `emergency()` only ever returns `.prompt` or `.noContact`.
//    · `confirm(true)` dials only while a prompt is pending and `now < promptedAt + confirmWindow`;
//      afterwards it is `.none` ("Nothing to confirm."), never a late call.
//    · A second "emergency" restarts the window; "no" or a lapse clears it. Both paths end in
//      "Emergency canceled." (`cancel` / `expire`).
//    · No contact (blank number) → `.noContact`, nothing pending.
//    · The number is spoken exactly as the profile stores it and dialled through `telDigits`
//      (digits and a leading plus). Logs carry the contact *name*, never the number (the caller's
//      rule; nothing here logs).
//    · Pure and deterministic: `now` is the caller's clock.
//
//  Owner / callers: `ConversationCoordinator` (one instance; `.emergency` / `.confirm` actions),
//  `ProfilePage` (`telDigits` for its Call link), `SpokenPhrases.shellLines` (`fixedLines`),
//  `AppModel` (prefetches `promptLine` for the saved profile — C2's wiring).
//  Tests: EmergencyConfirmTests.swift (9).
//

import Foundation

/// The confirmation gate between the word "emergency" and a phone call.
public struct EmergencyConfirm: Sendable, Equatable {

    /// Seconds a "yes" is accepted after the prompt. [H] 8 s: the prompt itself takes ~4 s to
    /// speak; the walker has the rest to answer. Longer and a "yes" to something else could dial.
    public static let confirmWindow: Double = 8

    /// Spoken when "no", "cancel" or the window's end ends the prompt.
    public static let canceledLine = "Emergency canceled."
    /// Spoken as the `tel:` URL opens (the app is about to leave the foreground).
    public static let callingLine = "Calling your emergency contact."
    /// Spoken when the profile has no number.
    public static let noContactLine = "No emergency contact is set up. Add one on the Profile tab."
    /// Spoken to a "yes" or "no" with no prompt pending.
    public static let nothingPendingLine = "Nothing to confirm."

    /// Every fixed line this flow can speak (the prompt is per profile), for the prefetch.
    /// Pinned by `fixedLinesAreTheFourSpokenOnes` and `everyLineTheShellCanSpeakIsPrefetched`.
    public static let fixedLines = [canceledLine, callingLine, noContactLine, nothingPendingLine]

    /// What the caller should do.
    public enum Outcome: Sendable, Equatable {
        /// Speak this prompt (`.nav`, ttl `confirmWindow`) and open a listen for the answer.
        case prompt(String)
        /// Open `tel:<tel>` after flushing the log; speak `callingLine`.
        case call(tel: String)
        /// Speak `canceledLine`.
        case cancel
        /// Nothing pending (late or unprompted yes / no): speak `nothingPendingLine`.
        case none
        /// Speak `noContactLine`.
        case noContact
    }

    /// When the current prompt was spoken; nil when nothing is pending.
    private var promptedAt: Double?
    /// The dialable number of the pending prompt.
    private var pendingTel = ""

    public init() {}

    /// "Say yes to call <name> at <number>." — the number as stored (spoken digit groups), the
    /// name or "your emergency contact" when blank. Prefetch it whenever the profile is saved.
    /// - Parameters:
    ///   - name: `CKMedicalProfile.emergencyContactName`.
    ///   - number: `CKMedicalProfile.emergencyContactPhone`, as typed.
    public static func promptLine(name: String, number: String) -> String {
        let who = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Say yes to call \(who.isEmpty ? "your emergency contact" : who) at \(number.trimmingCharacters(in: .whitespacesAndNewlines))."
    }

    /// Digits and a leading plus only, for a `tel:` URL. Moved here from `ProfilePage` (Step 59)
    /// so the Call link and the voice call dial the same string. Pinned by
    /// `digitsForTelKeepPlusAndNumbers`.
    /// - Parameter number: the number as typed on the profile.
    public static func telDigits(_ number: String) -> String {
        var out = ""
        for (i, ch) in number.enumerated() {
            if ch.isNumber { out.append(ch) }
            else if ch == "+", i == 0 { out.append(ch) }
        }
        return out
    }

    /// The word "emergency" was heard. Starts (or restarts) the window.
    /// - Parameters:
    ///   - now: the caller's clock.
    ///   - name: contact name, may be nil or blank.
    ///   - number: contact number, may be nil or blank → `.noContact`.
    /// - Returns: `.prompt(line)` or `.noContact`. Never `.call`.
    public mutating func emergency(now: Double, name: String?, number: String?) -> Outcome {
        let tel = Self.telDigits(number ?? "")
        guard !tel.isEmpty else {
            promptedAt = nil
            pendingTel = ""
            return .noContact
        }
        promptedAt = now
        pendingTel = tel
        return .prompt(Self.promptLine(name: name ?? "", number: number ?? ""))
    }

    /// "yes" (`true`) or "no" (`false`) was heard.
    /// - Parameters:
    ///   - yes: the parsed confirmation (`VoiceMenu.confirmation`).
    ///   - now: the caller's clock.
    /// - Returns: `.call(tel:)` for a yes inside the window, `.cancel` for a no inside it, else
    ///   `.none` (and the pending prompt, if any, is cleared).
    public mutating func confirm(_ yes: Bool, now: Double) -> Outcome {
        defer { promptedAt = nil; pendingTel = "" }
        guard isPending(now: now) else { return .none }
        return yes ? .call(tel: pendingTel) : .cancel
    }

    /// Whether a prompt is pending and still inside its window.
    /// - Parameter now: the caller's clock.
    public func isPending(now: Double) -> Bool {
        guard let promptedAt else { return false }
        return now - promptedAt < Self.confirmWindow
    }

    /// Poll from a ticker: true exactly once when a pending prompt's window has lapsed with no
    /// answer (speak `canceledLine`). Pinned by `expiryIsReportedOnce`.
    /// - Parameter now: the caller's clock.
    /// The microphone opened for the answer: the window restarts now (review 2026-09-13,
    /// Antigravity + OpenCode). The prompt itself takes ~4–7 s to speak (a race plus the read-back
    /// number), which left the walker a second or two — or nothing — of the 8 s window. No-op when
    /// nothing is pending. Pinned by `answerWindowRestartsWhenTheMicrophoneOpens`.
    /// - Parameter now: the caller's monotonic clock.
    /// - Returns: true when a pending prompt's window was restarted.
    @discardableResult
    public mutating func restartWindow(now: Double) -> Bool {
        guard isPending(now: now) else { return false }
        promptedAt = now
        return true
    }

    public mutating func expire(now: Double) -> Bool {
        guard let promptedAt, now - promptedAt >= Self.confirmWindow else { return false }
        self.promptedAt = nil
        pendingTel = ""
        return true
    }
}

// MARK: - Log masking (review round Steps 67–68, Muse #7)

extension EmergencyConfirm {
    /// Replacement for a phone number in a trip-log record.
    public static let maskedNumber = "[number]"

    /// Fewest digits a run needs to be masked: a 7-digit local number is the shortest real contact
    /// (`EmergencyContactSeed.minDigits`); route distances, counts and "911" are left alone.
    public static let maskMinDigits = 7

    /// `text` with every phone-like run (digits with spaces, dashes, dots, parentheses, a leading
    /// plus) of at least `maskMinDigits` digits replaced by `maskedNumber`. The emergency prompt
    /// reads the number back aloud before dialing (hard requirement, kept); the trip log — and the
    /// cloud mirror, which sees the same records — gets "Say yes to call Aritro at [number].".
    /// Caller: `TripLogger.event` for the `text`, `response`, `matched_line` and `transcript` fields.
    /// Pinned by `logRecordsMaskThePhoneNumber`.
    /// - Parameter text: a logged line.
    /// - Returns: the line with numbers masked (the same string when it has fewer than 7 digits).
    public static func logSafe(_ text: String) -> String {
        guard text.unicodeScalars.lazy.filter({ ("0"..."9").contains($0) }).count >= maskMinDigits,
              let regex = try? NSRegularExpression(pattern: #"\+?\(?\d[\d \-().]*\d"#) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let run = ns.substring(with: match.range)
            guard run.unicodeScalars.filter({ ("0"..."9").contains($0) }).count >= maskMinDigits else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += maskedNumber
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
