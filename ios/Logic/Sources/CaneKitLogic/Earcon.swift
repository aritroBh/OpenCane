//
//  Earcon.swift
//  CaneKitLogic
//
//  Calm feedback (Step 65): seven short tones that replace the app's waiting words, and the policy
//  that says — for every listening, waiting and busy event — tone, words, both, or nothing.
//
//  Why this exists: owner, 2026-09-13, after the first mounted walk — "make sure it's not over
//  stimulating again like with the amount of questions with the loading etc — make it nice, maybe a
//  little tap or bell and then it releases something; don't over-stimulate the blind person too much
//  or else they won't listen." The phone log of that walk (canekit-2026-09-13T08-51-14Z) shows why:
//  in the first 30 s the walker heard "OpenCane ready.", the 76-character eight-word menu, "Still
//  describing the previous scene." twice, "One moment." and "That is taking too long. Ask again in a
//  moment." — words about waiting, not answers. A tone says "heard you / working / nothing" in
//  under 0.2 s, does not compete with speech for the same attention, and leaves the street audible.
//
//  Key invariants:
//    · Every tone is ≤ `maxDurationMs` (180 ms) and peaks ≤ `maxGainDBFS` (−12 dBFS), measured on
//      the synthesized samples (`everyEarconIsShortAndQuiet`). A gain offset can only lower it.
//    · The envelope starts and ends at silence, so there is no click (`envelopesStartAndEndSilent`).
//    · Words survive only where a tone cannot carry the meaning: two empty presses in a row
//      ("I did not catch that."), a timeout ("No answer."), and route ready ("Starting.").
//    · A window the walker did not open (launch, follow-up) closes empty in silence.
//    · `gate`: never under automation (`SpeechQueue.muted`), never over a `.safety` line.
//    · Pure and nonisolated: no clock, no audio. `EarconPlayer` (app) plays `wavData`.
//
//  Owner / callers: `SpeechQueue.playEarcon` → `EarconPlayer` (app; `gate`, `wavData`),
//  `VoiceInputEngine` (listenOpened / heard / empty, `emptyPressCount`), `ConversationCoordinator`
//  (thinking, timedOut, cloudFailed, answer), `SceneDescriber` (describerBusy, answer),
//  `AppModel.queueRouteStart` / `depthReadinessChanged` (routeWarming, `warmupTickDue`, routeReady).
//  Tests: EarconTests.swift (14).
//

import Foundation

/// One short synthesized tone, named for what it tells the walker.
public enum Earcon: String, CaseIterable, Sendable, Equatable {
    /// Soft rising two-note: the microphone is open, talk now.
    case listening
    /// One short high tap: the microphone closed and it heard words.
    case heard
    /// Soft falling two-note: a press closed and heard nothing.
    case nothing
    /// A very quiet tick: still working (a slow cloud answer, obstacle detection warming up).
    case thinking
    /// Two soft same-pitch taps: busy with the previous request, this one was dropped.
    case busy
    /// A gentle bell: a long answer or the route starts right after it.
    case done
    /// Low double tap: that did not work (followed by "No answer.").
    case error

    /// One sine note of an earcon.
    public struct Tone: Sendable, Equatable {
        /// Fundamental frequency, Hz.
        public let hz: Double
        /// Note length including attack and decay, milliseconds.
        public let durationMs: Double
        /// Silence before this note, milliseconds (0 for the first note).
        public let gapBeforeMs: Double
        /// Peak level of the note, dBFS (≤ `Earcon.maxGainDBFS`).
        public let gainDBFS: Double
        /// An inharmonic partial at `hz × partialRatio`, weight 0.25 — what makes `done` a bell
        /// rather than a beep. nil for a pure sine.
        public let partialRatio: Double?

        public init(hz: Double, durationMs: Double, gapBeforeMs: Double = 0, gainDBFS: Double,
                    partialRatio: Double? = nil) {
            self.hz = hz
            self.durationMs = durationMs
            self.gapBeforeMs = gapBeforeMs
            self.gainDBFS = gainDBFS
            self.partialRatio = partialRatio
        }
    }

    /// Longest an earcon may be, milliseconds. [H] 180 ms: under the ~200 ms at which a sound starts
    /// to be heard as an event of its own rather than a tick, and short enough to sit between two
    /// words of a route line. Pinned by `ceilingsArePinned`.
    public static let maxDurationMs: Double = 180
    /// Loudest an earcon may peak, dBFS. [H] −12 dBFS: speech clips are normalised near −1 dBFS, so
    /// every tone is at least ~11 dB under the voice it sits beside.
    public static let maxGainDBFS: Double = -12
    /// Synthesis rate, Hz (the WAV's rate; `AVAudioPlayer` resamples to the route).
    public static let sampleRate: Double = 44_100
    /// Linear attack, milliseconds (shorter for a note shorter than 4× this).
    static let attackMs: Double = 4

