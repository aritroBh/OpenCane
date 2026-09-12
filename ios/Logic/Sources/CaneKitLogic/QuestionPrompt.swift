//
//  QuestionPrompt.swift
//  CaneKitLogic
//
//  "Ask CaneKit": one spoken question about the frame the camera is looking at, one short spoken
//  answer. The sibling of `ScenePrompt` ("Where am I", which asks nothing) and `HazardPrompt`
//  (the automatic watch, which asks a fixed question every 8 s).
//
//  Why a question at all, and why a *bounded* one — the research this shape came from:
//    · Blind users do want to ask rather than only listen. The top unmet ask on AppleVis's
//      "Feature request for blindness AI apps" thread is precisely a hands-free shortcut that
//      takes a picture and answers, because holding the object, the phone and the button at once
//      is impossible; none of Seeing AI, Be My Eyes or Aira's Access AI offered one.
//    · But length is the dominant complaint. "Say It My Way" (CHI 2026) measured AI replies to
//      blind users running over ten times longer than the question (160–242 words against 10–20),
//      with users reporting they "can't process at all" and have to "cipher through everything",
//      and it found brevity wanted most when the user is hurried — which a walker always is.
//    · And open conversation is measurably weakest exactly where a walker needs it: ChatGPT
//      Advanced Voice with video "falls short in delivering essential live descriptions required
//      in dynamic situations" (arXiv 2508.03651) even while handling static scenes well.
//    · Be My Eyes shipped the same conclusion as product: fixed Siri phrases with explicit
//      "Describe Quickly / Normally / Fully" tiers plus one separate "Ask Question", rather than a
//      single open-ended conversational mode.
//  So this is deliberately **one question, one sentence, no follow-up and no conversation state**.
//  A back-and-forth is the thing the evidence says not to build for someone who is walking.
//
//  Key invariants:
//    · The answer is held to the same contract as `ScenePrompt`: no numbers, no counts, no
//      distances, and no promise that the way is clear. `CloudSceneGate` enforces every one of
//      them on the reply, so a question cannot be used to talk the model past the gate — "how far
//      is the pole?" simply gets an answer with the number refused.
//    · The model is told to say it cannot tell, rather than guess. The phrase it is given
//      (`cannotTell`) is chosen to survive the gate, which is pinned by a test — a refusal that
//      the gate itself threw away would be replaced by a scene description and read as an answer.
//    · The question is cleaned before it is interpolated (`clean`): whitespace collapsed, quotes
//      and newlines removed so the prompt stays well formed, and capped at
//      `maxQuestionCharacters` so a Siri mis-transcription of a whole sentence cannot become the
//      prompt.
//
//  Owner: `AppModel.askAboutScene(_:)` (app) → `SceneDescriber.ask(_:)`.
//  Tests: QuestionPromptTests.swift.
//

import Foundation

/// Builds the prompt for a one-shot spoken question about the current camera frame.
public enum QuestionPrompt {

    /// Longest question passed to the model. Siri hands over whatever it transcribed, and a
    /// mis-heard sentence ("take me to the ... and then read me my messages and ...") must not
    /// become the prompt. 160 characters is roughly two spoken sentences — longer than any real
    /// question a walker asks, short enough to bound the request.
    public static let maxQuestionCharacters = 160

    /// What the model is told to say when the picture does not answer the question. It is a
    /// deliberate phrase and not free choice: ⚠ `cannotTellSurvivesTheCloudGate` pins that
    /// `CloudSceneGate` lets it through. A refusal worded as "nothing there" or "all clear" would
    /// be refused by the gate, replaced by a scene description, and heard as an answer.
    public static let cannotTell = "I cannot tell from the picture"

    /// Trims a spoken question into something safe to interpolate.
    /// - Parameter question: the raw text (Siri's transcription, or the App Intent parameter).
    /// - Returns: the cleaned question, or nil when there is no question in it (empty, or
    ///   punctuation only) — the caller then says so instead of asking the model nothing.
    public static func clean(_ question: String) -> String? {
        // Quotes would break out of the quoted slot in `text(for:)`; everything else the walker
        // said is kept, including question marks. Newlines need no special case — they are
        // whitespace, so the split below turns them into the single space that separates words
        // (removing them first would glue "there\na" into "therea").
        let stripped = question.filter { $0 != "\"" }
        let collapsed = stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.contains(where: \.isLetter) else { return nil }
        guard collapsed.count > maxQuestionCharacters else { return collapsed }
        return String(collapsed.prefix(maxQuestionCharacters)).trimmingCharacters(in: .whitespaces)
    }

    /// The prompt actually sent with the image.
    ///
    /// It repeats `ScenePrompt`'s bans word for word on purpose: the reply goes through the same
    /// `CloudSceneGate`, and a prompt that allowed what the gate refuses would turn every answer
    /// into a refusal and a fallback description.
    /// - Parameter question: a question already through `clean(_:)`.
    /// - Returns: the full prompt text. Pinned by `questionPromptCarriesTheQuestionAndTheBans`.
    public static func text(for question: String) -> String {
        "You are the eyes of a blind pedestrian. A camera clamped to their white cane took this "
        + "picture. Answer this question about the picture: \"\(question)\". "
        + "One sentence, under 20 words. Answer only from what you can actually see; if the "
        + "picture does not show it, reply exactly \"\(cannotTell)\". "
        + "Never give a number, a distance or a count. Never say the way is clear, empty or safe. "
        + "No preamble."
    }
}
