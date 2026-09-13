//
//  EarconPlayer.swift
//  CaneKit
//
//  Plays the calm-feedback tones (Step 65, `Earcon` in CaneKitLogic) — a tap, a tick, a bell —
//  through the app's existing audio session, with a matching soft haptic felt on the cane.
//
//  Why this exists: owner, 2026-09-13 — "maybe a little tap or bell and then it releases something;
//  don't over-stimulate the blind person too much or else they won't listen." The waiting words
//  ("One moment.", "Still describing the previous scene.", the warm-up sentence) became tones.
//
//  Key invariants:
//    · ⚠ Hard rule 7: no `setCategory` / `setActive` here, ever. `AVAudioPlayer(data:)` plays in
//      whatever session `SpeechQueue` owns (`.playback`, or `.playAndRecord` while listening).
//    · Ducks nothing and is not a speech line: it never enters the queue, never delays a line, and
//      never sets `SpeechQueue.isSpeaking`.
//    · Whether to play at all (muted automation, a `.safety` line playing) is decided by
//      `EarconPolicy.gate`, applied by the only caller, `SpeechQueue.playEarcon`.
//    · The tones are synthesized once per (earcon, gain) in memory (`Earcon.wavData`, 16-bit mono
//      WAV, a few kB each) — no bundled audio files, no disk.
//
//  Owner / caller: `SpeechQueue` (one instance, `playEarcon`). Isolation: main actor (UIKit haptic).
//  Tests: the numbers (≤ 180 ms, ≤ −12 dBFS, silent edges, WAV header) are pinned in
//  CaneKitLogic `EarconTests`; the player itself has no unit test (device check in CHANGELOG Step 65).
//

import AVFoundation
import CaneKitLogic
import UIKit

/// Synthesizes and plays `Earcon` tones plus a soft haptic. Main actor; owned by `SpeechQueue`.
@MainActor
final class EarconPlayer {

    /// WAV bytes per earcon and gain offset, built on first use.
    private var cache: [String: Data] = [:]
    /// Players still sounding; kept alive here (an `AVAudioPlayer` that is released stops), pruned
    /// on every `play`.
    private var playing: [AVAudioPlayer] = []
    /// The soft impact felt through the cane with each tone.
    private let impact = UIImpactFeedbackGenerator(style: .soft)

    /// Plays one earcon now. Overlapping tones are allowed (each is ≤ 180 ms).
    /// - Parameters:
    ///   - earcon: the tone.
    ///   - gainOffsetDB: level change, ≤ 0 (`EarconPolicy.followUpGainOffsetDB` for the follow-up cue).
    ///   - haptic: also fire the soft impact (false for `.listening`, which already has the 1519
    ///     system haptic in `VoiceInputEngine`).
    /// - Returns: false when the player could not be built or would not start.
    /// Caller: `SpeechQueue.playEarcon`, after `EarconPolicy.gate` said `.play`.
    @discardableResult
    func play(_ earcon: Earcon, gainOffsetDB: Double = 0, haptic: Bool = true) -> Bool {
        let key = "\(earcon.rawValue)@\(gainOffsetDB)"
        let data: Data
        if let cached = cache[key] {
            data = cached
        } else {
            data = earcon.wavData(gainOffsetDB: gainOffsetDB)
            cache[key] = data
        }
        playing.removeAll { !$0.isPlaying }
        guard let player = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue) else {
            return false
        }
        player.prepareToPlay()
        guard player.play() else { return false }
        playing.append(player)
        if haptic { impact.impactOccurred(intensity: 0.6) }
        return true
    }
}
