//
//  QuestionPromptTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins QuestionPrompt.swift — the one-shot spoken question about the current frame.
//
//  The two failures these guard against are both "the answer sounded fine":
//    · a question used as a way round `CloudSceneGate` ("how many steps?", "is it clear?"), which
//      is why the prompt repeats the gate's bans and the gate still runs on the reply;
//    · a refusal the gate itself throws away. The model is told to say `cannotTell` when the
//      picture does not answer; if that phrase were refused, the app would quietly speak a scene
//      description instead and the walker would hear it as the answer to their question.
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/QuestionPrompt.swift` (`clean`, `text(for:)`,
//  `cannotTell`, `maxQuestionCharacters` 160), checked against the real `CloudSceneGate`.
//  Caller: `SceneDescriber.ask` (cleans the question, sends `text(for:)` with one frame to the
//  cloud model, gates the reply), reached from `AskSceneIntent` → `AppModel.askAboutScene`
//  (HandsFreeIntents.swift, "Ask OpenCane").
//

import Testing
@testable import CaneKitLogic

/// The prompt has to carry the walker's question *and* every ban the gate enforces, or the answer
/// is refused and replaced by a description — a question that always fails is worse than none.
@Test func questionPromptCarriesTheQuestionAndTheBans() {
    let text = QuestionPrompt.text(for: "is there a bench on the left")
    #expect(text.contains("is there a bench on the left"))
    #expect(text.contains("Never give a number, a distance or a count."))
    #expect(text.contains("Never say the way is clear, empty or safe."))
    #expect(text.contains("One sentence, under 20 words."))
    #expect(text.contains(QuestionPrompt.cannotTell))
}

/// ⚠ The model's "I don't know" must survive the gate. If it did not, `SceneDescriber` would fall
/// back to a scene description and the walker would hear an answer to a different question.
@Test func cannotTellSurvivesTheCloudGate() {
    let verdict = CloudSceneGate.check(QuestionPrompt.cannotTell + ".",
                                       lidar: "", ocr: [], detectedNouns: [])
    #expect(verdict.sentence != nil)
    #expect(verdict.note == "spoken")
}

/// A question cannot be used to talk the model past the gate: asking for a number still gets the
/// number refused, and asking "is it clear" still gets the reassurance refused.
@Test func askingForNumbersOrReassuranceIsStillRefused() {
    #expect(CloudSceneGate.sanitized("The pole is about four meters ahead.",
                                     lidar: "", ocr: [], detectedNouns: []) == nil)
    #expect(CloudSceneGate.sanitized("Yes, the path ahead is clear.",
                                     lidar: "", ocr: [], detectedNouns: []) == nil)
}

/// Quotes and newlines would break out of the quoted slot in the prompt; whitespace is collapsed
/// so a hesitant transcription does not arrive full of gaps.
@Test func cleanCollapsesWhitespaceAndRemovesQuotes() {
    #expect(QuestionPrompt.clean("  is   there\na \"bench\"?  ") == "is there a bench?")
    #expect(QuestionPrompt.clean("what is ahead") == "what is ahead")
}

/// No question in it is not a question: the caller says so rather than asking the model nothing.
@Test func aQuestionWithNoLettersIsNotAQuestion() {
    #expect(QuestionPrompt.clean("") == nil)
    #expect(QuestionPrompt.clean("   ") == nil)
    #expect(QuestionPrompt.clean("?? ...  !") == nil)
    #expect(QuestionPrompt.clean("12 34") == nil)
}

/// Siri hands over whatever it transcribed; a mis-heard paragraph must not become the prompt.
@Test func anOverlongQuestionIsCapped() {
    let long = String(repeating: "a", count: 400)
    let cleaned = QuestionPrompt.clean(long)
    #expect(cleaned?.count == QuestionPrompt.maxQuestionCharacters)
    #expect(QuestionPrompt.maxQuestionCharacters == 160)
}