    /// The notes, in order. Numbers are [H] until a walk log tunes them.
    public var tones: [Tone] {
        switch self {
        case .listening:
            return [Tone(hz: 523.25, durationMs: 60, gainDBFS: -18),                  // C5
                    Tone(hz: 783.99, durationMs: 80, gapBeforeMs: 15, gainDBFS: -18)]  // G5
        case .heard:
            return [Tone(hz: 1046.5, durationMs: 45, gainDBFS: -20)]                   // C6
        case .nothing:
            return [Tone(hz: 659.25, durationMs: 70, gainDBFS: -20),                   // E5
                    Tone(hz: 493.88, durationMs: 90, gapBeforeMs: 10, gainDBFS: -22)]  // B4
        case .thinking:
            return [Tone(hz: 1760, durationMs: 20, gainDBFS: -28)]                     // A6, faint
        case .busy:
            return [Tone(hz: 587.33, durationMs: 45, gainDBFS: -22),                   // D5 ×2
                    Tone(hz: 587.33, durationMs: 45, gapBeforeMs: 40, gainDBFS: -22)]
        case .done:
            return [Tone(hz: 1318.51, durationMs: 170, gainDBFS: -16, partialRatio: 2.76)]  // E6 bell
        case .error:
            return [Tone(hz: 233.08, durationMs: 55, gainDBFS: -16),                   // B♭3
                    Tone(hz: 196.0, durationMs: 65, gapBeforeMs: 45, gainDBFS: -16)]   // G3
        }
    }

    /// Total length including gaps, milliseconds.
    public var durationMs: Double {
        tones.reduce(0) { $0 + $1.gapBeforeMs + $1.durationMs }
    }

    /// The earcon as mono float samples in −1…1 at `sampleRate`.
    /// Envelope per note: linear attack over `attackMs`, then a quadratic decay to exactly 0 at the
    /// note's end — so every note starts and ends in silence.
    /// - Parameter gainOffsetDB: added to every note's gain; clamped to ≤ 0 (quieter only).
    /// - Returns: the samples (gaps are zeros).
    public func samples(gainOffsetDB: Double = 0) -> [Float] {
        let offset = min(0, gainOffsetDB)
        var out: [Float] = []
        for tone in tones {
            let gap = Int((tone.gapBeforeMs / 1000 * Self.sampleRate).rounded())
            out.append(contentsOf: repeatElement(0, count: gap))
            let n = Int((tone.durationMs / 1000 * Self.sampleRate).rounded())
            guard n > 1 else { continue }
            let amplitude = pow(10, (tone.gainDBFS + offset) / 20)
            let attack = max(1, Int((min(Self.attackMs, tone.durationMs / 4) / 1000 * Self.sampleRate).rounded()))
            let w = 2 * Double.pi * tone.hz / Self.sampleRate
            for i in 0..<n {
                let env: Double
                if i < attack {
                    env = Double(i) / Double(attack)
                } else {
                    let x = Double(i - attack) / Double(max(1, n - 1 - attack))
                    env = (1 - x) * (1 - x)
                }
                var wave = sin(w * Double(i))
                if let ratio = tone.partialRatio {
                    wave = 0.75 * wave + 0.25 * sin(w * ratio * Double(i))
                }
                out.append(Float(amplitude * env * wave))
            }
        }
        return out
    }

    /// The earcon as an in-memory 16-bit mono PCM WAV file (44-byte header), for
    /// `AVAudioPlayer(data:)`.
    /// - Parameter gainOffsetDB: as `samples(gainOffsetDB:)`.
    public func wavData(gainOffsetDB: Double = 0) -> Data {
        let pcm = samples(gainOffsetDB: gainOffsetDB)
        let rate = UInt32(Self.sampleRate)
        let dataBytes = UInt32(pcm.count * 2)
        var d = Data(capacity: 44 + pcm.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        for s in pcm {
            let clamped = max(-1, min(1, s))
            u16(UInt16(bitPattern: Int16((clamped * Float(Int16.max)).rounded())))
        }
        return d
    }
}

/// Tone, words, both or nothing — for each event where the app used to talk about waiting.
public enum EarconPolicy {

    /// What to play and say for one event. The caller plays `earcon` (at `gainOffsetDB`) first, then
    /// speaks `line` through `SpeechQueue` at the band it already used.
    public struct Feedback: Sendable, Equatable {
        /// The tone, or nil for none.
        public let earcon: Earcon?
        /// Level change for the tone, dB (≤ 0).
        public let gainOffsetDB: Double
        /// Words to speak after the tone, or nil for none.
        public let line: String?

        public init(earcon: Earcon?, gainOffsetDB: Double, line: String?) {
            self.earcon = earcon
            self.gainOffsetDB = gainOffsetDB
            self.line = line
        }

        /// Nothing at all.
        public static let silent = Feedback(earcon: nil, gainOffsetDB: 0, line: nil)
    }

    /// Who opened the microphone.
    public enum ListenKind: String, Sendable, Equatable {
        /// The walker pressed (Guide tile, Action button, nod).
        case press
        /// The voice shell, once after the launch menu.
        case launch
        /// The voice shell, after an answer.
        case followUp
        /// The emergency prompt's yes / no window (the app asked a question).
        case question
    }

