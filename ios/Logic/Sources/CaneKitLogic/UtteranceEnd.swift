//
//  UtteranceEnd.swift
//  CaneKitLogic
//
//  When push-to-talk listening ends on its own. Pure, Foundation-only; the numbers live here
//  (AGENTS.md hard rule 3) and are pinned by `UtteranceEndTests`.
//
//  Purpose:
//    · `VoiceInputEngine` (the app) feeds every partial transcript it receives plus a clock tick;
//      this type answers "still listening", "the walker has finished" or "give up".
//    · A blind walker cannot see a "Listening…" label and cannot be asked to press twice with
//      one hand on the cane, so the decision has to be made for them, from the transcript alone.
//
//  Key invariants:
//    · Never submits before any words arrive — silence before the first word is thinking time.
//    · Submits once a non-empty transcript has been unchanged for `silenceAfterSpeech`.
//    · The hard cap `maxListen` still applies: with words it is a submit, without words a timeout.
//    · Deterministic: the caller passes `now`, so tests need no clock.
//

import Foundation

/// End-of-utterance decision for push-to-talk. Feed `update(transcript:now:)` on every partial
/// result and on every `checkInterval` tick; stop listening on the first non-`.listening` verdict.
///
/// Why transcript stability and not audio energy: `SFSpeechRecognizer` already runs a voice
/// activity detector and only emits a new partial result when it heard more words, so "the text
/// stopped changing" is the same signal with none of the microphone-level tuning (street noise,
/// wind on the cane) that an RMS gate would need. Caller: `VoiceInputEngine.startListening()`'s
/// end ticker. ⚠ `UtteranceEndTests` pin every number and branch here.
public struct UtteranceEndDetector: Sendable, Equatable {

    /// Why listening should end, or that it should not.
    public enum Verdict: Sendable, Equatable {
        /// Keep the microphone open.
        case listening
        /// Words arrived and then stopped changing for `silenceAfterSpeech` (or the cap was hit
        /// with words on the clock): submit the transcript.
        case endOfUtterance
        /// `maxListen` elapsed and nothing was said: stop and tell the walker nothing was heard.
        case timeout
    }

    /// Seconds a non-empty transcript must stay unchanged before it is submitted. 1.5 s covers a
    /// breath between clauses; shorter starts cutting "take me to… Grainger" in half, longer makes
    /// every answer feel late. Untuned on the street beyond the demo route — tune from the
    /// `voice_end` trip-log events, not by feel.
    public static let silenceAfterSpeech: Double = 1.5

    /// Seconds from the start of listening after which the microphone is closed no matter what.
    /// The pre-existing push-to-talk cap: a stuck recogniser must never hold the microphone (and
    /// the muted beacon) open indefinitely.
    public static let maxListen: Double = 10

    /// How often the engine re-asks while no partial result arrives (the silence clock has to be
    /// noticed without a new result to drive it). A quarter of `silenceAfterSpeech` keeps the
    /// answer within ~0.25 s of the true end of speech.
    public static let checkInterval: Double = 0.25

    /// When listening began (same clock as `now`).
    private let startedAt: Double
    /// The last trimmed transcript seen; "" until words arrive.
    private var lastText = ""
    /// When `lastText` last changed; nil until the first words.
    private var lastChangeAt: Double?
    /// Set once a terminal verdict was given, so a stale tick repeats it instead of flipping.
    private var ended: Verdict?

    /// - Parameter startedAt: the moment listening began, on the caller's clock.
    public init(startedAt: Double) {
        self.startedAt = startedAt
    }

    /// Record the latest transcript and decide. Idempotent after the first terminal verdict.
    /// - Parameters:
    ///   - transcript: `bestTranscription.formattedString` of the latest partial result (or the
    ///     last one seen, on a plain tick). Whitespace-only counts as no words.
    ///   - now: the caller's clock, same base as `startedAt`.
    public mutating func update(transcript: String, now: Double) -> Verdict {
        if let ended { return ended }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text != lastText {
            lastText = text
            lastChangeAt = now
        }
        let hasWords = !text.isEmpty
        if now - startedAt >= Self.maxListen {
            ended = hasWords ? .endOfUtterance : .timeout
            return ended!
        }
        if hasWords, let lastChangeAt, now - lastChangeAt >= Self.silenceAfterSpeech {
            ended = .endOfUtterance
            return .endOfUtterance
        }
        return .listening
    }
}