    /// Every event with a calm-feedback rule.
    public enum Event: Sendable, Equatable {
        /// The microphone opened.
        case listenOpened(ListenKind)
        /// The microphone closed with words that will be answered.
        case listenHeardWords
        /// The microphone closed on the app's own voice (`SelfHearFilter` dropped it).
        case listenSelfHeard
        /// The microphone closed with no words; `emptyPressCount` from `emptyPressCount(previous:heardWords:)`.
        case listenEmpty(ListenKind, emptyPressCount: Int)
        /// A cloud turn is still working (`ConversationBudget.Event.thinking`).
        case thinking
        /// A cloud turn hit its budget.
        case timedOut
        /// A cloud turn threw.
        case cloudFailed
        /// A cloud turn was replaced by a newer question.
        case superseded
        /// "Where am I" / a scene question while a description is already running.
        case describerBusy
        /// An answer of `characters` is about to be spoken.
        case answer(characters: Int)
        /// A route start is waiting for obstacle detection (one tick; `warmupTickDue` paces them).
        case routeWarming
        /// Obstacle detection is ready; the route intro follows.
        case routeReady
    }

    /// The follow-up window's listening cue level, dB. [H] −8 dB: audible as "you may talk", quiet
    /// enough not to read as a demand.
    public static let followUpGainOffsetDB: Double = -8
    /// Empty presses in a row before the words "I did not catch that." are said.
    public static let emptyPressesBeforeWords = 2
    /// An answer at least this long gets the bell first. [H] 100 characters ≈ 6 s of speech.
    public static let longAnswerCharacters = 100
    /// Seconds between warm-up ticks. [H]
    public static let warmupTickInterval: Double = 2
    /// Most warm-up ticks per route start (then silence until "Starting." or the fallback line).
    public static let warmupMaxTicks = 3
    /// Spoken when obstacle detection is ready and a queued route begins. Prefetched
    /// (`SpokenPhrases.shellLines`).
    public static let routeReadyLine = "Starting."

    /// The rule table. Pinned by the policy tests in EarconTests.swift.
    /// - Parameter event: what just happened.
    /// - Returns: the tone and words for it.
    public static func feedback(for event: Event) -> Feedback {
        switch event {
        case .listenOpened(let kind):
            return Feedback(earcon: .listening, gainOffsetDB: kind == .followUp ? followUpGainOffsetDB : 0, line: nil)
        case .listenHeardWords:
            return Feedback(earcon: .heard, gainOffsetDB: 0, line: nil)
        case .listenSelfHeard, .superseded:
            return .silent
        case .listenEmpty(let kind, let count):
            guard kind == .press else { return .silent }
            return Feedback(earcon: .nothing, gainOffsetDB: 0,
                            line: count >= emptyPressesBeforeWords ? SpokenPhrases.notHeardLine : nil)
        case .thinking, .routeWarming:
            return Feedback(earcon: .thinking, gainOffsetDB: 0, line: nil)
        case .timedOut, .cloudFailed:
            return Feedback(earcon: .error, gainOffsetDB: 0, line: ConversationBudget.timeoutLine)
        case .describerBusy:
            return Feedback(earcon: .busy, gainOffsetDB: 0, line: nil)
        case .answer(let characters):
            return characters >= longAnswerCharacters ? Feedback(earcon: .done, gainOffsetDB: 0, line: nil) : .silent
        case .routeReady:
            return Feedback(earcon: .done, gainOffsetDB: 0, line: routeReadyLine)
        }
    }

    /// The empty-press counter after a press closes: 0 when it heard words, otherwise 1, 2, 1, 2 …
    /// so the words come on every second empty press in a row, never on each one.
    /// - Parameters:
    ///   - previous: the counter before this press.
    ///   - heardWords: this press heard words.
    public static func emptyPressCount(previous: Int, heardWords: Bool) -> Int {
        heardWords ? 0 : (max(0, previous) % emptyPressesBeforeWords) + 1
    }

    /// Whether the next warm-up tick is due: ticks at 0, `warmupTickInterval`, 2× … while fewer than
    /// `warmupMaxTicks` have played.
    /// - Parameters:
    ///   - elapsed: seconds since the route start was queued.
    ///   - ticksSoFar: ticks already played for this start.
    public static func warmupTickDue(elapsed: Double, ticksSoFar: Int) -> Bool {
        ticksSoFar < warmupMaxTicks && elapsed >= Double(ticksSoFar) * warmupTickInterval
    }

    /// Whether an earcon may play now.
    public enum Gate: Sendable, Equatable {
        case play
        /// Written to the `earcon` trip-log record as `reason`.
        case skip(reason: String)
    }

    /// - Parameters:
    ///   - muted: `SpeechQueue.muted` (automation: silent, no haptic).
    ///   - safetySpeaking: a `.safety` line is playing (a tone must never cover "Head height.").
    public static func gate(muted: Bool, safetySpeaking: Bool) -> Gate {
        if muted { return .skip(reason: "muted") }
        if safetySpeaking { return .skip(reason: "safety_speaking") }
        return .play
    }
}
